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

    static func published(at bundle: URL) throws -> Self {
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
                    mounts: mounts, engineRoot: configuration.hasEngineAssets ? bundle.appendingPathComponent("Engine") : nil,
                    preferredFramesPerSecond: configuration.framesPerSecond, preferredRenderSize: configuration.renderSize)
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
    @MainActor
    static func makeActor(source: SystemWallpaperSceneSource, layer: CAMetalLayer, size: CGSize,
                          hidingClockCalendar: Bool = false) async throws -> WPEDisplayRenderActor {
        guard let device = layer.device else { throw WPEMetalRenderExecutorError.commandBufferFailed }
        let renderer = try WPEMetalSceneRenderer(
            descriptor: source.descriptorForSystemWallpaper(hidingClockCalendar: hidingClockCalendar), cacheRootURL: source.projectRoot,
            assetProvider: source.provider, projectManifestRootURL: source.projectRoot,
            dependencyMounts: source.mounts, engineAssetsRootURL: source.engineRoot,
            surfaceControl: SystemWallpaperSceneSurfaceControl(), mailbox: WPEPointerMailbox(),
            presentLayer: WPEPresentLayer(layer: layer), drawableSize: size, device: device
        )
        renderer.excludedObjectIDs = hidingClockCalendar ? source.clockCalendarObjectIDs() : []
        let actor = WPEDisplayRenderActor(label: "com.loomscreen.wallpaper.scene")
        await actor.adopt(renderer)
        await actor.setAudioMuted(true)
        await actor.setFrameRateCeiling(source.preferredFramesPerSecond)
        do { try await actor.load() } catch {
            await actor.teardownRenderer()
            actor.requestStop()
            throw error
        }
        return actor
    }
}
#endif
