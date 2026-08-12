#if !LITE_BUILD
import Foundation
import LiveWallpaperProWPE

/// Read-only allocated-size inventory inside the Steam-library security scope.
struct WPEStorageInventory: Sendable {
    struct ProjectEntry: Sendable, Identifiable {
        let workshopID: String
        let sizeBytes: UInt64
        let folderURL: URL
        var id: String { workshopID }
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

    @MainActor
    static func compute(
        doctor: SteamCMDDoctorService,
        fileManager: FileManager = .default
    ) -> WPEStorageInventory {
        let (assetsBytes, assetsURL) = scanEngineAssets(fileManager: fileManager)
        let (projects, root, scopeRoot) = scanProjects(doctor: doctor, fileManager: fileManager)
        return WPEStorageInventory(
            projects: projects,
            projectsTotalBytes: projects.reduce(0) { $0 + $1.sizeBytes },
            projectsRootURL: root,
            projectsScopeRootURL: scopeRoot,
            engineAssetsBytes: assetsBytes,
            engineAssetsURL: assetsURL
        )
    }

    /// Size of one workshop content folder in the authorized Steam library.
    @MainActor
    private static func scanProjects(
        doctor: SteamCMDDoctorService,
        fileManager fm: FileManager
    ) -> ([ProjectEntry], URL?, URL?) {
        guard let steamRoot = try? doctor.resolveWorkdirURL() else { return ([], nil, nil) }
        let scope = steamRoot.startAccessingSecurityScopedResource()
        defer { if scope { steamRoot.stopAccessingSecurityScopedResource() } }

        let root = steamRoot.appendingPathComponent(
            "steamapps/workshop/content/\(SteamCMDDoctorService.wallpaperEngineAppID)",
            isDirectory: true
        )
        guard let children = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return ([], nil, nil) }

        var entries: [ProjectEntry] = []
        for child in children {
            let id = child.lastPathComponent
            // A symlinked id folder could point anywhere; refuse to walk it.
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard WPEPathSafety.isSafeWorkshopID(id),
                  values?.isDirectory == true,
                  values?.isSymbolicLink != true else { continue }
            let bytes = WPEStoragePaths.allocatedBytes(at: child, fileManager: fm)
            guard bytes > 0 else { continue }
            entries.append(ProjectEntry(workshopID: id, sizeBytes: bytes, folderURL: child))
        }
        return (entries.sorted { $0.sizeBytes > $1.sizeBytes }, root, steamRoot)
    }

    @MainActor
    private static func scanEngineAssets(fileManager fm: FileManager) -> (UInt64, URL?) {
        guard let root = WPEEngineAssetsLibrary.managedInstallRoot() else { return (0, nil) }
        let scope = root.startAccessingSecurityScopedResource()
        defer { if scope { root.stopAccessingSecurityScopedResource() } }
        guard fm.fileExists(atPath: root.path(percentEncoded: false)) else { return (0, nil) }
        let bytes = WPEStoragePaths.allocatedBytes(at: root, fileManager: fm)
        return bytes > 0 ? (bytes, root) : (0, nil)
    }
}
#endif
