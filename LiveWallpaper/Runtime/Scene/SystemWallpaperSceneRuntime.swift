#if !LITE_BUILD
import Foundation
import LiveWallpaperCore
import LiveWallpaperProWPE
import Metal
import QuartzCore

struct SystemWallpaperSceneSource: Sendable {
    let descriptor: SceneDescriptor
    let provider: any WPESceneAssetProvider
    let projectRoot: URL
    let mounts: [WPEAssetMount]
    let engineRoot: URL?
    var preferredFramesPerSecond = 30
    var preferredRenderSize = CGSize(width: 1920, height: 1080)
    var parityConfiguration: SystemWallpaperSceneConfiguration.Parity?
    /// The exact shader-cache root in an immutable publication, rather than the app's evictable cache.
    var shaderCacheURL: URL?
    var shaderPolicy: WPEParityShaderPolicy = .compileAllowed

    /// Preserve the display aspect ratio while bounding native rendering by the selected resolution.
    func renderSize(for size: CGSize) -> CGSize {
        let scale = min(1, preferredRenderSize.width / max(size.width, 1), preferredRenderSize.height / max(size.height, 1))
        return CGSize(width: max(2, floor(size.width * scale / 2) * 2), height: max(2, floor(size.height * scale / 2) * 2))
    }

    func descriptorForSystemWallpaper(hidingClockCalendar: Bool) -> SceneDescriptor {
        guard hidingClockCalendar else { return descriptor }
        let data = try? Data(contentsOf: projectRoot.appendingPathComponent("project.json"))
        var overrides = descriptor.propertyOverrides
        for (key, hiddenValue) in SystemWallpaperClockPolicy.visibilityOverrides(projectData: data) {
            overrides[key] = .bool(hiddenValue)
        }
        return descriptor.withPropertyOverrides(overrides)
    }

    func clockCalendarObjectIDs() -> Set<String> {
        guard let data = try? provider.data(atRelativePath: descriptor.entryFile) else { return [] }
        return SystemWallpaperClockPolicy.hiddenObjectIDs(
            sceneData: data, projectData: try? Data(contentsOf: projectRoot.appendingPathComponent("project.json"))
        )
    }

    static func published(at bundle: URL, shaderPolicy: WPEParityShaderPolicy = .precompiledOnly) throws -> Self {
        try readBundle(at: bundle, shaderPolicy: shaderPolicy, legacyRepreparation: false)
    }

    #if !SYSTEM_WALLPAPER_EXTENSION
    /// Explicit app-side migration input. The extension's ordinary published reader still rejects old capsules.
    static func legacyRepreparation(at bundle: URL) throws -> Self {
        try readBundle(at: bundle, shaderPolicy: .compileAllowed, legacyRepreparation: true)
    }
    #endif

    private static func readBundle(at bundle: URL, shaderPolicy: WPEParityShaderPolicy,
                                   legacyRepreparation: Bool) throws -> Self {
        let configuration = try JSONDecoder().decode(
            SystemWallpaperSceneConfiguration.self,
            from: Data(contentsOf: bundle.appendingPathComponent("configuration.json"))
        )
        guard WPEPathSafety.isSafeRelativePath(configuration.descriptor.entryFile),
              WPEPathSafety.isSafeCacheRelativePath(configuration.descriptor.cacheRelativePath),
              [15, 30, 60].contains(configuration.framesPerSecond),
              configuration.renderSize.width.isFinite, configuration.renderSize.height.isFinite,
              (64 ... 3840).contains(configuration.renderSize.width), (64 ... 2160).contains(configuration.renderSize.height) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let assets = bundle.appendingPathComponent("Assets", isDirectory: true)
        let shaders = bundle.appendingPathComponent("Shaders", isDirectory: true)
        let root = bundle.resolvingSymlinksInPath()
        guard WPEPathSafety.contains(assets.resolvingSymlinksInPath(), in: root),
              WPEPathSafety.contains(shaders.resolvingSymlinksInPath(), in: root) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let engine = configuration.hasEngineAssets ? bundle.appendingPathComponent("Engine", isDirectory: true) : nil
        if let engine, !WPEPathSafety.contains(engine.resolvingSymlinksInPath(), in: root) {
            throw CocoaError(.fileReadCorruptFile)
        }
        if !legacyRepreparation {
            guard let parity = configuration.parity else { throw CocoaError(.fileReadCorruptFile) }
            _ = try parity.settings(for: configuration.descriptor)
        }
        let mounts = try configuration.dependencies.map { dependency in
            guard SystemWallpaperManifest.isSafeFileName(dependency.directory),
                  WPEPathSafety.isSafeProjectID(dependency.workshopID) else { throw CocoaError(.fileReadCorruptFile) }
            let url = bundle.appendingPathComponent(dependency.directory, isDirectory: true)
            guard WPEPathSafety.contains(url.resolvingSymlinksInPath(), in: bundle.resolvingSymlinksInPath()) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return WPEAssetMount(workshopID: dependency.workshopID, rootURL: url)
        }
        return Self(descriptor: configuration.descriptor,
                    provider: WPEDirectorySceneAssetProvider(rootURL: assets), projectRoot: assets,
                    mounts: mounts, engineRoot: engine,
                    preferredFramesPerSecond: configuration.framesPerSecond, preferredRenderSize: configuration.renderSize,
                    parityConfiguration: legacyRepreparation ? nil : configuration.parity,
                    shaderCacheURL: shaders, shaderPolicy: shaderPolicy)
    }
}

