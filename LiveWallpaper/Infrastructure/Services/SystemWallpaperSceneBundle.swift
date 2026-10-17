#if !LITE_BUILD
import Foundation
import LiveWallpaperCore
import LiveWallpaperProWPE

enum SystemWallpaperSceneBundle {
    /// Materialise packages and dependencies once so a sandboxed provider needs no original bookmarks.
    static func stage(source: SystemWallpaperSceneSource, at bundle: URL, framesPerSecond: Int = 30,
                      renderSize: CGSize = CGSize(width: 1920, height: 1080)) throws {
        let manager = FileManager.default
        let assets = bundle.appendingPathComponent("Assets", isDirectory: true)
        try copy(provider: source.provider, to: assets)
        let project = source.projectRoot.appendingPathComponent("project.json")
        if !manager.fileExists(atPath: assets.appendingPathComponent("project.json").path),
           (try? project.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            try manager.copyItem(at: project, to: assets.appendingPathComponent("project.json"))
        }
        var dependencies: [SystemWallpaperSceneConfiguration.Dependency] = []
        for (index, mount) in source.mounts.enumerated() {
            try Task.checkCancellation()
            let directory = "Dependency-\(index)"
            let provider: any WPESceneAssetProvider = switch mount.backing {
            case let .directory(root): WPEDirectorySceneAssetProvider(rootURL: root)
            case let .package(url): try WPEPackageSceneAssetProvider(packageURL: url)
            }
            try copy(provider: provider, to: bundle.appendingPathComponent(directory, isDirectory: true))
            dependencies.append(.init(workshopID: mount.workshopID, directory: directory))
        }
        if let engineRoot = source.engineRoot {
            try SecurityScopedBookmarkResolver.withScopedAccess(engineRoot) { _ in
                try copy(provider: WPEDirectorySceneAssetProvider(rootURL: engineRoot),
                         to: bundle.appendingPathComponent("Engine", isDirectory: true))
            }
        }
        let configuration = SystemWallpaperSceneConfiguration(
            descriptor: source.descriptor, dependencies: dependencies, hasEngineAssets: source.engineRoot != nil,
            framesPerSecond: framesPerSecond, renderSize: renderSize
        )
        try JSONEncoder().encode(configuration).write(to: bundle.appendingPathComponent("configuration.json"), options: .atomic)
    }

    private static func copy(provider: any WPESceneAssetProvider, to root: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        for name in provider.entryNames {
            try Task.checkCancellation()
            guard WPEPathSafety.isSafeRelativePath(name),
                  let destination = WPEPathSafety.resourceURL(root: root, relativePath: name) else {
                throw WPESceneAssetProviderError.invalidRelativePath(name)
            }
            let source = try provider.stagedURL(atRelativePath: name)
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.copyItem(at: source, to: destination)
        }
    }
}
#endif
