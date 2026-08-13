#if !LITE_BUILD
import Foundation
import LiveWallpaperCore
import LiveWallpaperProWPE

/// Workshop import: project.json → in-place WallpaperContent (no wpe-cache extract).
@MainActor
final class WallpaperEngineImportService {
    enum ImportResult: Equatable, Sendable {
        case ready(WallpaperContent, origin: WPEOrigin)
        case unsupported(origin: WPEOrigin)
        case rejected(reason: String)
    }

    private let fileManager: FileManager
    private let validateVideo: @Sendable (URL) async throws -> Void
    private let makeBookmark: @MainActor @Sendable (URL) -> Data?

    init(
        fileManager: FileManager = .default,
        validateVideo: @escaping @Sendable (URL) async throws -> Void = { url in
            try await PlayableVideoLoader.validatePlayableVideo(at: url)
        },
        makeBookmark: @escaping @MainActor @Sendable (URL) -> Data? = { url in
            ResourceUtilities.createBookmark(for: url)
        }
    ) {
        self.fileManager = fileManager
        self.validateVideo = validateVideo
        self.makeBookmark = makeBookmark
    }

    func importProject(folder folderURL: URL) async throws -> ImportResult {
        let project = try WallpaperEngineProject.read(from: folderURL)
        guard let sourceBookmark = makeBookmark(folderURL) else {
            return .rejected(reason: "Cannot create source folder bookmark")
        }

        switch project.type {
        case .video:
            return await importVideo(project: project, folderURL: folderURL, sourceBookmark: sourceBookmark)
        case .web:
            return await importWeb(project: project, folderURL: folderURL, sourceBookmark: sourceBookmark)
        case .scene:
            return await importScene(project: project, folderURL: folderURL, sourceBookmark: sourceBookmark)
        case .application, .unknown:
            return .unsupported(origin: makeOrigin(
                project: project,
                sourceBookmark: sourceBookmark,
                cacheRelativePath: nil,
                resourceLocation: .unsupported
            ))
        }
    }

    private func importVideo(
        project: WallpaperEngineProject,
        folderURL: URL,
        sourceBookmark: Data
    ) async -> ImportResult {
        let pkgURL = folderURL.appendingPathComponent("scene.pkg")
        if fileManager.fileExists(atPath: pkgURL.path) {
            return await importPackagedVideo(project: project, pkgURL: pkgURL, sourceBookmark: sourceBookmark)
        }
        return await importUnpackagedVideo(project: project, folderURL: folderURL, sourceBookmark: sourceBookmark)
    }

    /// In-place packaged video via ranged resource loader (+ one-shot playability probe).
    private func importPackagedVideo(
        project: WallpaperEngineProject,
        pkgURL: URL,
        sourceBookmark: Data
    ) async -> ImportResult {
        guard let provider = try? await WPEPackageSceneAssetProvider.open(packageURL: pkgURL),
              provider.exists(atRelativePath: project.entryFile) else {
            return .rejected(reason: "Missing video entry \(project.entryFile) in package")
        }

        // Provider's staging dir is removed on deinit (after this scope), so
        // nothing persists. Playback reads the entry windowed, in place.
        do {
            let stagedURL = try provider.stagedURL(atRelativePath: project.entryFile)
            try await validateVideo(stagedURL)
        } catch {
            return .rejected(reason: describe(error))
        }


        guard let videoBookmark = makeBookmark(pkgURL) else {
            return .rejected(reason: "Cannot create video package bookmark")
        }

        let origin = makeOrigin(
            project: project,
            sourceBookmark: sourceBookmark,
            cacheRelativePath: nil,
            resourceLocation: .sourceFolder
        )
        return .ready(
            .video(bookmarkData: videoBookmark, packageEntryName: project.entryFile),
            origin: origin
        )
    }

    private func importUnpackagedVideo(
        project: WallpaperEngineProject,
        folderURL: URL,
        sourceBookmark: Data
    ) async -> ImportResult {
        guard let videoURL = WPEPathSafety.resourceURL(root: folderURL, relativePath: project.entryFile),
              fileManager.fileExists(atPath: videoURL.path) else {
            return .rejected(reason: "Missing video entry \(project.entryFile)")
        }

        do {
            try await validateVideo(videoURL)
        } catch {
            return .rejected(reason: describe(error))
        }

        guard let videoBookmark = makeBookmark(videoURL) else {
            return .rejected(reason: "Cannot create video bookmark")
        }

        let origin = makeOrigin(
            project: project,
            sourceBookmark: sourceBookmark,
            cacheRelativePath: nil,
            resourceLocation: .sourceFolder
        )
        return .ready(.video(bookmarkData: videoBookmark), origin: origin)
    }

