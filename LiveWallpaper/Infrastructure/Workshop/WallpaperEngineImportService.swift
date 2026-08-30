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
        /// A preset item: values for someone else's wallpaper, not a wallpaper.
        /// Callers register it in the preset library instead of installing it.
        case workshopPreset(ScenePreset)
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

        // A preset item restyles someone else's wallpaper and has no entry of
        // its own. Routed here it would fall through to the missing-entry
        // branch and be reported to the user as an unsupported wallpaper.
        if let preset = project.scenePreset() {
            return .workshopPreset(preset)
        }
        guard let sourceBookmark = makeBookmark(folderURL) else {
            return .rejected(reason: String(localized: "Cannot create source folder bookmark", bundle: .appLanguage, comment: "Wallpaper Engine import rejection reason; appears inside the invalid-package alert."))
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
            return .rejected(reason: String(localized: "Missing video entry \(project.entryFile) in package", bundle: .appLanguage, comment: "Wallpaper Engine import rejection reason; appears inside the invalid-package alert."))
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
            return .rejected(reason: String(localized: "Cannot create video package bookmark", bundle: .appLanguage, comment: "Wallpaper Engine import rejection reason; appears inside the invalid-package alert."))
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
            return .rejected(reason: String(localized: "Missing video entry \(project.entryFile)", bundle: .appLanguage, comment: "Wallpaper Engine import rejection reason; appears inside the invalid-package alert."))
        }

        do {
            try await validateVideo(videoURL)
        } catch {
            return .rejected(reason: describe(error))
        }

        guard let videoBookmark = makeBookmark(videoURL) else {
            return .rejected(reason: String(localized: "Cannot create video bookmark", bundle: .appLanguage, comment: "Wallpaper Engine import rejection reason; appears inside the invalid-package alert."))
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
            return .rejected(reason: String(localized: "Missing web entry \(project.entryFile)", bundle: .appLanguage, comment: "Wallpaper Engine import rejection reason; appears inside the invalid-package alert."))
        }

        guard let folderBookmark = makeBookmark(folderURL) else {
            return .rejected(reason: String(localized: "Cannot create web folder bookmark", bundle: .appLanguage, comment: "Wallpaper Engine import rejection reason; appears inside the invalid-package alert."))
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
                return .rejected(reason: String(localized: "Cannot create web folder bookmark", bundle: .appLanguage, comment: "Wallpaper Engine import rejection reason; appears inside the invalid-package alert."))
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

        return .rejected(reason: String(localized: "Missing web entry \(project.entryFile) in package", bundle: .appLanguage, comment: "Wallpaper Engine import rejection reason; appears inside the invalid-package alert."))
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
            return .rejected(reason: String(localized: "Packaged scene \(project.entryFile) could not be read from the package", bundle: .appLanguage, comment: "Wallpaper Engine import rejection reason; appears inside the invalid-package alert."))
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
        return .rejected(reason: String(localized: "Scene \(project.entryFile) could not be read from the source folder", bundle: .appLanguage, comment: "Wallpaper Engine import rejection reason; appears inside the invalid-package alert."))
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

    /// Dependency IDs the item at `folderURL` declares that Steam has not put
    /// next to it — the same rule `importScene` uses to mark a scene
    /// unsupported, exposed so the downloader can go fetch them.
    func missingDependencyIDs(inFolder folderURL: URL) async -> [String] {
        guard let project = try? WallpaperEngineProject.read(from: folderURL) else { return [] }
        return await missingDependencies(declared: project.dependencyWorkshopIDs, sourceFolderURL: folderURL)
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

/// `WPEScenePreflight` emits an unordered `Set` so descriptor persistence matches the historical ordering convention (alphabetical by raw value).
func sortedPreflightFeatureFlags(_ flags: Set<WPESceneFeatureFlag>) -> [WPESceneFeatureFlag] {
    flags.sorted { $0.rawValue < $1.rawValue }
}

func defaultHTMLPhysicalPixelLayout(folderURL: URL, indexFileName: String) -> Bool {
    HTMLWallpaperCompatibilityPolicy.shouldAutoEnablePhysicalPixelLayout(
        folderURL: folderURL,
        indexFileName: indexFileName
    )
}
#endif
