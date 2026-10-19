import CoreGraphics
@testable import LiveWallpaper
import Metal
import Testing

@Suite("WPE Metal render scale decoupling", .serialized)
struct WPEMetalRenderScaleTests {
    // MARK: - scaledCanvasSize (the single conversion)

    @Test("Scale 1 is the identity for ANY size — the bit-identity guarantee")
    func canvasIdentityAtScaleOne() {
        for size in [CGSize(width: 1920, height: 1080),
                     CGSize(width: 2233, height: 1081),
                     CGSize(width: 63, height: 7)] {
            #expect(WPEMetalFXSpatialUpscaler.scaledCanvasSize(size, pixelScale: 1.0) == size)
        }
    }

    @Test("Scale 0.75 floors, aligns even, and never drops below 64")
    func canvasScaling() {
        #expect(WPEMetalFXSpatialUpscaler.scaledCanvasSize(
            CGSize(width: 1920, height: 1080), pixelScale: 0.75
        ) == CGSize(width: 1440, height: 810))
        // 2233 × 0.75 = 1674.75 → floor 1674 (even); 1081 × 0.75 = 810.75 → 810.
        #expect(WPEMetalFXSpatialUpscaler.scaledCanvasSize(
            CGSize(width: 2233, height: 1081), pixelScale: 0.75
        ) == CGSize(width: 1674, height: 810))
        #expect(WPEMetalFXSpatialUpscaler.scaledCanvasSize(
            CGSize(width: 100, height: 100), pixelScale: 0.25
        ) == CGSize(width: 64, height: 64))
    }

    // MARK: - Presenter gating

    @Test("Test processes read the isolated store, not this machine's real defaults")
    func renderScaleIsTestIsolated() {
        let scoped = UserDefaults.appScoped()
        defer { scoped.removeObject(forKey: WPEMetalFXSpatialUpscaler.renderScaleDefaultsKey) }
        #expect(WPEMetalFXSpatialUpscaler.renderScale == 1.0)
        scoped.set(0.5, forKey: WPEMetalFXSpatialUpscaler.renderScaleDefaultsKey)
        #expect(WPEMetalFXSpatialUpscaler.renderScale == 0.5)
    }

    @Test("A freshly built presenter is unplanned and renders at full resolution")
    func presenterDefaultsToScaleOne() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let presenter = try WPEMetalPresenter(device: device)
        #expect(presenter.upscalePlan.renderPixelScale == 1.0)
        #expect(presenter.upscalePlan.isActive == false)
    }

    // MARK: - Render-scale changes must not strand pixel-keyed resources

    @Test("Changing the render scale releases every pixel-keyed resource")
    func scaleChangeReleasesSizeKeyedResources() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let presenter = try WPEMetalPresenter(device: device)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 64, height: 64, mipmapped: false
        )
        descriptor.usage = [.shaderRead, .renderTarget]
        descriptor.storageMode = .private
        let texture = try #require(device.makeTexture(descriptor: descriptor))

        presenter.outputTexturePool = [texture]
        presenter.linearPresentationTexture = texture
        presenter.recentOutputTextureIDs = [ObjectIdentifier(texture)]
        presenter.releaseRenderScaleDependentResources()
        #expect(presenter.outputTexturePool.isEmpty)
        #expect(presenter.recentOutputTextureIDs.isEmpty)
        #expect(presenter.linearPresentationTexture == nil)
    }
}