    private func importWeb(
        project: WallpaperEngineProject,
        folderURL: URL,
        sourceBookmark: Data
    ) async -> ImportResult {
        let pkgURL = folderURL.appendingPathComponent("scene.pkg")
        if fileManager.fileExists(atPath: pkgURL.path) {
            return await importPackagedWeb(
                project: project,
                folderURL: folderURL,
                pkgURL: pkgURL,
                sourceBookmark: sourceBookmark
            )
        }

        guard let indexURL = WPEPathSafety.resourceURL(root: folderURL, relativePath: project.entryFile),
              fileManager.fileExists(atPath: indexURL.path) else {
            return .rejected(reason: "Missing web entry \(project.entryFile)")
        }

        guard let folderBookmark = makeBookmark(folderURL) else {
            return .rejected(reason: "Cannot create web folder bookmark")
        }

        let originKind = WallpaperEngineImportService.originKind(forSourceFolder: folderURL)
        let origin = makeOrigin(
            project: project,
            sourceBookmark: sourceBookmark,
            cacheRelativePath: nil,
            resourceLocation: .sourceFolder,
            originKind: originKind
        )
        let content = WallpaperContent.html(
            source: .folder(bookmarkData: folderBookmark, indexFileName: project.entryFile),
            config: HTMLConfig(
                physicalPixelLayout: defaultHTMLPhysicalPixelLayout(
                    folderURL: folderURL,
                    indexFileName: project.entryFile
                ),
                originKind: originKind
            )
        )
        return .ready(content, origin: origin)
    }

    /// In-place packaged web via scheme handler (loose files first, then pkg entries).
    private func importPackagedWeb(
        project: WallpaperEngineProject,
        folderURL: URL,
        pkgURL: URL,
        sourceBookmark: Data
    ) async -> ImportResult {
        if let provider = try? await WPEPackageSceneAssetProvider.open(packageURL: pkgURL),
           provider.exists(atRelativePath: project.entryFile) {
            guard let folderBookmark = makeBookmark(folderURL) else {
                return .rejected(reason: "Cannot create web folder bookmark")
            }
            let originKind = WallpaperEngineImportService.originKind(forSourceFolder: folderURL)
            let origin = makeOrigin(
                project: project,
                sourceBookmark: sourceBookmark,
                cacheRelativePath: nil,
                resourceLocation: .sourceFolder,
                originKind: originKind
            )
            let content = WallpaperContent.html(
                source: .folder(bookmarkData: folderBookmark, indexFileName: project.entryFile),
                config: HTMLConfig(
                    physicalPixelLayout: defaultHTMLPhysicalPixelLayout(
                        folderURL: folderURL,
                        indexFileName: project.entryFile
                    ),
                    originKind: originKind
                )
            )
            return .ready(content, origin: origin)
        }

        return .rejected(reason: "Missing web entry \(project.entryFile) in package")
    }


    /// `.workshopImport` only under steamapps/workshop/content/431960/<id>/; else `.userLocal`.
    static func originKind(forSourceFolder folderURL: URL) -> HTMLOriginKind {
        let canonical = folderURL.standardizedFileURL.resolvingSymlinksInPath().path
        let components = canonical.split(separator: "/", omittingEmptySubsequences: true)
        guard let id = components.last,
              UInt64(id) != nil,
              components.count >= 5 else {
            return .userLocal
        }
        let tail = components.suffix(5)
        let tailArray = Array(tail)
        // Layout: steamapps / workshop / content / 431960 / <pubfileid>
        guard tailArray[0] == "steamapps",
              tailArray[1] == "workshop",
              tailArray[2] == "content",
              tailArray[3] == "431960" else {
            return .userLocal
        }
        return .workshopImport
    }

