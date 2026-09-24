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

    /// True until the last queued batch ends.
    private(set) var isImporting = false
    /// The batch being imported, once its projects are counted; nil otherwise.
    private(set) var progress: Progress?
    @ObservationIgnored var onLocalLibraryImported: (@MainActor (Int) -> Void)?

    /// Requests made while a batch runs, each imported as its own batch in arrival order.
    @ObservationIgnored private var pendingFolders: [[URL]] = []
    @ObservationIgnored private var isIngesting = false
    @ObservationIgnored private let importService: WallpaperEngineImportService
    @ObservationIgnored private let fileManager: FileManager

    init(
        importService: WallpaperEngineImportService = WallpaperEngineImportService(),
        fileManager: FileManager = .default
    ) {
        self.importService = importService
        self.fileManager = fileManager
    }

    func importProjects(from folder: URL) {
        importProjects(from: [folder])
    }

    /// One pass for every folder: a request made while another import runs waits for it.
    func importProjects(from folders: [URL]) {
        guard !isImporting else {
            pendingFolders.append(folders)
            return
        }
        isImporting = true
        Task { [weak self] in
            await self?.importQueue(startingWith: folders)
        }
    }

    private func importQueue(startingWith folders: [URL]) async {
        var next: [URL]? = folders
        while let batch = next {
            await importAll(from: batch)
            next = pendingFolders.isEmpty ? nil : pendingFolders.removeFirst()
        }
        isImporting = false
    }

    private func importAll(from folders: [URL]) async {
        let scoped = folders.filter { $0.startAccessingSecurityScopedResource() }
        defer {
            for folder in scoped {
                folder.stopAccessingSecurityScopedResource()
            }
        }

        let title = ListFormatter.localizedString(byJoining: folders.map(\.lastPathComponent))
        var projectFolders: [URL] = []
        var unreadableFolders = 0
        for folder in folders {
            if let found = discoverProjectFolders(in: folder) {
                projectFolders += found
            } else {
                unreadableFolders += 1
            }
        }
        if unreadableFolders == folders.count {
            WorkshopToastCenter.shared.post(
                headline: String(localized: "Import failed", bundle: .appLanguage, comment: "Folder import failure toast headline."),
                title: title,
                message: String(localized: "That folder couldn't be read.", bundle: .appLanguage, comment: "Folder import failure: the chosen folder could not be enumerated."),
                isSuccess: false
            )
            return
        }
        guard !projectFolders.isEmpty else {
            WorkshopToastCenter.shared.post(
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
        var wallpaperEntries = 0
        progress = Progress(title: title, completed: 0, total: projectFolders.count)
        for projectFolder in projectFolders {
            switch await importOne(projectFolder, deliberate: true, onWallpaperImported: { wallpaperEntries += 1 }) {
            case .imported: imported += 1
            case .rejected: rejected += 1
            case .unreadable: unreadable += 1
            }
            progress?.completed += 1
        }

        progress = nil
        emitSummary(title: title, imported: imported, rejected: rejected, unreadable: unreadable)
        onLocalLibraryImported?(wallpaperEntries)
    }

    func ingestExistingDownloads(using doctor: SteamCMDDoctorService) async {
        guard !isIngesting, !isImporting else { return }
        isIngesting = true
        defer { isIngesting = false }

        let settings = SettingsManager.shared.loadGlobalSettings()
        // Re-import when the stored source bookmark no longer resolves.
        var known = Set(
            settings.recentWPEImports
                .filter { Self.originResolves($0.origin) }
                .map(\.origin.workshopID)
        )
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
        let staleIDs = Set(
            settings.recentWPEImports
                .filter { !Self.originResolves($0.origin) }
                .map(\.origin.workshopID)
        )

        // Scan adds/relinks only; never prune on absence (unplugged drive ≠ deleted).
        await doctor.enumerateDownloadedItemFolders { [weak self] folder in
            guard let self else { return }
            let id = folder.lastPathComponent
            guard !known.contains(id) else { return }
            let isRelink = staleIDs.contains(id)
            if await importOne(folder, deliberate: false, preservesHistory: isRelink) == .imported {
                if isRelink { repaired += 1 } else { added += 1 }
                known.insert(id)
            }
        }

        guard added > 0 || repaired > 0 else { return }
        WorkshopToastCenter.shared.post(
            headline: String(localized: "Library synced", bundle: .appLanguage, comment: "Toast headline after auto-importing existing SteamCMD downloads."),
            title: String(localized: "SteamCMD downloads", bundle: .appLanguage, comment: "Toast subject for the SteamCMD download sync."),
            message: Self.syncSummary(added: added, repaired: repaired),
            isSuccess: true
        )
    }

    nonisolated static func syncSummary(added: Int, repaired: Int) -> String {
        var parts: [String] = []
        if added > 0 {
            parts.append(String(localized: "added \(added)", bundle: .appLanguage, comment: "Library-sync summary fragment. Placeholder is the number of newly imported wallpapers."))
        }
        if repaired > 0 {
            parts.append(String(localized: "relinked \(repaired)", bundle: .appLanguage, comment: "Library-sync summary fragment. Placeholder is the number of wallpapers whose broken folder access was restored."))
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
    }

    /// Record history entry; deliberate=true lifts delete tombstones (auto-scan does not).
    private func importOne(
        _ projectFolder: URL,
        deliberate: Bool,
        preservesHistory: Bool = false,
        onWallpaperImported: (@MainActor () -> Void)? = nil
    ) async -> ProjectImportOutcome {
        do {
            switch try await importService.importProject(folder: projectFolder) {
            case .ready(_, let origin), .unsupported(let origin):
                SettingsManager.shared.recordWPEImport(
                    WPEHistoryEntry(origin: origin, importedAt: Date(), lastUsedAt: nil),
                    clearsDeleteTombstone: deliberate,
                    preservesHistory: preservesHistory
                )
                onWallpaperImported?()
                return .imported
            case let .workshopPreset(preset):
                await SettingsManager.shared.registerScenePreset(
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

    private func emitSummary(title: String, imported: Int, rejected: Int, unreadable: Int) {
        guard imported > 0 else {
            // One word here would make a folder of damaged projects read as a folder of the wrong kind of file.
            let message = unreadable > 0 && rejected == 0
                ? String(localized: "None of the projects in that folder could be read.", bundle: .appLanguage, comment: "Folder import failure: every discovered project failed to read.")
                : String(localized: "None of the projects in that folder could be imported.", bundle: .appLanguage, comment: "Folder import failure: every discovered project was rejected.")
            WorkshopToastCenter.shared.post(
                headline: String(localized: "Import failed", bundle: .appLanguage, comment: "Folder import failure toast headline."),
                title: title,
                message: message,
                isSuccess: false
            )
            return
        }

        let message = if rejected > 0, unreadable > 0 {
            String(localized: "Linked \(imported), skipped \(rejected), \(unreadable) unreadable.", bundle: .appLanguage, comment: "Folder-link success summary. Placeholders are the linked, skipped and unreadable counts.")
        } else if unreadable > 0 {
            String(localized: "Linked \(imported), \(unreadable) couldn't be read.", bundle: .appLanguage, comment: "Folder-link success summary with unreadable projects. Placeholders are the linked and unreadable counts.")
        } else if rejected > 0 {
            String(localized: "Linked \(imported), skipped \(rejected).", bundle: .appLanguage, comment: "Folder-link success summary with skipped count. Placeholders are linked and skipped counts.")
        } else {
            String(localized: "Linked \(imported) project folders to your library.", bundle: .appLanguage, comment: "Folder-link success summary. Placeholder is the linked project count; source folders remain in place.")
        }
        WorkshopToastCenter.shared.post(
            headline: String(localized: "Linked", bundle: .appLanguage, comment: "Folder-link success toast headline."),
            title: title,
            message: message,
            isSuccess: true
        )
    }

    /// nil when the folder could not be read at all — different from a folder that holds no projects.
    private func discoverProjectFolders(in root: URL) -> [URL]? {
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

        return children.filter { child in
            let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return isDir && fileManager.fileExists(atPath: child.appendingPathComponent("project.json").path)
        }
    }
}
#endif
