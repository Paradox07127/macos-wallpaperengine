#if !LITE_BUILD
import Foundation
import LiveWallpaperCore
import LiveWallpaperProWPE

/// Read-only allocated-size inventory inside the Steam-library security scope.
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
    /// Root of the Workshop content tree, for "show in Finder".
    let projectsRootURL: URL?
    /// The bookmarked Steam library `projectsRootURL` sits under. Revealing the
    /// tree needs its scope, and a derived child URL cannot open one itself.
    let projectsScopeRootURL: URL?
    /// Footprint of the linked Wallpaper Engine assets, 0 when none is linked.
    let engineAssetsBytes: UInt64
    let engineAssetsURL: URL?

    /// Roots resolved on the main actor. Both services that produce them are
    /// `@MainActor`, and a security scope is process-wide once opened, so the
    /// caller keeps the scopes open across the walk and closes them after.
    struct ScanRoots: Sendable {
        let steamRoot: URL?
        let engineAssetsRoot: URL?
    }

    /// Resolves the roots and opens their scopes on the main actor, then walks
    /// the trees off it. The walk is recursive over a user-sized library, which
    /// is why it must not run on the main actor; cancelling the calling task
    /// stops it at the next entry.
    @MainActor
    static func compute(doctor: SteamCMDDoctorService) async -> WPEStorageInventory {
        let steamRoot = try? doctor.resolveWorkdirURL()
        let engineAssetsRoot = WPEEngineAssetsLibrary.managedInstallRoot()
        let steamScope = steamRoot?.startAccessingSecurityScopedResource() ?? false
        let assetsScope = engineAssetsRoot?.startAccessingSecurityScopedResource() ?? false
        defer {
            if steamScope {
                steamRoot?.stopAccessingSecurityScopedResource()
            }
            if assetsScope {
                engineAssetsRoot?.stopAccessingSecurityScopedResource()
            }
        }
        return await WPEStorageInventoryScanner.shared.scan(
            roots: ScanRoots(steamRoot: steamRoot, engineAssetsRoot: engineAssetsRoot)
        )
    }
}

/// Runs inventory passes off the main actor and serialises them against each
/// other. Reached through `WPEStorageInventory.compute`, which owns the scopes.
actor WPEStorageInventoryScanner {
    static let shared = WPEStorageInventoryScanner()

    /// The actor owns its `FileManager`: the shared instance is not `Sendable`,
    /// and a per-pass enumerator must not race the main actor's own file work.
    private let fileManager = FileManager()

    func scan(
        roots: WPEStorageInventory.ScanRoots,
        budget: Int = WPEStoragePaths.defaultWalkBudget
    ) -> WPEStorageInventory {
        // A budget PER ROOT, not one shared across both: the two trees are
        // independent and unequal — engine assets is one app-managed directory,
        // the Steam root grows with the user's library — so a shared counter let
        // whichever ran first spend it all and report the other as empty.
        var assetsVisited = 0
        let (assetsBytes, assetsURL) = scanEngineAssets(
            root: roots.engineAssetsRoot,
            budget: budget,
            visited: &assetsVisited
        )
        var projectsVisited = 0
        let (projects, root) = scanProjects(
            steamRoot: roots.steamRoot,
            budget: budget,
            visited: &projectsVisited
        )
        if assetsVisited >= budget || projectsVisited >= budget {
            Logger.warning(
                "Storage inventory stopped at its \(budget)-entry budget; reported sizes are lower bounds",
                category: .fileAccess
            )
        }
        return WPEStorageInventory(
            projects: projects,
            projectsTotalBytes: projects.reduce(0) { $0 + $1.sizeBytes },
            projectsRootURL: root,
            projectsScopeRootURL: roots.steamRoot,
            engineAssetsBytes: assetsBytes,
            engineAssetsURL: assetsURL
        )
    }

    /// Size of every workshop content folder in the authorized Steam library.
    private func scanProjects(
        steamRoot: URL?,
        budget: Int,
        visited: inout Int
    ) -> ([WPEStorageInventory.ProjectEntry], URL?) {
        guard let steamRoot else { return ([], nil) }
        let root = steamRoot.appendingPathComponent(
            "steamapps/workshop/content/\(SteamCMDDoctorService.wallpaperEngineAppID)",
            isDirectory: true
        )
        guard let children = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return ([], nil) }

        var entries: [WPEStorageInventory.ProjectEntry] = []
        for child in children {
            guard !Task.isCancelled, visited < budget else { break }
            let id = child.lastPathComponent
            // A symlinked id folder could point anywhere; refuse to walk it.
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard WPEPathSafety.isSafeProjectID(id),
                  values?.isDirectory == true,
                  values?.isSymbolicLink != true else { continue }
            let bytes = WPEStoragePaths.allocatedBytes(
                at: child,
                fileManager: fileManager,
                budget: budget,
                visited: &visited
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
        visited: inout Int
    ) -> (UInt64, URL?) {
        guard let root,
              fileManager.fileExists(atPath: root.path(percentEncoded: false)) else { return (0, nil) }
        let bytes = WPEStoragePaths.allocatedBytes(
            at: root,
            fileManager: fileManager,
            budget: budget,
            visited: &visited
        )
        return bytes > 0 ? (bytes, root) : (0, nil)
    }
}
#endif
