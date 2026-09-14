#if !LITE_BUILD
import CoreGraphics
import Foundation
import LiveWallpaperCore
import LiveWallpaperProWPE
import Metal
import MetalKit
import Testing
@testable import LiveWallpaper

@Suite("WPE surface geometry feeding the upscale plan", .serialized)
@MainActor
struct WPEMetalSurfaceGeometryTests {

    private static func makeRenderer() throws -> (WPEMetalSceneRenderer, URL) {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SurfaceGeometry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let surface = WPERenderSurface(
            frame: CGRect(x: 0, y: 0, width: 64, height: 64), device: device
        )
        let renderer = try WPEMetalSceneRenderer(
            descriptor: SceneDescriptor(
                workshopID: "surface-geometry-fixture",
                cacheRelativePath: "wpe-cache/surface-geometry-fixture",
                entryFile: "scene.json",
                capabilityTier: .imageOnly
            ),
            cacheRootURL: root,
            projectManifestRootURL: root,
            dependencyMounts: [],
            surfaceControl: surface,
            mailbox: surface.mailbox,
            presentLayer: WPEPresentLayer(layer: surface.metalLayer),
            // What the builder seeds from the screen when the layer has no size yet.
            drawableSize: CGSize(width: 3840, height: 2160),
            device: device
        )
        return (renderer, root)
    }

