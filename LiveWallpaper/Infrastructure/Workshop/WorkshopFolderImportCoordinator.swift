#if !LITE_BUILD
import Foundation
import LiveWallpaperCore
import Observation

/// Links project folders into the managed library (discover, bookmark, history entry).
/// Source assets remain in place; this coordinator does not copy the chosen folders.
@MainActor
@Observable
final class WorkshopFolderImportCoordinator {
    static let shared = WorkshopFolderImportCoordinator()

    private(set) var isImporting = false

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

    /// The toolbar's single "add wallpaper" picker classifies what the user
    /// chose and routes library folders here, so this owns no panel of its own.
    /// No-op while a previous import is still running.
    func importProjects(from folder: URL) {
        guard !isImporting else { return }
        isImporting = true
        Task { [weak self] in
            await self?.importAll(from: folder)
        }
    }

    private func importAll(from folder: URL) async {
        defer { isImporting = false }

        let didStart = folder.startAccessingSecurityScopedResource()
        defer {
            if didStart {
                folder.stopAccessingSecurityScopedResource()
            }
        }

        guard let projectFolders = discoverProjectFolders(in: folder) else {
            WorkshopToastCenter.shared.post(
                headline: String(localized: "Import failed", bundle: .appLanguage, comment: "Folder import failure toast headline."),
                title: folder.lastPathComponent,
                message: String(localized: "That folder couldn't be read.", bundle: .appLanguage, comment: "Folder import failure: the chosen folder could not be enumerated."),
                isSuccess: false
            )
            return
        }
        guard !projectFolders.isEmpty else {
            WorkshopToastCenter.shared.post(
                headline: String(localized: "Import failed", bundle: .appLanguage, comment: "Folder import failure toast headline."),
                title: folder.lastPathComponent,
                message: String(localized: "No Wallpaper Engine projects were found in that folder.", bundle: .appLanguage, comment: "Folder import failure: the chosen folder had no project.json."),
                isSuccess: false
            )
            return
        }

        var imported = 0
        var rejected = 0
        var unreadable = 0
        for projectFolder in projectFolders {
            switch await importOne(projectFolder, deliberate: true) {
            case .imported: imported += 1
            case .rejected: rejected += 1
            case .unreadable: unreadable += 1
            }
        }

        emitSummary(folder: folder, imported: imported, rejected: rejected, unreadable: unreadable)
    }

    /// Imports every not-yet-recorded project from the authorized official Steam
    /// profile. Silent unless it adds something; re-runs are cheap.
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
        // A registered preset leaves no history entry, so without this the scan
        // re-registers every downloaded preset on each pass — overwriting a
        // local rename and restamping `createdAt`, which reads downstream as a
        // brand-new preset every time.
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

    /// Why one project in the folder did not come in. A `Bool` made the
    /// summary call every failure "unsupported", which is wrong for a project
    /// whose `project.json` could not be read at all.
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
        preservesHistory: Bool = false
    ) async -> ProjectImportOutcome {
        do {
            switch try await importService.importProject(folder: projectFolder) {
            case .ready(_, let origin), .unsupported(let origin):
                SettingsManager.shared.recordWPEImport(
                    WPEHistoryEntry(origin: origin, importedAt: Date(), lastUsedAt: nil),
                    clearsDeleteTombstone: deliberate,
                    preservesHistory: preservesHistory
                )
                return .imported
            case let .workshopPreset(preset):
                await SettingsManager.shared.registerScenePreset(
                    preset,
                    clearsDeleteTombstone: deliberate
                )
                return .imported
            case let .rejected(reason):
                Logger.info("Skipped a project during import: \(reason)", category: .workshop)
                return .rejected
            }
        } catch {
            Logger.info("Failed to read a project during import: \(error.localizedDescription)", category: .workshop)
            return .unreadable
        }
    }

    private func emitSummary(folder: URL, imported: Int, rejected: Int, unreadable: Int) {
        guard imported > 0 else {
            // "Unsupported" was the only word offered here, so a folder of
            // damaged projects read as a folder of the wrong kind of file.
            let message = unreadable > 0 && rejected == 0
                ? String(localized: "None of the projects in that folder could be read.", bundle: .appLanguage, comment: "Folder import failure: every discovered project failed to read.")
                : String(localized: "None of the projects in that folder could be imported.", bundle: .appLanguage, comment: "Folder import failure: every discovered project was rejected.")
            WorkshopToastCenter.shared.post(
                headline: String(localized: "Import failed", bundle: .appLanguage, comment: "Folder import failure toast headline."),
                title: folder.lastPathComponent,
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
            title: folder.lastPathComponent,
            message: message,
            isSuccess: true
        )
    }

    /// A folder with `project.json` imports as itself; otherwise it is treated as
    /// a library root and its immediate `project.json`-bearing subfolders import.
    /// `nil` when the folder could not be read at all, which is a different
    /// message from a folder that holds no projects.
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