/// Headless pacing: the export loop or extension drives frames, never MTKView.
private final class SystemWallpaperSceneSurfaceControl: WPESurfaceControl {
    func applyPacing(_: WPERenderPacingUpdate) {}
    func setNeedsRedraw() {}
    func drawImmediately() {}
    func releaseDrawables() {}
    func detach() {}
    func setClickCaptureEnabled(_: Bool) {}
}

enum SystemWallpaperSceneRuntime {
    struct Unavailable: LocalizedError {
        let reason: String
        var errorDescription: String? {
            reason
        }
    }

    @MainActor
    static func makeActor(source: SystemWallpaperSceneSource, layer: CAMetalLayer, size: CGSize,
                          hidingClockCalendar: Bool = false) async throws -> WPEDisplayRenderActor {
        guard let device = layer.device else { throw WPEMetalRenderExecutorError.commandBufferFailed }
        let descriptor = source.descriptorForSystemWallpaper(hidingClockCalendar: hidingClockCalendar)
        let compiler: (any WPEParityShaderCompiling)?
        let compilerIdentity: String?
        switch source.shaderPolicy {
        case .compileAllowed:
            #if SYSTEM_WALLPAPER_EXTENSION
            throw Unavailable(reason: "System wallpaper extensions require a precompiled scene capsule")
            #else
            let helper = try WPEParityShaderToolchain.makeCompiler().get()
            compiler = helper
            compilerIdentity = helper.compilerIdentity
            if let identity = source.parityConfiguration?.compilerIdentity, identity != compilerIdentity {
                throw Unavailable(reason: "The scene capsule was prepared with a different shader compiler")
            }
            #endif
        case .precompiledOnly:
            guard source.parityConfiguration != nil, source.shaderCacheURL != nil else {
                throw Unavailable(reason: "The scene capsule has no precompiled shader configuration")
            }
            compiler = nil
            compilerIdentity = source.parityConfiguration?.compilerIdentity
        }
        let settings: WPEParityProgramSettings
        if let configuration = source.parityConfiguration {
            settings = try configuration.settings(for: descriptor)
        } else {
            #if SYSTEM_WALLPAPER_EXTENSION
            throw Unavailable(reason: "The scene capsule has no parity configuration")
            #else
            settings = try WPEParityProductSettings.make(descriptor: descriptor, device: device)
            #endif
        }
        var inputs = WPEParitySceneInputs(
            descriptor: descriptor,
            entryResolver: SceneResourceResolver(provider: source.provider, cacheRootURL: source.projectRoot),
            projectRoot: source.projectRoot,
            assets: WPEParitySceneAssets.make(provider: source.provider, projectRoot: source.projectRoot,
                                              dependencyMounts: source.mounts, engineAssetsRootURL: source.engineRoot),
            settings: settings, compiler: compiler, device: device,
            presentLayer: WPEPresentLayer(layer: layer), mailbox: WPEPointerMailbox(),
            surfaceControl: SystemWallpaperSceneSurfaceControl(), drawableSize: size, pixelFormat: layer.pixelFormat
        )
        inputs.compilerIdentity = compilerIdentity
        inputs.shaderOptions = source.parityConfiguration?.shaderOptions ?? .init()
        inputs.bindingABIVersion = source.parityConfiguration?.bindingABIVersion ?? 1
        inputs.shaderPolicy = source.shaderPolicy
        inputs.requireCompleteShaders = true
        inputs.textureCompression = source.parityConfiguration?.textureCompression
        inputs.renderScaleOverride = source.parityConfiguration?.renderScale
        if let root = source.shaderCacheURL {
            inputs.diskCache = WPEParityShaderDiskCache(rootURL: root, readOnly: source.shaderPolicy == .precompiledOnly,
                                                        sizeBudget: .max)
        }
        let actor = WPEDisplayRenderActor(label: "com.loomscreen.wallpaper.scene")
        do {
            try await actor.adoptParity(inputs)
            await actor.setAudioMuted(true)
            await actor.setFrameRateCeiling(source.preferredFramesPerSecond)
            try await actor.setSystemWallpaperState(descriptor: descriptor,
                                                    excludedObjectIDs: hidingClockCalendar ? source.clockCalendarObjectIDs() : [])
            try await actor.load()
            guard let state = await actor.rendererStateSnapshot(), state.isLoaded, state.shaderErrorCount == 0 else {
                throw Unavailable(reason: "The parity scene did not load every required shader")
            }
            try Task.checkCancellation()
        } catch {
            await actor.teardownRenderer()
            actor.requestStop()
            throw error
        }
        return actor
    }
}
#endif
