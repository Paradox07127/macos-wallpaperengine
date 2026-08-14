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
        defer { if didStart { folder.stopAccessingSecurityScopedResource() } }

        let projectFolders = discoverProjectFolders(in: folder)
        guard !projectFolders.isEmpty else {
            WorkshopToastCenter.shared.post(
                headline: String(localized: "Import failed", comment: "Folder import failure toast headline."),
                title: folder.lastPathComponent,
                message: String(localized: "No Wallpaper Engine projects were found in that folder.", comment: "Folder import failure: the chosen folder had no project.json."),
                isSuccess: false
            )
            return
        }

        var imported = 0
        for projectFolder in projectFolders {
            if await importOne(projectFolder, deliberate: true) { imported += 1 }
        }

        emitSummary(folder: folder, imported: imported, skipped: projectFolders.count - imported)
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
            if await self.importOne(folder, deliberate: false, preservesHistory: isRelink) {
                if isRelink { repaired += 1 } else { added += 1 }
                known.insert(id)
            }
        }

        guard added > 0 || repaired > 0 else { return }
        WorkshopToastCenter.shared.post(
            headline: String(localized: "Library synced", comment: "Toast headline after auto-importing existing SteamCMD downloads."),
            title: String(localized: "SteamCMD downloads", comment: "Toast subject for the SteamCMD download sync."),
            message: Self.syncSummary(added: added, repaired: repaired),
            isSuccess: true
        )
    }

    nonisolated static func syncSummary(added: Int, repaired: Int) -> String {
        var parts: [String] = []
        if added > 0 {
            parts.append(String(localized: "added \(added)", comment: "Library-sync summary fragment. Placeholder is the number of newly imported wallpapers."))
        }
        if repaired > 0 {
            parts.append(String(localized: "relinked \(repaired)", comment: "Library-sync summary fragment. Placeholder is the number of wallpapers whose broken folder access was restored."))
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

    /// Record history entry; deliberate=true lifts delete tombstones (auto-scan does not).
    private func importOne(
        _ projectFolder: URL,
        deliberate: Bool,
        preservesHistory: Bool = false
    ) async -> Bool {
        do {
            switch try await importService.importProject(folder: projectFolder) {
            case .ready(_, let origin), .unsupported(let origin):
                SettingsManager.shared.recordWPEImport(
                    WPEHistoryEntry(origin: origin, importedAt: Date(), lastUsedAt: nil),
                    clearsDeleteTombstone: deliberate,
                    preservesHistory: preservesHistory
                )
                return true
            case .workshopPreset(let preset):
                await SettingsManager.shared.registerScenePreset(
                    preset,
                    clearsDeleteTombstone: deliberate
                )
                return true
            case .rejected(let reason):
                Logger.info("Skipped a project during import: \(reason)", category: .workshop)
                return false
            }
        } catch {
            Logger.info("Failed to read a project during import: \(error.localizedDescription)", category: .workshop)
            return false
        }
    }

    private func emitSummary(folder: URL, imported: Int, skipped: Int) {
        guard imported > 0 else {
            WorkshopToastCenter.shared.post(
                headline: String(localized: "Import failed", comment: "Folder import failure toast headline."),
                title: folder.lastPathComponent,
                message: String(localized: "None of the projects in that folder could be imported.", comment: "Folder import failure: every discovered project was rejected."),
                isSuccess: false
            )
            return
        }

        let message: String
        if skipped > 0 {
            message = String(localized: "Linked \(imported), skipped \(skipped) unsupported.", comment: "Folder-link success summary with skipped count. Placeholders are linked and skipped counts.")
        } else {
            message = String(localized: "Linked \(imported) project folders to your library.", comment: "Folder-link success summary. Placeholder is the linked project count; source folders remain in place.")
        }
        WorkshopToastCenter.shared.post(
            headline: String(localized: "Linked", comment: "Folder-link success toast headline."),
            title: folder.lastPathComponent,
            message: message,
            isSuccess: true
        )
    }

    /// A folder with `project.json` imports as itself; otherwise it is treated as
    /// a library root and its immediate `project.json`-bearing subfolders import.
    private func discoverProjectFolders(in root: URL) -> [URL] {
        if fileManager.fileExists(atPath: root.appendingPathComponent("project.json").path) {
            return [root]
        }

        guard let children = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        return children.filter { child in
            let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return isDir && fileManager.fileExists(atPath: child.appendingPathComponent("project.json").path)
        }
    }
}
#endif
