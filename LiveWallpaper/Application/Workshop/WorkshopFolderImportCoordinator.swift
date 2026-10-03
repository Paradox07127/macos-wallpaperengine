#if !LITE_BUILD
import Foundation
import LiveWallpaperCore
import Observation

@MainActor
@Observable
final class WorkshopFolderImportCoordinator {
    static let shared = WorkshopFolderImportCoordinator()

    struct Progress: Equatable {
        /// The batch's folder names, joined for display.
        let title: String
        /// Projects tried so far, imported or not.
        var completed: Int
        let total: Int
    }

    private enum Importer { case folders, downloadScan }

    /// Which entry is writing history, presets and tombstones; nil when idle. One slot for both entries.
    private var importer: Importer?
    /// True from a folder request until the last queued batch ends, including while it waits for the download scan.
    var isImporting: Bool {
        importer == .folders || !pendingFolders.isEmpty
    }

    /// The batch being imported, once its projects are counted; nil otherwise.
    private(set) var progress: Progress?
    @ObservationIgnored var onLocalLibraryImported: (@MainActor (Int) -> Void)?

    /// Requests made while an import runs, each imported as its own batch in arrival order.
    private var pendingFolders: [[URL]] = []
    @ObservationIgnored private var importTask: Task<Void, Never>?
    private var isTerminated = false
    @ObservationIgnored private let importService: WallpaperEngineImportService
    @ObservationIgnored private let settings: SettingsManager
    @ObservationIgnored private let discoverFolders: @Sendable (URL) -> [URL]?
    @ObservationIgnored private let toastCenter: WorkshopToastCenter
    /// Ids whose scan conflict was already shown this launch; the scan reruns on every Workshop visit.
    @ObservationIgnored private var reportedScanConflictIDs: Set<String> = []

    init(
        importService: WallpaperEngineImportService = WallpaperEngineImportService(),
        settings: SettingsManager = .shared,
        discoverFolders: (@Sendable (URL) -> [URL]?)? = nil,
        toastCenter: WorkshopToastCenter = .shared
    ) {
        self.importService = importService
        self.discoverFolders = discoverFolders ?? Self.discoverProjectFolders
        self.toastCenter = toastCenter
        self.settings = settings
    }

    /// One pass for every folder: a request made while another import or the download scan runs waits for it.
    func importProjects(from folders: [URL]) {
        guard !isTerminated else { return }
        guard importer == nil else {
            pendingFolders.append(folders)
            return
        }
        importer = .folders
        importTask = Task { [weak self] in
            guard let self else { return }
            await importQueue(startingWith: folders)
            importTask = nil
        }
    }

    func shutdown() {
        isTerminated = true
        pendingFolders.removeAll()
        importTask?.cancel()
        progress = nil
    }

    private var allowsImport: Bool {
        !isTerminated && !Task.isCancelled
    }

    private func importQueue(startingWith folders: [URL]) async {
        var next: [URL]? = folders
        while let batch = next, allowsImport {
            await importAll(from: batch)
            next = pendingFolders.isEmpty ? nil : pendingFolders.removeFirst()
        }
        importer = nil
    }