    @Test("MTKView knows its backing size at construction; its layer does not")
    func layerReportsZeroUntilFirstDrawable() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let view = WPEInteractiveMTKView(
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), device: device
        )
        let layer = try #require(view.layer as? CAMetalLayer)

        #expect(layer.drawableSize == .zero, "layer reported a size before nextDrawable()")
        #expect(view.drawableSize.width > 0, "MTKView should size itself from its frame")
        #expect(view.convertToBacking(view.bounds).size.width > 0)
        #expect(view.drawableSize == view.convertToBacking(view.bounds).size)
    }

    @Test("A sizeless geometry report never clobbers a known drawable size")
    func sizelessReportIsIgnored() throws {
        let (renderer, root) = try Self.makeRenderer()
        defer { try? FileManager.default.removeItem(at: root) }

        renderer.updateSurfaceGeometry(drawableSize: .zero)
        #expect(renderer.surfaceDrawableSize == CGSize(width: 3840, height: 2160))

        renderer.updateSurfaceGeometry(drawableSize: CGSize(width: 2560, height: 1440))
        #expect(renderer.surfaceDrawableSize == CGSize(width: 2560, height: 1440))
    }

    @Test("The renderer has no plan of its own — the executor is the single owner")
    func planHasOneOwner() throws {
        let (renderer, root) = try Self.makeRenderer()
        defer { try? FileManager.default.removeItem(at: root) }

        let active = WPEMetalUpscalePlan.make(
            worldCanvas: CGSize(width: 3840, height: 2160),
            drawableSize: CGSize(width: 3840, height: 2160),
            fitMode: .cover,
            isHDR: false,
            hdrOutputEnabled: false,
            renderScale: 0.75,
            deviceSupportsScaler: true
        )
        renderer.executor.upscalePlan = active
        #expect(renderer.upscalePlan.verdict == .active)

        renderer.executor.upscalePlan = active.demotedToNative()
        #expect(renderer.upscalePlan.verdict == .declinedAtPresent)
        #expect(renderer.upscalePlan.renderPixelScale == 1.0)
    }

    @Test("The surface reports a real backing size even though its layer is zero")
    func surfaceBackingSizeIsUsable() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let surface = WPERenderSurface(
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), device: device
        )
        #expect(surface.backingDrawableSize.width > 0)
        #expect(surface.backingDrawableSize.height > 0)
        #expect(surface.metalLayer.drawableSize == .zero)
    }

    @Test("Every construction path seeds a usable drawable size")
    func convenienceInitAlsoSeeds() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SurfaceGeometry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let renderer = try WPEMetalSceneRenderer(
            descriptor: SceneDescriptor(
                workshopID: "surface-geometry-convenience",
                cacheRelativePath: "wpe-cache/surface-geometry-convenience",
                entryFile: "scene.json",
                capabilityTier: .imageOnly
            ),
            cacheRootURL: root,
            projectManifestRootURL: root,
            dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            device: device
        )
        #expect(renderer.surfaceDrawableSize.width > 0)
        #expect(renderer.surfaceDrawableSize.height > 0)
    }

    @Test("The drawable keeps its display-optimized path unless the scaler needs it")
    func framebufferOnlyTracksTheScaler() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let frame = CGRect(x: 0, y: 0, width: 640, height: 480)
        let scoped = UserDefaults.appScoped()
        let key = WPEMetalFXSpatialUpscaler.renderScaleDefaultsKey
        defer { scoped.removeObject(forKey: key) }

        scoped.removeObject(forKey: key)
        #expect(WPERenderSurface(frame: frame, device: device).metalLayer.framebufferOnly)

        scoped.set(0.5, forKey: key)
        let expected = !WPEMetalFXSpatialUpscaler.deviceSupportsSpatialScaler
        #expect(WPERenderSurface(frame: frame, device: device).metalLayer.framebufferOnly == expected)
    }

    @Test("Fit mode arrives at construction, not through a later submit")
    func fitModeIsAConstructionArgument() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SurfaceGeometry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let renderer = try WPEMetalSceneRenderer(
            descriptor: SceneDescriptor(
                workshopID: "fit-mode-fixture",
                cacheRelativePath: "wpe-cache/fit-mode-fixture",
                entryFile: "scene.json",
                capabilityTier: .imageOnly
            ),
            cacheRootURL: root,
            projectManifestRootURL: root,
            dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 640, height: 480),
            presentFitMode: WPEPresentFitMode(.center),
            device: device
        )
        #expect(renderer.presentFitMode == .center)
    }

    @Test("A scale change actually triggers the purge, not just offers one")
    func scaleChangePurgesThroughTheRealPath() throws {
        let (renderer, root) = try Self.makeRenderer()
        defer { try? FileManager.default.removeItem(at: root) }
        let scoped = UserDefaults.appScoped()
        let key = WPEMetalFXSpatialUpscaler.renderScaleDefaultsKey
        defer { scoped.removeObject(forKey: key) }
        guard WPEMetalFXSpatialUpscaler.deviceSupportsSpatialScaler else { return }

        renderer.sceneRenderSize = CGSize(width: 3840, height: 2160)
        scoped.set(0.5, forKey: key)
        renderer.refreshUpscalePlan(reason: "test", isInitial: true)
        try #require(renderer.upscalePlan.isActive)

        // Stand in for the pixel-keyed allocations a rendered frame leaves behind.
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 64, height: 64, mipmapped: false
        )
        descriptor.usage = [.shaderRead, .renderTarget]
        descriptor.storageMode = .private
        let device = try #require(MTLCreateSystemDefaultDevice())
        renderer.executor.outputTexturePool = [try #require(device.makeTexture(descriptor: descriptor))]

        // Drive the purge through the real path: asserting
        // `releaseRenderScaleDependentResources` directly would pass with broken wiring.
        scoped.set(1.0, forKey: key)
        renderer.refreshUpscalePlan(reason: "test")
        #expect(renderer.upscalePlan.renderPixelScale == 1.0)
        #expect(renderer.executor.outputTexturePool.isEmpty)
    }

    /// `refreshUpscalePlan` structurally cannot clean up after a present-time
    /// demote: scale is already 1.0 and `.declinedAtPresent` is sticky, so the
    /// refresh sees no change and returns before its purge.
    @Test("A present-time demote purges and forces a redraw, like a scale change")
    func presentDemotePurgesThroughTheRealPath() throws {
        let (renderer, root) = try Self.makeRenderer()
        defer { try? FileManager.default.removeItem(at: root) }
        let scoped = UserDefaults.appScoped()
        let key = WPEMetalFXSpatialUpscaler.renderScaleDefaultsKey
        defer { scoped.removeObject(forKey: key) }
        guard WPEMetalFXSpatialUpscaler.deviceSupportsSpatialScaler else { return }

        renderer.sceneRenderSize = CGSize(width: 3840, height: 2160)
        scoped.set(0.5, forKey: key)
        renderer.refreshUpscalePlan(reason: "test", isInitial: true)
        try #require(renderer.upscalePlan.isActive)

        let device = try #require(MTLCreateSystemDefaultDevice())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 64, height: 64, mipmapped: false
        )
        descriptor.usage = [.shaderRead, .renderTarget]
        descriptor.storageMode = .private
        renderer.executor.outputTexturePool = [try #require(device.makeTexture(descriptor: descriptor))]
        renderer.executor.previousFrameHistory = .init(
            sceneSize: renderer.sceneRenderSize, sceneTexture: nil, namedTextures: [:]
        )

        // What `encodePresent` does when the scaler refuses a planned frame.
        renderer.executor.upscalePlan = renderer.upscalePlan.demotedToNative()
        renderer.executor.notePresentSideDemotion()

        // A refresh is not the cleanup path — prove it before relying on the drain.
        renderer.refreshUpscalePlan(reason: "test")
        #expect(!renderer.executor.outputTexturePool.isEmpty)

        renderer.adoptPresentSideDemotion()
        #expect(renderer.executor.outputTexturePool.isEmpty)
        #expect(renderer.executor.previousFrameHistory == nil)
        #expect(renderer.pendingForcedRerender)

        // One-shot: a later frame must not purge again.
        renderer.pendingForcedRerender = false
        renderer.executor.outputTexturePool = [try #require(device.makeTexture(descriptor: descriptor))]
        renderer.adoptPresentSideDemotion()
        #expect(!renderer.executor.outputTexturePool.isEmpty)
        #expect(!renderer.pendingForcedRerender)
    }

    @Test("A seeded drawable size yields an active plan for a 4K canvas")
    func seededSizeLetsThePlanEngage() throws {
        let (renderer, root) = try Self.makeRenderer()
        defer { try? FileManager.default.removeItem(at: root) }

        let plan = WPEMetalUpscalePlan.make(
            worldCanvas: CGSize(width: 3840, height: 2160),
            drawableSize: renderer.surfaceDrawableSize,
            fitMode: renderer.presentFitMode,
            isHDR: false,
            hdrOutputEnabled: false,
            renderScale: 0.75,
            deviceSupportsScaler: true
        )
        #expect(plan.verdict == .active)
        #expect(plan.renderPixelScale == 0.75)
    }
}
#endif