    private func importScene(
        project: WallpaperEngineProject,
        folderURL: URL,
        sourceBookmark: Data
    ) async -> ImportResult {
        if project.requiresWindowsPlugin {
            return .unsupported(origin: makeOrigin(
                project: project,
                sourceBookmark: sourceBookmark,
                cacheRelativePath: nil,
                resourceLocation: .unsupported
            ))
        }

        let missingDeps = await missingDependencies(
            declared: project.dependencyWorkshopIDs,
            sourceFolderURL: folderURL
        )
        if !missingDeps.isEmpty {
            return .unsupported(origin: makeOrigin(
                project: project,
                sourceBookmark: sourceBookmark,
                cacheRelativePath: nil,
                resourceLocation: .unsupported,
                missingDependencyIDs: missingDeps
            ))
        }

        let pkgURL = folderURL.appendingPathComponent("scene.pkg")
        if fileManager.fileExists(atPath: pkgURL.path) {
            // Unopenable package is unsupported (same parser as the old extract path).
            if let packageResult = await finishScenePackageBackedImport(
                project: project,
                pkgURL: pkgURL,
                sourceBookmark: sourceBookmark
            ) {
                return packageResult
            }
            return .rejected(reason: "Packaged scene \(project.entryFile) could not be read from the package")
        }

        guard let entryURL = WPEPathSafety.resourceURL(root: folderURL, relativePath: project.entryFile),
              fileManager.fileExists(atPath: entryURL.path) else {
            return .unsupported(origin: makeOrigin(
                project: project,
                sourceBookmark: sourceBookmark,
                cacheRelativePath: nil,
                resourceLocation: .unsupported
            ))
        }

        // If in-place reading fails it's unsupported — a mirror copies the same
        // files, so it couldn't have recovered either.
        if let directoryResult = await finishSceneSourceDirectoryImport(
            project: project,
            folderURL: folderURL,
            sourceBookmark: sourceBookmark
        ) {
            return directoryResult
        }
        return .rejected(reason: "Scene \(project.entryFile) could not be read from the source folder")
    }

    /// Returns `nil` when the package can't be opened/parsed for in-place use,
    /// in which case the caller rejects it as unsupported.
    private func finishScenePackageBackedImport(
        project: WallpaperEngineProject,
        pkgURL: URL,
        sourceBookmark: Data
    ) async -> ImportResult? {
        guard let provider = try? await WPEPackageSceneAssetProvider.open(packageURL: pkgURL),
              let sceneData = try? provider.data(atRelativePath: project.entryFile) else {
            return nil
        }
        let document: WPESceneDocument
        do {
            document = try WPESceneDocumentParser.parse(data: sceneData)
        } catch {
            return nil
        }

        let dependencyMounts = WPEDependencyMountResolver().mounts(
            dependencyWorkshopIDs: project.dependencyWorkshopIDs,
            origin: nil
        )
        let engineRoot = WPEEngineAssetsLibrary.shared.resolveAuthorizedRoot()
        let tier = WPESceneCapabilityClassifier().capabilityTier(
            for: document,
            primaryProvider: provider,
            dependencyMounts: dependencyMounts,
            engineAssetsRootURL: engineRoot
        )
        let preflight = WPEScenePreflight.classify(
            document: document,
            project: project,
            scenePackageEntries: provider.entryNames
        )
        let descriptor = SceneDescriptor(
            workshopID: project.workshopID,
            cacheRelativePath: cacheRelativePath(for: project),
            entryFile: project.entryFile,
            capabilityTier: tier,
            assetStorage: .packageSource(fileName: pkgURL.lastPathComponent),
            dependencyWorkshopIDs: project.dependencyWorkshopIDs,
            preflightTier: preflight.tier,
            preflightFeatureFlags: sortedPreflightFeatureFlags(preflight.featureFlags)
        )
        let origin = makeOrigin(
            project: project,
            sourceBookmark: sourceBookmark,
            cacheRelativePath: cacheRelativePath(for: project),
            resourceLocation: .cache
        )

        if tier == .unsupported {
            return .unsupported(origin: origin)
        }
        return .ready(.scene(descriptor), origin: origin)
    }