    private func importAll(from folders: [URL]) async {
        let scoped = folders.filter { $0.startAccessingSecurityScopedResource() }
        defer {
            for folder in scoped {
                folder.stopAccessingSecurityScopedResource()
            }
        }

        let title = ListFormatter.localizedString(byJoining: folders.map(\.lastPathComponent))
        let discoverFolders = discoverFolders
        let discovery = Task.detached(priority: .utility) { @Sendable in
            var projectFolders: [URL] = []
            var unreadableFolders = 0
            for folder in folders {
                guard !Task.isCancelled else { break }
                if let found = discoverFolders(folder) {
                    projectFolders += found
                } else {
                    unreadableFolders += 1
                }
            }
            return (projectFolders, unreadableFolders)
        }
        let (projectFolders, unreadableFolders) = await withTaskCancellationHandler {
            await discovery.value
        } onCancel: {
            discovery.cancel()
        }
        guard allowsImport else { return }
        if unreadableFolders == folders.count {
            toastCenter.post(
                headline: String(localized: "Import failed", bundle: .appLanguage, comment: "Folder import failure toast headline."),
                title: title,
                message: String(localized: "That folder couldn't be read.", bundle: .appLanguage, comment: "Folder import failure: the chosen folder could not be enumerated."),
                isSuccess: false
            )
            return
        }
        guard !projectFolders.isEmpty else {
            toastCenter.post(
                headline: String(localized: "Import failed", bundle: .appLanguage, comment: "Folder import failure toast headline."),
                title: title,
                message: String(localized: "No Wallpaper Engine projects were found in that folder.", bundle: .appLanguage, comment: "Folder import failure: the chosen folder had no project.json."),
                isSuccess: false
            )
            return
        }

        var imported = 0
        var rejected = 0
        var unreadable = unreadableFolders
        var conflictTitles: [String] = []
        var wallpaperEntries = 0
        progress = Progress(title: title, completed: 0, total: projectFolders.count)
        for projectFolder in projectFolders {
            guard allowsImport else { return }
            let outcome = await importOne(projectFolder, deliberate: true, onWallpaperImported: { wallpaperEntries += 1 })
            guard allowsImport else { return }
            switch outcome {
            case .imported: imported += 1
            case .rejected: rejected += 1
            case .unreadable: unreadable += 1
            case let .conflict(title): conflictTitles.append(title)
            }
            progress?.completed += 1
        }

        progress = nil
        emitSummary(title: title, imported: imported, rejected: rejected, unreadable: unreadable, conflictTitles: conflictTitles)
        onLocalLibraryImported?(wallpaperEntries)
    }

    /// Skipped, not queued, while anything else imports: the scan reruns on the next Workshop visit.
    func ingestExistingDownloads(using doctor: SteamCMDDoctorService) async {
        guard allowsImport, importer == nil else { return }
        importer = .downloadScan
        defer {
            importer = nil
            if !isTerminated, !pendingFolders.isEmpty {
                importProjects(from: pendingFolders.removeFirst())
            }
        }

        let settings = settings.loadGlobalSettings()
        // Re-import when the stored source bookmark no longer resolves.
        var known = Set<String>()
        var staleIDs = Set<String>()
        // One resolve per entry: each resolve is a ScopedBookmarkAgent request.
        for entry in settings.recentWPEImports {
            if Self.originResolves(entry.origin) {
                known.insert(entry.origin.workshopID)
            } else {
                staleIDs.insert(entry.origin.workshopID)
            }
        }
        // Skip items the user explicitly deleted so a still-present Steam item
        // does not silently reappear after removal from the Loomscreen library.
        known.formUnion(settings.deletedWorkshopIDs)
        // A registered preset leaves no history entry; without this the scan would re-register every downloaded preset, overwriting a local rename and restamping createdAt.
        known.formUnion(settings.scenePresets.values.compactMap {
            if case .workshop(let workshopID) = $0.source { return workshopID }
            return nil
        })
        var added = 0
        var repaired = 0
        var conflicts = 0

        // Scan adds/relinks only; never prune on absence (unplugged drive ≠ deleted).
        await doctor.enumerateDownloadedItemFolders { [weak self] folder in
            guard let self, allowsImport else { return }
            let id = folder.lastPathComponent
            guard !known.contains(id) else {
                guard !settings.deletedWorkshopIDs.contains(id),
                      let existing = self.settings.conflictingWPEImport(workshopID: id, sourceFolder: folder) else { return }
                let outcome: ProjectImportOutcome = existing.origin.steamFolderItemID == nil
                    ? await importOne(folder, deliberate: false, supersedesLocalCopy: true)
                    : .conflict(title: existing.origin.title)
                switch outcome {
                case .imported:
                    added += 1
                case .conflict:
                    if reportedScanConflictIDs.insert(id).inserted {
                        conflicts += 1
                    }
                case .rejected, .unreadable:
                    break
                }
                return
            }
            let isRelink = staleIDs.contains(id)
            switch await importOne(folder, deliberate: false, preservesHistory: isRelink) {
            case .imported:
                if isRelink {
                    repaired += 1
                } else {
                    added += 1
                }
                known.insert(id)
            case .conflict:
                if reportedScanConflictIDs.insert(id).inserted {
                    conflicts += 1
                }
            case .rejected, .unreadable:
                break
            }
        }

        guard allowsImport, added > 0 || repaired > 0 || conflicts > 0 else { return }
        toastCenter.post(
            headline: String(localized: "Library synced", bundle: .appLanguage, comment: "Toast headline after auto-importing existing SteamCMD downloads."),
            title: String(localized: "SteamCMD downloads", bundle: .appLanguage, comment: "Toast subject for the SteamCMD download sync."),
            message: Self.syncSummary(added: added, repaired: repaired, conflicts: conflicts),
            isSuccess: true
        )
    }

