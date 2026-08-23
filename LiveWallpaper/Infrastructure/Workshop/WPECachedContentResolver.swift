#if !LITE_BUILD
import Foundation
import LiveWallpaperCore
import LiveWallpaperProWPE

@MainActor
struct WPECachedContentResolver {
    private let applicationSupportRootURL: URL
    private let fileManager: FileManager
    private let makeBookmark: @MainActor @Sendable (URL) -> Data?

    init(
        applicationSupportRootURL: URL? = nil,
        fileManager: FileManager = .default,
        makeBookmark: @escaping @MainActor @Sendable (URL) -> Data? = { url in
            ResourceUtilities.createBookmark(for: url)
        }
    ) {
        self.fileManager = fileManager
        if let applicationSupportRootURL {
            self.applicationSupportRootURL = applicationSupportRootURL
        } else if let applicationSupport = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) {
            self.applicationSupportRootURL = applicationSupport.appendingPathComponent("LiveWallpaper", isDirectory: true)
        } else {
            self.applicationSupportRootURL = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support/LiveWallpaper", isDirectory: true)
        }
        self.makeBookmark = makeBookmark
    }

    func content(for origin: WPEOrigin) -> WallpaperContent? {
        switch origin.resourceLocation {
        case .cache:
            // Rebuild legacy `.cache` imports from source; missing source is permanent loss.
            return sourceFolderContent(for: origin) ?? cacheContent(for: origin)
        case .sourceFolder:
            return sourceFolderContent(for: origin)
        default:
            return nil
        }
    }

    /// Rebuild `.sourceFolder` video/web in place (needed for bookmarking unpackaged items).
    private func sourceFolderContent(for origin: WPEOrigin) -> WallpaperContent? {
        guard let entryFile = origin.entryFile, !entryFile.isEmpty else { return nil }
        guard let folderURL = try? SecurityScopedBookmarkResolver.shared
            .resolve(origin.sourceFolderBookmark, target: .transient).get().url
        else { return nil }
        let didStart = folderURL.startAccessingSecurityScopedResource()
        defer { if didStart { folderURL.stopAccessingSecurityScopedResource() } }

        let looseEntryURL = WPEPathSafety.resourceURL(root: folderURL, relativePath: entryFile)
        let looseEntryExists = looseEntryURL.map { fileManager.fileExists(atPath: $0.path) } ?? false
        let pkgURL = folderURL.appendingPathComponent("scene.pkg")
        let packagedEntryExists = fileManager.fileExists(atPath: pkgURL.path)
            && Self.packageContainsEntry(pkgURL, relativePath: entryFile)

        switch origin.originalType {
        case .video:
            if looseEntryExists, let entryURL = looseEntryURL, let bookmark = makeBookmark(entryURL) {
                return .video(bookmarkData: bookmark)
            }
            if packagedEntryExists, let bookmark = makeBookmark(pkgURL) {
                return .video(bookmarkData: bookmark, packageEntryName: entryFile)
            }
            return nil
        case .web:
            // Index may be loose or inside scene.pkg; the scheme handler serves
            // loose files first, then package entries. Bookmark the folder.
            guard looseEntryExists || packagedEntryExists,
                  let bookmark = makeBookmark(folderURL) else { return nil }
            return .html(
                source: .folder(bookmarkData: bookmark, indexFileName: entryFile),
                config: HTMLConfig(
                    physicalPixelLayout: defaultHTMLPhysicalPixelLayout(
                        folderURL: folderURL,
                        indexFileName: entryFile
                    ),
                    originKind: origin.originKind
                )
            )
        case .scene, .application, .unknown:
            return nil
        }
    }

    private static func packageContainsEntry(_ pkgURL: URL, relativePath: String) -> Bool {
        guard let provider = try? WPEPackageSceneAssetProvider(packageURL: pkgURL) else { return false }
        return provider.exists(atRelativePath: relativePath)
    }

    private func cacheContent(for origin: WPEOrigin) -> WallpaperContent? {
        guard origin.resourceLocation == .cache,
              let cacheRelativePath = origin.cacheRelativePath,
              WPEPathSafety.isSafeCacheRelativePath(cacheRelativePath),
              let entryFile = origin.entryFile,
              !entryFile.isEmpty else {
            return nil
        }

        let safeSupportRoot = applicationSupportRootURL.standardizedFileURL.resolvingSymlinksInPath()
        let cacheURL = safeSupportRoot
            .appendingPathComponent(cacheRelativePath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard WPEPathSafety.contains(cacheURL, in: safeSupportRoot) else {
            return nil
        }
        let entryURLCandidate = WPEPathSafety.resourceURL(root: cacheURL, relativePath: entryFile)
        let entryExistsInCache = entryURLCandidate.map { fileManager.fileExists(atPath: $0.path) } ?? false

        // Prefer source rebuild over stale cache; cache only if source is gone.
        if origin.originalType == .scene,
           let sourceBacked = sourceBackedSceneContent(
               for: origin,
               cacheRelativePath: cacheRelativePath,
               entryFile: entryFile
           ) {
            return sourceBacked
        }

        guard let entryURL = entryURLCandidate, entryExistsInCache else {
            return nil
        }

        switch origin.originalType {
        case .video:
            guard let bookmark = makeBookmark(entryURL) else { return nil }
            return .video(bookmarkData: bookmark)
        case .web:
            guard let bookmark = makeBookmark(cacheURL) else { return nil }
            return .html(
                source: .folder(bookmarkData: bookmark, indexFileName: entryFile),
                config: HTMLConfig(
                    physicalPixelLayout: defaultHTMLPhysicalPixelLayout(
                        folderURL: cacheURL,
                        indexFileName: entryFile
                    ),
                    originKind: origin.originKind
                )
            )
        case .scene:
            var tier: SceneCapabilityTier = .unsupported
            var preflightTier: WPEScenePreflightTier?
            var preflightFeatureFlags: [WPESceneFeatureFlag] = []
            do {
                let data = try Data(contentsOf: entryURL)
                let document = try WPESceneDocumentParser.parse(data: data)
                let dependencyMounts = WPEDependencyMountResolver().mounts(
                    dependencyWorkshopIDs: origin.dependencyWorkshopIDs,
                    origin: origin
                )
                let engineRoot = WPEEngineAssetsLibrary.shared.resolveAuthorizedRoot()
                tier = WPESceneCapabilityClassifier().capabilityTier(
                    for: document,
                    cacheURL: cacheURL,
                    dependencyMounts: dependencyMounts,
                    engineAssetsRootURL: engineRoot
                )
                let synthesizedProject = WallpaperEngineProject(
                    workshopID: origin.workshopID,
                    title: origin.title,
                    entryFile: entryFile,
                    type: origin.originalType,
                    previewFileName: origin.previewFileName,
                    propertyCount: 0,
                    dependencyWorkshopIDs: origin.dependencyWorkshopIDs,
                    requiresWindowsPlugin: origin.requiresWindowsPlugin
                )
                let preflight = WPEScenePreflight.classify(
                    document: document,
                    project: synthesizedProject,
                    scenePackageEntries: scenePackageEntryNames(in: cacheURL, fileManager: fileManager)
                )
                preflightTier = preflight.tier
                preflightFeatureFlags = sortedPreflightFeatureFlags(preflight.featureFlags)
            } catch {
            }
            return .scene(SceneDescriptor(
                workshopID: origin.workshopID,
                cacheRelativePath: cacheRelativePath,
                entryFile: entryFile,
                capabilityTier: tier,
                dependencyWorkshopIDs: origin.dependencyWorkshopIDs,
                preflightTier: preflightTier,
                preflightFeatureFlags: preflightFeatureFlags
            ))
        case .application, .unknown:
            return nil
        }
    }

    /// Rebuild favorites/history scene content from source folder or scene.pkg.
    private func sourceBackedSceneContent(
        for origin: WPEOrigin,
        cacheRelativePath: String,
        entryFile: String
    ) -> WallpaperContent? {
        guard let folderURL = try? SecurityScopedBookmarkResolver.shared
            .resolve(origin.sourceFolderBookmark, target: .transient).get().url
        else { return nil }
        let didStart = folderURL.startAccessingSecurityScopedResource()
        defer { if didStart { folderURL.stopAccessingSecurityScopedResource() } }

        let provider: any WPESceneAssetProvider
        let assetStorage: SceneAssetStorage
        let sceneData: Data

        let packageURL = folderURL.appendingPathComponent("scene.pkg", isDirectory: false)
        if fileManager.fileExists(atPath: packageURL.path),
           let packageProvider = try? WPEPackageSceneAssetProvider(packageURL: packageURL),
           let packageSceneData = try? packageProvider.data(atRelativePath: entryFile) {
            provider = packageProvider
            assetStorage = .packageSource(fileName: packageURL.lastPathComponent)
            sceneData = packageSceneData
        } else {
            let directoryProvider = WPEDirectorySceneAssetProvider(rootURL: folderURL)
            guard let directorySceneData = try? directoryProvider.data(atRelativePath: entryFile) else {
                return nil
            }
            provider = directoryProvider
            assetStorage = .sourceDirectory
            sceneData = directorySceneData
        }
        guard let document = try? WPESceneDocumentParser.parse(data: sceneData) else {
            return nil
        }

        let dependencyMounts = WPEDependencyMountResolver().mounts(
            dependencyWorkshopIDs: origin.dependencyWorkshopIDs,
            origin: origin
        )
        let engineRoot = WPEEngineAssetsLibrary.shared.resolveAuthorizedRoot()
        let tier = WPESceneCapabilityClassifier().capabilityTier(
            for: document,
            primaryProvider: provider,
            dependencyMounts: dependencyMounts,
            engineAssetsRootURL: engineRoot
        )
        let synthesizedProject = WallpaperEngineProject(
            workshopID: origin.workshopID,
            title: origin.title,
            entryFile: entryFile,
            type: origin.originalType,
            previewFileName: origin.previewFileName,
            propertyCount: 0,
            dependencyWorkshopIDs: origin.dependencyWorkshopIDs,
            requiresWindowsPlugin: origin.requiresWindowsPlugin
        )
        let preflight = WPEScenePreflight.classify(
            document: document,
            project: synthesizedProject,
            scenePackageEntries: provider.entryNames
        )
        return .scene(SceneDescriptor(
            workshopID: origin.workshopID,
            cacheRelativePath: cacheRelativePath,
            entryFile: entryFile,
            capabilityTier: tier,
            assetStorage: assetStorage,
            dependencyWorkshopIDs: origin.dependencyWorkshopIDs,
            preflightTier: preflight.tier,
            preflightFeatureFlags: sortedPreflightFeatureFlags(preflight.featureFlags)
        ))
    }

}

/// Scene-cache file list for preflight custom-shader probes.
private func scenePackageEntryNames(
    in rootURL: URL,
    fileManager: FileManager,
    limit: Int = 10_000
) -> [String] {
    guard limit > 0,
          let enumerator = fileManager.enumerator(
              at: rootURL,
              includingPropertiesForKeys: [.isRegularFileKey],
              options: [.skipsHiddenFiles, .skipsPackageDescendants]
          ) else {
        return []
    }

    var entries: [String] = []
    entries.reserveCapacity(min(limit, 256))
    for case let url as URL in enumerator {
        guard entries.count < limit else { break }
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            continue
        }
        entries.append(url.lastPathComponent)
    }
    return entries
}


#endif