    /// Returns `nil` when the entry can't be read/parsed, in which case the
    /// caller rejects it as unsupported.
    private func finishSceneSourceDirectoryImport(
        project: WallpaperEngineProject,
        folderURL: URL,
        sourceBookmark: Data
    ) async -> ImportResult? {
        let provider = WPEDirectorySceneAssetProvider(rootURL: folderURL)
        guard let sceneData = try? provider.data(atRelativePath: project.entryFile) else {
            return nil
        }
        let document: WPESceneDocument
        do {
            document = try WPESceneDocumentParser.parse(data: sceneData)
        } catch {
            return nil
        }


        let dependencyMounts = WPEDependencyMountResolver().mounts(
            dependencyWorkshopIDs: project.dependencyWorkshopIDs,
            origin: nil
        )
        let engineRoot = WPEEngineAssetsLibrary.shared.resolveAuthorizedRoot()
        let tier = WPESceneCapabilityClassifier().capabilityTier(
            for: document,
            primaryProvider: provider,
            dependencyMounts: dependencyMounts,
            engineAssetsRootURL: engineRoot
        )
        let preflight = WPEScenePreflight.classify(
            document: document,
            project: project,
            scenePackageEntries: provider.entryNames
        )
        let descriptor = SceneDescriptor(
            workshopID: project.workshopID,
            cacheRelativePath: cacheRelativePath(for: project),
            entryFile: project.entryFile,
            capabilityTier: tier,
            assetStorage: .sourceDirectory,
            dependencyWorkshopIDs: project.dependencyWorkshopIDs,
            preflightTier: preflight.tier,
            preflightFeatureFlags: sortedPreflightFeatureFlags(preflight.featureFlags)
        )
        let origin = makeOrigin(
            project: project,
            sourceBookmark: sourceBookmark,
            cacheRelativePath: cacheRelativePath(for: project),
            resourceLocation: .cache
        )

        if tier == .unsupported {
            return .unsupported(origin: origin)
        }
        return .ready(.scene(descriptor), origin: origin)
    }


    private func makeOrigin(
        project: WallpaperEngineProject,
        sourceBookmark: Data,
        cacheRelativePath: String?,
        resourceLocation: WPEResourceLocation,
        missingDependencyIDs: [String] = [],
        originKind: HTMLOriginKind = .userLocal
    ) -> WPEOrigin {
        WPEOrigin(
            workshopID: project.workshopID,
            title: project.title,
            originalType: project.type,
            sourceFolderBookmark: sourceBookmark,
            cacheRelativePath: cacheRelativePath,
            previewFileName: project.previewFileName,
            entryFile: project.entryFile,
            resourceLocation: resourceLocation,
            dependencyWorkshopIDs: project.dependencyWorkshopIDs,
            missingDependencyIDs: missingDependencyIDs,
            requiresWindowsPlugin: project.requiresWindowsPlugin,
            originKind: originKind
        )
    }

    /// Returns the subset of `declared` workshop IDs whose extracted payload is NOT currently available either in our cache OR as a sibling `~/Documents/Live Wallpapers/<appid>/<wid>/` folder.
    private func missingDependencies(declared: [String], sourceFolderURL: URL) async -> [String] {
        guard !declared.isEmpty else { return [] }
        // The extraction cache is gone; a dependency is available only if Steam
        // has the sibling item in the same Workshop content directory.
        let available = subscribedWorkshopIDs(declared: declared, sourceFolderURL: sourceFolderURL)
        return declared.filter { !available.contains($0) }
    }

    /// Inspects the parent of `sourceFolderURL` (the Steam Workshop content directory) for sibling folders matching declared dependency IDs.
    private func subscribedWorkshopIDs(declared: [String], sourceFolderURL: URL) -> Set<String> {
        let workshopRoot = sourceFolderURL.deletingLastPathComponent()
        var hits: Set<String> = []
        for id in declared {
            guard WPEPathSafety.isSafeWorkshopID(id) else { continue }
            let dependencyURL = workshopRoot.appendingPathComponent(id, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: dependencyURL.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                continue
            }
            let manifest = dependencyURL.appendingPathComponent("project.json")
            if fileManager.fileExists(atPath: manifest.path) {
                hits.insert(id)
            }
        }
        return hits
    }

    private func cacheRelativePath(for project: WallpaperEngineProject) -> String {
        "wpe-cache/\(project.workshopID)"
    }


    private func describe(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }
}

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

/// `WPEScenePreflight` emits an unordered `Set` so descriptor persistence matches the historical ordering convention (alphabetical by raw value).
private func sortedPreflightFeatureFlags(_ flags: Set<WPESceneFeatureFlag>) -> [WPESceneFeatureFlag] {
    flags.sorted { $0.rawValue < $1.rawValue }
}

private func defaultHTMLPhysicalPixelLayout(folderURL: URL, indexFileName: String) -> Bool {
    HTMLWallpaperCompatibilityPolicy.shouldAutoEnablePhysicalPixelLayout(
        folderURL: folderURL,
        indexFileName: indexFileName
    )
}
#endif