    nonisolated static func syncSummary(added: Int, repaired: Int, conflicts: Int = 0) -> String {
        var parts: [String] = []
        if added > 0 {
            parts.append(String(localized: "added \(added)", bundle: .appLanguage, comment: "Library-sync summary fragment. Placeholder is the number of newly imported wallpapers."))
        }
        if repaired > 0 {
            parts.append(String(localized: "relinked \(repaired)", bundle: .appLanguage, comment: "Library-sync summary fragment. Placeholder is the number of wallpapers whose broken folder access was restored."))
        }
        if conflicts > 0 {
            parts.append(String(localized: "\(conflicts) skipped: already in library from another folder", bundle: .appLanguage, locale: AppLanguagePreference.current.locale, comment: "Library-sync summary fragment. Placeholder is the number of downloaded items whose Workshop id the library already holds from a different folder."))
        }
        return ListFormatter.localizedString(byJoining: parts)
    }

    /// Cheap liveness probe for a stored import: the source bookmark must still
    /// resolve *and* point at a folder that exists.
    static func originResolves(_ origin: WPEOrigin) -> Bool {
        guard case .success(let resolved) = SecurityScopedBookmarkResolver.shared.resolve(
            origin.sourceFolderBookmark,
            target: .transient
        ) else { return false }
        return SecurityScopedBookmarkResolver.withScopedAccess(resolved.url) { _ in
            FileManager.default.fileExists(atPath: resolved.url.path(percentEncoded: false))
        }
    }

    /// Why one project did not come in. A Bool would make the summary call every failure unsupported, including an unreadable project.json.
    enum ProjectImportOutcome: Equatable, Sendable {
        case imported
        /// Read fine, but not something this app can show.
        case rejected
        /// Could not be read — a damaged project, a permission fault.
        case unreadable
        /// Not imported: another folder already holds this Workshop id in the library. `title` is that entry's.
        case conflict(title: String)
    }

    /// Record history entry; deliberate=true lifts delete tombstones (auto-scan does not).
    private func importOne(
        _ projectFolder: URL,
        deliberate: Bool,
        preservesHistory: Bool = false,
        supersedesLocalCopy: Bool = false,
        onWallpaperImported: (@MainActor () -> Void)? = nil
    ) async -> ProjectImportOutcome {
        guard allowsImport else { return .unreadable }
        if let project = try? WallpaperEngineProject.read(from: projectFolder),
           let existing = settings.conflictingWPEImport(workshopID: project.workshopID, sourceFolder: projectFolder),
           !(supersedesLocalCopy && existing.origin.steamFolderItemID == nil) {
            Logger.info("Skipped a project whose Workshop id is already in the library from another folder", category: .workshop)
            return .conflict(title: existing.origin.title)
        }
        do {
            let result = try await importService.importProject(folder: projectFolder)
            guard allowsImport else { return .unreadable }
            switch result {
            case .ready(_, let origin), .unsupported(let origin):
                settings.recordWPEImport(
                    WPEHistoryEntry(origin: origin, importedAt: Date(), lastUsedAt: nil),
                    clearsDeleteTombstone: deliberate,
                    preservesHistory: preservesHistory
                )
                onWallpaperImported?()
                return .imported
            case let .workshopPreset(preset):
                await settings.registerScenePreset(
                    preset,
                    clearsDeleteTombstone: deliberate
                )
                return .imported
            case let .sceneFailure(cause, _, _):
                Logger.warning("Failed to read a scene during import: \(cause.reason)", category: .workshop)
                return .unreadable
            case let .rejected(reason):
                Logger.info("Skipped a project during import: \(reason)", category: .workshop)
                return .rejected
            }
        } catch {
            Logger.info("Failed to read a project during import: \(error.localizedDescription)", category: .workshop)
            return .unreadable
        }
    }

