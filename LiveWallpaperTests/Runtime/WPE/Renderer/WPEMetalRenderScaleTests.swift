import CoreGraphics
import Metal
import Testing
@testable import LiveWallpaper
import LiveWallpaperProWPE

/// Ortho render-scale decoupling (MetalFX): the ONE world→pixel conversion,
/// pool key consistency under `pixelScale`, world-canvas derivation, and the
/// loader's reduced-mip upload selection.
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

    // MARK: - Pool key derivation under pixelScale

    private static let sceneSize = CGSize(width: 1920, height: 1080)

    private static func makeLayer(localFBOs: [WPERenderFBO] = []) -> WPERenderLayer {
        WPERenderLayer(
            objectID: "obj",
            objectName: "obj",
            imagePath: "",
            materialPath: nil,
            geometry: .identity,
            compositeA: "comp_a",
            compositeB: "comp_b",
            localFBOs: localFBOs,
            passes: []
        )
    }

    private static func pool() throws -> WPEMetalRenderTargetPool {
        let device = try #require(MTLCreateSystemDefaultDevice())
        return WPEMetalRenderTargetPool(device: device)
    }

    @Test("pixelScale 1 keys are identical to the historical derivation")
    func poolKeysIdentityAtScaleOne() throws {
        let pool = try Self.pool()
        pool.pixelScale = 1
        let layer = Self.makeLayer()
        let key = pool.diagnosticKey(
            for: .fbo(name: "_rt_FullFrameBuffer"),
            spec: WPERenderFBO(name: "_rt_FullFrameBuffer", scale: 1, format: "rgba8888"),
            layer: layer,
            sceneSize: Self.sceneSize
        )
        #expect(key.width == 1920)
        #expect(key.height == 1080)
        let half = pool.diagnosticKey(
            for: .fbo(name: "_rt_HalfFrameBuffer"),
            spec: WPERenderFBO(name: "_rt_HalfFrameBuffer", scale: 2, format: "rgba8888"),
            layer: layer,
            sceneSize: Self.sceneSize
        )
        #expect(half.width == 960)
        #expect(half.height == 540)
    }

    @Test("Scene-sized FBO key matches the scaled scene output exactly (the blit invariant)")
    func sceneAliasKeyMatchesScaledOutput() throws {
        let pool = try Self.pool()
        pool.pixelScale = 0.75
        let key = pool.diagnosticKey(
            for: .fbo(name: "_rt_FullFrameBuffer"),
            spec: WPERenderFBO(name: "_rt_FullFrameBuffer", scale: 1, format: "rgba8888"),
            layer: Self.makeLayer(),
            sceneSize: Self.sceneSize
        )
        let output = WPEMetalFXSpatialUpscaler.scaledCanvasSize(Self.sceneSize, pixelScale: 0.75)
        #expect(key.width == Int(output.width))
        #expect(key.height == Int(output.height))
        // Odd canvas: the even-alignment of the conversion must flow into the key
        // (an Int-truncated 1674.75→1674 vs even-aligned path differing by 1px
        // would make the alias-snapshot blit read out of bounds).
        let oddScene = CGSize(width: 2233, height: 1081)
        let oddKey = pool.diagnosticKey(
            for: .fbo(name: "_rt_FullFrameBuffer"),
            spec: WPERenderFBO(name: "_rt_FullFrameBuffer", scale: 1, format: "rgba8888"),
            layer: Self.makeLayer(),
            sceneSize: oddScene
        )
        let oddOutput = WPEMetalFXSpatialUpscaler.scaledCanvasSize(oddScene, pixelScale: 0.75)
        #expect(oddKey.width == Int(oddOutput.width))
        #expect(oddKey.height == Int(oddOutput.height))
    }

    @Test("Downsample divisors derive from the SCALED canvas head")
    func divisorAppliesAfterScaledCanvas() throws {
        let pool = try Self.pool()
        pool.pixelScale = 0.75
        let key = pool.diagnosticKey(
            for: .fbo(name: "_rt_HalfFrameBuffer"),
            spec: WPERenderFBO(name: "_rt_HalfFrameBuffer", scale: 2, format: "rgba8888"),
            layer: Self.makeLayer(),
            sceneSize: Self.sceneSize
        )
        // Head 1440x810 → divisor 2 → 720x405 (truncating, like WPE).
        #expect(key.width == 720)
        #expect(key.height == 405)
    }

    @Test("Authored pixelSize and fit scale with the canvas")
    func pixelSizeAndFitScale() throws {
        let pool = try Self.pool()
        pool.pixelScale = 0.75
        let layer = Self.makeLayer()
        let sized = pool.diagnosticKey(
            for: .fbo(name: "text"),
            spec: WPERenderFBO(
                name: "text", scale: 1, format: "rgba8888",
                pixelSize: CGSize(width: 557, height: 500)
            ),
            layer: layer,
            sceneSize: Self.sceneSize
        )
        let expected = WPEMetalFXSpatialUpscaler.scaledCanvasSize(
            CGSize(width: 557, height: 500), pixelScale: 0.75
        )
        #expect(sized.width == Int(expected.width))
        #expect(sized.height == Int(expected.height))

        let fitted = pool.diagnosticKey(
            for: .fbo(name: "fx"),
            spec: WPERenderFBO(name: "fx", scale: 1, fit: 512, format: "rgba8888"),
            layer: layer,
            sceneSize: Self.sceneSize
        )
        // fit is an absolute pixel edge → scales linearly: 512 × 0.75 = 384.
        #expect(max(fitted.width, fitted.height) == 384)
    }

    @Test("Allocation dimensions agree with the diagnostic key under scaling")
    func allocationMatchesDiagnosticKey() throws {
        let fbo = WPERenderFBO(name: "fxBlur", scale: 2, format: "rgba8888")
        let layer = Self.makeLayer(localFBOs: [fbo])
        let pool = try Self.pool()
        pool.pixelScale = 0.75
        let key = pool.diagnosticKey(
            for: .fbo(name: "fxBlur"),
            spec: fbo,
            layer: layer,
            sceneSize: Self.sceneSize
        )
        let texture = try pool.texture(
            for: .fbo(name: "fxBlur"),
            layer: layer,
            sceneSize: Self.sceneSize,
            avoiding: nil
        )
        #expect(texture.width == key.width)
        #expect(texture.height == key.height)
    }

    @Test("worldCanvasSize ignores pixelScale and equals scale-1 dimensions")
    func worldCanvasSizeIsScaleInvariant() throws {
        let fbo = WPERenderFBO(
            name: "group", scale: 1, format: "rgba8888",
            pixelSize: CGSize(width: 557, height: 500)
        )
        let layer = Self.makeLayer(localFBOs: [fbo])
        let pool = try Self.pool()
        pool.pixelScale = 0.75
        let world = pool.worldCanvasSize(
            for: .fbo(name: "group"),
            layer: layer,
            sceneSize: Self.sceneSize
        )
        #expect(world == CGSize(width: 557, height: 500))
        #expect(pool.worldCanvasSize(
            for: .scene, layer: layer, sceneSize: Self.sceneSize
        ) == Self.sceneSize)
        // At scale 1 the world canvas IS the allocated texture size — the
        // refactored objectQuadSceneSize/text-canvas paths stay bit-identical.
        pool.pixelScale = 1
        let texture = try pool.texture(
            for: .fbo(name: "group"),
            layer: layer,
            sceneSize: Self.sceneSize,
            avoiding: nil
        )
        #expect(CGFloat(texture.width) == world.width)
        #expect(CGFloat(texture.height) == world.height)
    }

    // MARK: - Executor gating

    @Test("Test processes read the isolated store, not this machine's real defaults")
    func renderScaleIsTestIsolated() {
        let scoped = UserDefaults.appScoped()
        defer { scoped.removeObject(forKey: WPEMetalFXSpatialUpscaler.renderScaleDefaultsKey) }
        // The machine's com.loomscreen.pro domain may carry a real value (the
        // user runs the feature); a leak here would silently shrink every RT
        // in headless render tests and oracle captures.
        #expect(WPEMetalFXSpatialUpscaler.renderScale == 1.0)
        scoped.set(0.5, forKey: WPEMetalFXSpatialUpscaler.renderScaleDefaultsKey)
        #expect(WPEMetalFXSpatialUpscaler.renderScale == 0.5)
    }

    @Test("A freshly built executor is unplanned and renders at full resolution")
    func executorDefaultsToScaleOne() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        // An executor that never received a plan must behave exactly like the
        // pre-feature path — the renderer is the only thing allowed to decide.
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
        // A single-level payload always stays put.
        #expect(WPEMetalTextureLoader.uploadMipStartIndex(
            mipmaps: [Self.mip(0, 2048, 1024)], maxEdge: 100
        ) == 0)
        #expect(WPEMetalTextureLoader.uploadMipStartIndex(mipmaps: chain, maxEdge: 0) == 0)
    }

    @Test("Mip-chain upload follows the scene's plan, not the global setting")
    func mipChainDefaultFollowsPlan() {
        // Unset override: a scene that is NOT scaling must keep its historical
        // level-0-only upload even while another scene on the same machine is.
        guard WPEMetalTextureLoader.mipChainOverride == nil else { return }
        #expect(WPEMetalTextureLoader.uploadsMipChain(scalingActive: true))
        #expect(WPEMetalTextureLoader.uploadsMipChain(scalingActive: false) == false)
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

        // Everything below is keyed by a PIXEL dimension, so a scale change makes
        // every entry unreachable — stranded, not reused.
        executor.outputTexturePool = [texture]
        executor.bootstrapPreviousTextureCache[
            .init(targetID: .scene, width: 64, height: 64, pixelFormat: .rgba8Unorm)
        ] = texture
        executor.sceneReadHazardSnapshotCache[
            .init(targetID: .scene, width: 64, height: 64, pixelFormat: .rgba8Unorm)
        ] = texture
        // Validated against the WORLD size, which a scale change leaves alone —
        // so without an explicit drop it keeps serving old-resolution textures
        // to `.previous` reads.
        executor.previousFrameHistory = .init(
            sceneSize: CGSize(width: 1920, height: 1080),
            sceneTexture: texture,
            namedTextures: [:]
        )

        executor.releaseRenderScaleDependentResources()

        #expect(executor.outputTexturePool.isEmpty)
        #expect(executor.bootstrapPreviousTextureCache.isEmpty)
        #expect(executor.sceneReadHazardSnapshotCache.isEmpty)
        #expect(executor.previousFrameHistory == nil)
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
