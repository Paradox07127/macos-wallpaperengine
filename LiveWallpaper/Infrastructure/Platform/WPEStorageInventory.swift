#if !LITE_BUILD
import Foundation
import LiveWallpaperCore
import LiveWallpaperProWPE

struct WPEStorageInventory: Sendable {
    struct ProjectEntry: Sendable, Identifiable {
        let workshopID: String
        let sizeBytes: UInt64
        let folderURL: URL
        var id: String {
            workshopID
        }
    }

    /// Downloaded Workshop wallpapers, largest first.
    let projects: [ProjectEntry]
    let projectsTotalBytes: UInt64
    let projectsRootURL: URL?
    /// The bookmarked Steam library `projectsRootURL` sits under. Revealing the
    /// tree needs its scope, and a derived child URL cannot open one itself.
    var projectsScopeRootURL: URL?
    /// Footprint of the linked Wallpaper Engine assets, 0 when none is linked.
    let engineAssetsBytes: UInt64
    let engineAssetsURL: URL?
    var engineAssetsScopeRootURL: URL?
    var isIncomplete = false

    struct ScanRoots: Sendable {
        let steamRoot: URL?
        let engineAssetsRoot: URL?
    }

    @MainActor
    static func compute(doctor: SteamCMDDoctorService) async -> WPEStorageInventory {
        let steamAccess = try? doctor.beginWorkdirAccess()
        let steamRoot = steamAccess?.url
        let assetsAccess = WPEEngineAssetsLibrary.shared.beginAuthorizedRootAccess()
        let steamScopeRoot = steamAccess?.scopedURL
        defer {
            steamAccess?.end()
            assetsAccess?.end()
        }
        var inventory = await WPEStorageInventoryScanner.shared.scan(
            roots: ScanRoots(steamRoot: steamRoot, engineAssetsRoot: assetsAccess?.root)
        )
        inventory.engineAssetsScopeRootURL = assetsAccess?.scopedURL
        inventory.projectsScopeRootURL = steamScopeRoot
        return inventory
    }
}

actor WPEStorageInventoryScanner {
    static let shared = WPEStorageInventoryScanner()

    /// The actor owns its `FileManager`: the shared instance is not `Sendable`,
    /// and a per-pass enumerator must not race the main actor's own file work.
    private let fileManager = FileManager()

    func scan(
        roots: WPEStorageInventory.ScanRoots,
        budget: Int = WPEStoragePaths.defaultWalkBudget
    ) -> WPEStorageInventory {
        // A budget PER ROOT, not one shared across both: a shared counter let whichever ran first spend it all and report the other as empty.
        var complete = true
        var assetsVisited = 0
        let (assetsBytes, assetsURL) = scanEngineAssets(
            root: roots.engineAssetsRoot,
            budget: budget,
            visited: &assetsVisited,
            complete: &complete
        )
        var projectsVisited = 0
        let (projects, root) = scanProjects(
            steamRoot: roots.steamRoot,
            budget: budget,
            visited: &projectsVisited,
            complete: &complete
        )
        let isIncomplete = !complete || assetsVisited >= budget || projectsVisited >= budget
        if isIncomplete {
            Logger.warning(
                "Storage inventory stopped early or hit unreadable entries (budget \(budget)); reported sizes are lower bounds",
                category: .fileAccess
            )
        }
        return WPEStorageInventory(
            projects: projects,
            projectsTotalBytes: projects.reduce(0) { $0 + $1.sizeBytes },
            projectsRootURL: root,
            projectsScopeRootURL: roots.steamRoot,
            engineAssetsBytes: assetsBytes,
            engineAssetsURL: assetsURL,
            isIncomplete: isIncomplete
        )
    }

    private func scanProjects(
        steamRoot: URL?,
        budget: Int,
        visited: inout Int,
        complete: inout Bool
    ) -> ([WPEStorageInventory.ProjectEntry], URL?) {
        guard let steamRoot else { return ([], nil) }
        let root = steamRoot.appendingPathComponent(
            "steamapps/workshop/content/\(SteamCMDDoctorService.wallpaperEngineAppID)",
            isDirectory: true
        )
        let children: [URL]
        do {
            children = try fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            let cocoa = error as NSError
            let missing = cocoa.domain == NSCocoaErrorDomain && cocoa.code == NSFileReadNoSuchFileError
            // A reachable library without the content folder has simply downloaded nothing yet.
            if !missing || (try? steamRoot.checkResourceIsReachable()) != true {
                complete = false
            }
            return ([], nil)
        }

        var entries: [WPEStorageInventory.ProjectEntry] = []
        for child in children {
            guard !Task.isCancelled, visited < budget else {
                complete = false
                break
            }
            let id = child.lastPathComponent
            guard WPEPathSafety.isSafeProjectID(id) else { continue }
            guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
                complete = false
                continue
            }
            // A symlinked id folder could point anywhere; refuse to walk it.
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
            let bytes = WPEStoragePaths.allocatedBytes(
                at: child,
                fileManager: fileManager,
                budget: budget,
                visited: &visited,
                complete: &complete
            )
            guard bytes > 0 else { continue }
            entries.append(
                WPEStorageInventory.ProjectEntry(workshopID: id, sizeBytes: bytes, folderURL: child)
            )
        }
        return (entries.sorted { $0.sizeBytes > $1.sizeBytes }, root)
    }

    private func scanEngineAssets(
        root: URL?,
        budget: Int,
        visited: inout Int,
        complete: inout Bool
    ) -> (UInt64, URL?) {
        guard let root else { return (0, nil) }
        guard fileManager.fileExists(atPath: root.path(percentEncoded: false)) else {
            complete = false
            return (0, nil)
        }
        let bytes = WPEStoragePaths.allocatedBytes(
            at: root,
            fileManager: fileManager,
            budget: budget,
            visited: &visited,
            complete: &complete
        )
        return bytes > 0 ? (bytes, root) : (0, nil)
    }
}
#endif