    private func emitSummary(title: String, imported: Int, rejected: Int, unreadable: Int, conflictTitles: [String]) {
        let conflictNote = conflictTitles.isEmpty ? nil : String(localized: "\(conflictTitles.count) skipped: already in your library from another folder.", bundle: .appLanguage, locale: AppLanguagePreference.current.locale, comment: "Folder import summary sentence appended after the linked/skipped counts. Placeholder is the number of projects whose Workshop id the library already holds from a different folder.")
        guard imported > 0 else {
            // One word here would make a folder of damaged projects read as a folder of the wrong kind of file.
            let failure = unreadable > 0 && rejected == 0
                ? String(localized: "None of the projects in that folder could be read.", bundle: .appLanguage, comment: "Folder import failure: every discovered project failed to read.")
                : String(localized: "None of the projects in that folder could be imported.", bundle: .appLanguage, comment: "Folder import failure: every discovered project was rejected.")
            let message = if conflictTitles.count == 1, rejected == 0, unreadable == 0 {
                String(localized: "\(conflictTitles[0]) is already in your library from another folder.", bundle: .appLanguage, comment: "Folder import failure: the one chosen project has a Workshop id the library already holds from a different folder. Placeholder is the title of the wallpaper already in the library.")
            } else {
                [failure, conflictNote].compactMap(\.self).joined(separator: " ")
            }
            toastCenter.post(
                headline: String(localized: "Import failed", bundle: .appLanguage, comment: "Folder import failure toast headline."),
                title: title,
                message: message,
                isSuccess: false
            )
            return
        }

        let counts = if rejected > 0, unreadable > 0 {
            String(localized: "Linked \(imported), skipped \(rejected), \(unreadable) unreadable.", bundle: .appLanguage, comment: "Folder-link success summary. Placeholders are the linked, skipped and unreadable counts.")
        } else if unreadable > 0 {
            String(localized: "Linked \(imported), \(unreadable) couldn't be read.", bundle: .appLanguage, comment: "Folder-link success summary with unreadable projects. Placeholders are the linked and unreadable counts.")
        } else if rejected > 0 {
            String(localized: "Linked \(imported), skipped \(rejected).", bundle: .appLanguage, comment: "Folder-link success summary with skipped count. Placeholders are linked and skipped counts.")
        } else {
            String(localized: "Linked \(imported) project folders to your library.", bundle: .appLanguage, locale: AppLanguagePreference.current.locale, comment: "Folder-link success summary. Placeholder is the linked project count; source folders remain in place.")
        }
        toastCenter.post(
            headline: String(localized: "Linked", bundle: .appLanguage, comment: "Folder-link success toast headline."),
            title: title,
            message: [counts, conflictNote].compactMap(\.self).joined(separator: " "),
            isSuccess: true
        )
    }

    /// nil when the folder could not be read at all — different from a folder that holds no projects.
    private nonisolated static func discoverProjectFolders(in root: URL) -> [URL]? {
        guard !Task.isCancelled else { return [] }
        let fileManager = FileManager()
        if fileManager.fileExists(atPath: root.appendingPathComponent("project.json").path) {
            return [root]
        }

        let children: [URL]
        do {
            children = try fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
        } catch {
            Logger.info("Could not read the chosen import folder: \(error.localizedDescription)", category: .workshop)
            return nil
        }

        var projects: [URL] = []
        for child in children {
            guard !Task.isCancelled else { break }
            let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir, fileManager.fileExists(atPath: child.appendingPathComponent("project.json").path) {
                projects.append(child)
            }
        }
        return projects
    }
}
#endif
