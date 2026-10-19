import CoreGraphics
import Metal
import Testing
@testable import LiveWallpaper
import LiveWallpaperProWPE

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

    // MARK: - Executor gating

    @Test("Test processes read the isolated store, not this machine's real defaults")
    func renderScaleIsTestIsolated() {
        let scoped = UserDefaults.appScoped()
        defer { scoped.removeObject(forKey: WPEMetalFXSpatialUpscaler.renderScaleDefaultsKey) }
        #expect(WPEMetalFXSpatialUpscaler.renderScale == 1.0)
        scoped.set(0.5, forKey: WPEMetalFXSpatialUpscaler.renderScaleDefaultsKey)
        #expect(WPEMetalFXSpatialUpscaler.renderScale == 0.5)
    }

    @Test("A freshly built executor is unplanned and renders at full resolution")
    func executorDefaultsToScaleOne() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        #expect(executor.upscalePlan.renderPixelScale == 1.0)
        #expect(executor.upscalePlan.isActive == false)
        #expect(executor.upscalePlan.maxSourceTextureEdge == nil)
    }

    // MARK: - Loader mip selection

    private static func mip(_ index: Int, _ width: Int, _ height: Int) -> WPETexTextureMipmap {
        WPETexTextureMipmap(index: index, width: width, height: height, bytes: Data())
    }

    @Test("uploadMipStartIndex picks the smallest level still covering the cap")
    func mipStartSelection() {
        let chain = [Self.mip(0, 2048, 1024), Self.mip(1, 1024, 512),
                     Self.mip(2, 512, 256), Self.mip(3, 256, 128)]
        #expect(WPEMetalTextureLoader.uploadMipStartIndex(mipmaps: chain, maxEdge: nil) == 0)
        #expect(WPEMetalTextureLoader.uploadMipStartIndex(mipmaps: chain, maxEdge: 4096) == 0)
        #expect(WPEMetalTextureLoader.uploadMipStartIndex(mipmaps: chain, maxEdge: 1620) == 0)
        #expect(WPEMetalTextureLoader.uploadMipStartIndex(mipmaps: chain, maxEdge: 810) == 1)
        #expect(WPEMetalTextureLoader.uploadMipStartIndex(mipmaps: chain, maxEdge: 512) == 2)
        // Never scales up: even a tiny cap keeps the smallest available level.
        #expect(WPEMetalTextureLoader.uploadMipStartIndex(mipmaps: chain, maxEdge: 100) == 3)
        #expect(WPEMetalTextureLoader.uploadMipStartIndex(
            mipmaps: [Self.mip(0, 2048, 1024)], maxEdge: 100
        ) == 0)
        #expect(WPEMetalTextureLoader.uploadMipStartIndex(mipmaps: chain, maxEdge: 0) == 0)
    }

    /// Pins `WPEMetalMipChainEnabled` in `UserDefaults.appScoped()` — the domain
    /// `mipChainOverride` reads; the test host uses its isolated process suite.
    /// Returns the restore closure.
    private static func pinMipChainDefault(_ value: Bool?) -> () -> Void {
        let defaults = UserDefaults.appScoped()
        let key = WPEMetalTextureLoader.mipChainDefaultsKey
        let previous = defaults.object(forKey: key)
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
        return {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
    }

    @Test("Mip-chain upload follows the scene's plan, not the global setting")
    func mipChainDefaultFollowsPlan() {
        // Pinned, not guarded on: guarding would skip this test on any machine where the knob
        // had ever been written, and it is the only coverage of the unset default.
        let restore = Self.pinMipChainDefault(nil)
        defer { restore() }

        #expect(WPEMetalTextureLoader.uploadsMipChain(scalingActive: true))
        #expect(WPEMetalTextureLoader.uploadsMipChain(scalingActive: false) == false)

        // An explicit setting overrides the per-scene plan in both directions.
        let restoreOn = Self.pinMipChainDefault(true)
        #expect(WPEMetalTextureLoader.uploadsMipChain(scalingActive: false))
        restoreOn()
        let restoreOff = Self.pinMipChainDefault(false)
        #expect(WPEMetalTextureLoader.uploadsMipChain(scalingActive: true) == false)
        restoreOff()
    }

    // MARK: - Render-scale changes must not strand pixel-keyed resources

    @Test("Changing the render scale releases every pixel-keyed resource")
    func scaleChangeReleasesSizeKeyedResources() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 64, height: 64, mipmapped: false
        )
        descriptor.usage = [.shaderRead, .renderTarget]
        descriptor.storageMode = .private
        let texture = try #require(device.makeTexture(descriptor: descriptor))

        executor.outputTexturePool = [texture]
        executor.linearPresentationTexture = texture
        executor.recentOutputTextureIDs = [ObjectIdentifier(texture)]
        executor.releaseRenderScaleDependentResources()
        #expect(executor.outputTexturePool.isEmpty)
        #expect(executor.recentOutputTextureIDs.isEmpty)
        #expect(executor.linearPresentationTexture == nil)
    }

    // MARK: - Registry world dimensions

    @Test("World dimensions default to the image dimensions and survive overrides")
    func registryWorldDimensions() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 8, height: 4, mipmapped: false
        )
        descriptor.storageMode = .shared
        let texture = try #require(device.makeTexture(descriptor: descriptor))

        let plain = WPEMetalTextureResolution(texture: texture, imageWidth: 6, imageHeight: 3)
        #expect(plain.worldWidth == 6)
        #expect(plain.worldHeight == 3)

        let scaled = WPEMetalTextureResolution(
            texture: texture, imageWidth: 6, imageHeight: 3, worldWidth: 12, worldHeight: 6
        )
        #expect(scaled.worldWidth == 12)
        #expect(scaled.worldHeight == 6)
        // shaderValue keeps describing the uploaded level, never the world size.
        #expect(scaled.shaderValue == .vector([8, 4, 6, 3]))
    }

    // MARK: - Raster decode downsample

    @Test("Raster images resample to the cap; small and strip-shaped images pass through")
    func rasterDownsample() throws {
        func makeImage(width: Int, height: Int) throws -> CGImage {
            let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
            let context = try #require(CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            return try #require(context.makeImage())
        }

        let image = try makeImage(width: 400, height: 200)
        let scaled = try #require(WPEMetalTextureLoader.downsampledImage(image, maxEdge: 128))
        #expect(scaled.width == 128)
        #expect(scaled.height == 64)
        #expect(WPEMetalTextureLoader.downsampledImage(image, maxEdge: 400) == nil)
        #expect(WPEMetalTextureLoader.downsampledImage(image, maxEdge: 800) == nil)
        // Strip-shaped data images (LUTs/gradients) index by texel — exempt even
        // when the long edge exceeds the cap.
        let strip = try makeImage(width: 512, height: 4)
        #expect(WPEMetalTextureLoader.downsampledImage(strip, maxEdge: 128) == nil)
    }
}
