#if !LITE_BUILD && DEBUG
import CoreGraphics
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import LiveWallpaperProWPE
import Metal
import MetalFX
import QuartzCore
import simd
import XCTest

/// Product assembly guards. Sizes are fixed independently of the production canvas/FBO builders; pixels use
/// the actual presented drawable and the platform's bare spatial scaler, never the old WPE renderer.
extension WPEParitySceneDriverTests {
    @objc func testMetalFXScalesEverySceneTargetAndPreservesLogicalInputs() async throws {
        let device = try requiredMetalFXDevice()
        let (baseAssets, compiler) = try requiredMetalFXInputs()
        let (document, assets) = try metalFXDocument(baseAssets: baseAssets, targets: true, clippedPuppet: true)
        // Reuse this Driver: a native present caches no scaler, then a .5 reload must really enable it.
        let driver = try WPEParitySceneDriver(device: device)
        defer { driver.cleanup() }
        // Raw401x203 -> fit75 -> /byte(258)=/2; scaling happens before fit and divisor.
        for (scale, bb, thin, fitted, history) in [
            (1.0, SIMD2(384, 256), SIMD2(128, 16), SIMD2(37, 18), SIMD2(64, 32)),
            (0.5, SIMD2(192, 128), SIMD2(64, 8), SIMD2(18, 9), SIMD2(32, 16)),
            (0.75, SIMD2(288, 192), SIMD2(96, 12), SIMD2(28, 14), SIMD2(48, 24)),
        ] {
            try await withMetalFXScale(scale) {
                try await driver.load(document: document, assets: assets,
                                      settings: .init(bloom: true, msaaSampleCount: 2),
                                      drawableSize: CGSize(width: 384, height: 256), pixelFormat: .rgba8Unorm,
                                      compiler: compiler, diskCache: WPEParityShaderDiskCache(cachesURL: scratch))
                let renderer = try XCTUnwrap(driver.renderer)
                XCTAssertTrue(renderer.skipped.isEmpty, "\(renderer.skipped)")
                let layer = metalFXLayer(device: device, size: CGSize(width: 384, height: 256))
                if scale == 0.5 {
                    // Load locks the plan. First present must not re-read this subsequently changed setting.
                    UserDefaults.appScoped().set(1.0, forKey: WPEMetalFXSpatialUpscaler.renderScaleDefaultsKey)
                }
                for down in [false, true, false] {
                    let command = try XCTUnwrap(driver.renderAndPresentFrame(
                        layer: layer, timestamp: nextTimestamp(), pointer: SIMD2(0.25, 0.5), buttonDown: down
                    ))
                    try await settle(driver, label: "scale \(scale) cursor frame")
                    XCTAssertEqual(command.status, .completed)
                    XCTAssertNil(command.error)
                }
                let pass = try XCTUnwrap(driver.executor.lastPresentPass)
                XCTAssertEqual(pass.usedMetalFX, scale < 1)
                let model = try XCTUnwrap(renderer.lastFrameDraws.first { item in
                    guard case let .scene(draw)? = renderer.frames[0].draws[item.operation],
                          draw.objectID == "91", case .modelMesh = draw.geometry else { return false }
                    return true
                }?.draw, "the real model must encode, not merely enable the model flag")
                XCTAssertTrue(model.indexCount > 0 || model.vertexCount > 0)
                let albedo = try XCTUnwrap(model.textures["g_Texture0"])
                XCTAssertEqual([albedo.width, albedo.height], [8192, 4096], "imported assets retain original pixels")
                XCTAssertEqual(renderer.pathCamera.renderTargetSize, SIMD2(384, 256))
                XCTAssertEqual(renderer.pathCamera.projection.columns.0.x, 2 / 384, accuracy: 0.000001)
                XCTAssertEqual(renderer.pathCamera.projection.columns.1.y, 2 / 256, accuracy: 0.000001)
                let probe = try XCTUnwrap(renderer.instance.state.object("900"))
                XCTAssertEqual(probe.origin, SIMD3(384, 256, 96), "script sees logical screen and cursor pixels")
                let script = try XCTUnwrap(renderer.instance.script)
                XCTAssertEqual(script.engine.exceptionCount, 0, script.engine.exceptions.joined(separator: "\n"))
                XCTAssertEqual(script.engine.dispatchCount(.cursorClick), 1, "the fixed logical point hits layer10")
                XCTAssertEqual(try XCTUnwrap(renderer.instance.state.object("10")).alpha, 0.375)
                let quad = try XCTUnwrap(renderer.cursorQuad("10", camera: renderer.pathCamera))
                // The 1/192 Float32 projection cannot represent the left edge exactly. Keep subpixel error
                // below two Float32 ULPs here; confusing physical and logical pixels misses by tens of pixels.
                for (actual, expected) in [(quad.0, SIMD2<Float>(32, 160)), (quad.1, SIMD2<Float>(160, 160)),
                                           (quad.2, SIMD2<Float>(160, 96)), (quad.3, SIMD2<Float>(32, 96))] {
                    XCTAssertEqual(actual.x, expected.x, accuracy: 0.00002)
                    XCTAssertEqual(actual.y, expected.y, accuracy: 0.00002)
                }
                for id: WPEResourceID in ["backbuffer", "backbufferDepth", "_rt_FullFrameBuffer",
                                          "_rt_FullFrameBufferMultiSampled", "_rt_FullFrameBufferMultiSampledDepth",
                                          "_rt_FullAlphaMask"] {
                    let texture = try actualMetalFXTarget(renderer, id: id, size: bb)
                    XCTAssertEqual(texture.sampleCount, id.rawValue.contains("MultiSampled") ? 2 : 1, "\(id)")
                    if id.rawValue.contains("AlphaMask") {
                        XCTAssertEqual(texture.pixelFormat, .r8Unorm)
                    }
                    if id.rawValue.hasSuffix("Depth") {
                        XCTAssertEqual(texture.pixelFormat, .depth32Float)
                    }
                }
                _ = try actualMetalFXTarget(renderer, id: "thin_7", size: thin)
                _ = try actualMetalFXTarget(renderer, id: "fit_7", size: fitted)
                _ = try actualMetalFXTarget(renderer, id: "history_7", size: history)
                _ = try actualMetalFXTarget(renderer, id: "scratch_7", size: history)
                _ = try actualMetalFXTarget(renderer, id: "shared", size: history)
                // An autosize layer takes its albedo TEXI size, 562×896, not the authored 128×64 (140209360.c:26-49).
                let composite = SIMD2((562 * bb.x / 384) & ~1, (896 * bb.y / 256) & ~1)
                _ = try actualMetalFXTarget(renderer, id: "_rt_imageLayerComposite_90_a", size: composite)
                for (id, divisor): (WPEResourceID, Int) in [("_rt_4FrameBuffer", 4), ("_rt_8FrameBuffer", 8),
                                                            ("_rt_Bloom", 8)] {
                    _ = try actualMetalFXTarget(renderer, id: id, size: SIMD2(bb.x / divisor, bb.y / divisor))
                }
                let frame = try XCTUnwrap(renderer.frames.first)
                let quarter = try XCTUnwrap(frame.draws.first { _, draw in
                    if case let .post(post) = draw {
                        return post.shader == "downsample_quarter_bloom"
                    }
                    return false
                })
                guard case let .post(post) = quarter.value else { return XCTFail("quarter draw missing") }
                XCTAssertEqual(post.texelSizes, [SIMD2(1 / Float(bb.x), 1 / Float(bb.y))])
                let quarterDraw = try XCTUnwrap(renderer.lastFrameDraws.first { $0.operation == quarter.key }?.draw)
                let quarterSource = try XCTUnwrap(quarterDraw.textures["g_Texture0"])
                XCTAssertEqual(SIMD2(quarterSource.width, quarterSource.height), bb)
                guard case let .vector(screen)? = quarterDraw.values(for: .fragment)["g_Screen"],
                      case let .vector(texel)? = quarterDraw.values(for: .fragment)["g_TexelSize"] else {
                    return XCTFail("actual post draw must carry physical screen/texel inputs")
                }
                XCTAssertEqual(screen, [Float(bb.x), Float(bb.y), 1.5])
                XCTAssertEqual(texel, [1 / Float(bb.x), 1 / Float(bb.y)])
                XCTAssertTrue(frame.operations.contains {
                    if case .swapResources = $0.kind {
                        true
                    } else {
                        false
                    }
                })
                let masks = frame.draws.filter { _, draw in
                    if case let .scene(scene) = draw {
                        return scene.target == "_rt_FullAlphaMask"
                    }
                    return false
                }
                XCTAssertEqual(masks.count, 4, "original eyes puppet has four real clipping consumers")
                for operation in masks.keys {
                    XCTAssertTrue(renderer.lastFrameDraws.contains { $0.operation == operation })
                }
                XCTAssertEqual(try XCTUnwrap(layer.lastTexture).width, 384)
                XCTAssertEqual(try XCTUnwrap(layer.lastTexture).height, 256)
                let scope = WPEResourceBindingScope.effect(objectID: "10", effectID: "7")
                let oldHistory = try XCTUnwrap(renderer.renderTarget("history_7", scope: scope))
                let oldScratch = try XCTUnwrap(renderer.renderTarget("scratch_7", scope: scope))
                XCTAssertFalse(oldHistory === oldScratch)
                try await present(driver, layer: layer, label: "one more actual swap")
                XCTAssertTrue(try XCTUnwrap(renderer.renderTarget("history_7", scope: scope)) === oldScratch)
                XCTAssertTrue(try XCTUnwrap(renderer.renderTarget("scratch_7", scope: scope)) === oldHistory)
            }
        }
    }

    @objc func testMetalFXTextAndEffectReplansUseTheOriginalLogicalExtent() async throws {
        let device = try requiredMetalFXDevice()
        let (baseAssets, compiler) = try requiredMetalFXInputs()
        let (document, assets) = try metalFXDocument(baseAssets: baseAssets, text: true)
        try await withMetalFXScale(0.5) {
            let driver = try WPEParitySceneDriver(device: device)
            defer { driver.cleanup() }
            try await driver.load(document: document, assets: assets, settings: .init(bloom: false),
                                  drawableSize: CGSize(width: 384, height: 256), pixelFormat: .rgba8Unorm,
                                  compiler: compiler, diskCache: WPEParityShaderDiskCache(cachesURL: scratch))
            let renderer = try XCTUnwrap(driver.renderer)
            let layer = metalFXLayer(device: device, size: CGSize(width: 384, height: 256))
            let rendererID = ObjectIdentifier(renderer)
            let generation = driver.loadGeneration
            var originalHiVertices: [SIMD2<Float>]?
            for caption in ["Hi", "Hello", "Hi"] {
                renderer.instance.state.setScriptField("text", of: "5", to: .string(caption), invalidating: .textLayout)
                for effects in [true, false, true] {
                    XCTAssertTrue(renderer.instance.state.setEffect("9", of: "5", visible: effects))
                    try await present(driver, layer: layer, label: "caption \(caption) effects \(effects)")
                    XCTAssertEqual(try ObjectIdentifier(XCTUnwrap(driver.renderer)), rendererID)
                    XCTAssertEqual(driver.loadGeneration, generation)
                    XCTAssertEqual(renderer.skipped, [:])
                    XCTAssertEqual([renderer.backbuffer.width, renderer.backbuffer.height], [192, 128])
                    let text = try XCTUnwrap(renderer.texts["5"])
                    XCTAssertEqual(text.object.text, caption)
                    let mesh = try XCTUnwrap(text.layout.mesh)
                    // Native140258ab0: trunc(max-min + 2*padding), with padding active only for effects.
                    // Glyph bounds are the actual font producer input to this size policy, not a scaled RT.
                    let padding: Float = effects ? 16 : 0
                    let logical = SIMD2(Int(mesh.maxX - mesh.minX + padding), Int(mesh.top - mesh.bottom + padding))
                    XCTAssertEqual(text.layout.fboSize, logical)
                    let vertices = mesh.mono.vertices.map { SIMD2($0.x, $0.y) }
                    if caption == "Hi" {
                        if let originalHiVertices {
                            XCTAssertEqual(vertices, originalHiVertices)
                        } else {
                            originalHiVertices = vertices
                        }
                    }
                    if effects {
                        let glyph = try XCTUnwrap(renderer.frames[0].draws.first { _, draw in
                            if case let .scene(scene) = draw {
                                return scene.objectID == "5" && scene.geometry == .textGlyphs(.mono) && scene.fillsComposite
                            }
                            return false
                        })
                        guard case let .scene(description) = glyph.value else { return XCTFail("text fill missing") }
                        let physical = SIMD2(max(1, (logical.x / 2) & ~1), max(1, (logical.y / 2) & ~1))
                        _ = try actualMetalFXTarget(renderer, id: description.target, size: physical)
                        let matrices = try XCTUnwrap(renderer.uniforms(glyph.key)).matrices
                        XCTAssertEqual(matrices.projection.columns.0.x, 2 / Float(logical.x), accuracy: 0.000001)
                        XCTAssertEqual(matrices.projection.columns.1.y, 2 / Float(logical.y), accuracy: 0.000001)
                        let draw = try XCTUnwrap(renderer.lastFrameDraws.first { $0.operation == glyph.key }?.draw)
                        let atlas = try XCTUnwrap(draw.textures["g_Texture0"])
                        XCTAssertEqual([atlas.width, atlas.height], [512, 512], "glyph atlas is never a scaled scene RT")
                        XCTAssertTrue(draw.vertexCount > 0 || draw.indexCount > 0, "real glyph geometry was encoded")
                    }
                    XCTAssertTrue(try XCTUnwrap(driver.executor.lastPresentPass).usedMetalFX)
                    let shown = try readBack(XCTUnwrap(layer.lastTexture), device: device)
                    XCTAssertTrue((8 ..< 120).contains { y in
                        (192 ..< 320).contains { x in shown[(y * 384 + x) * 4 + 1] > 32 }
                    }, "real text ink must reach its logical region of the actual drawable")
                }
            }
        }
    }

    @objc func testMetalFXProductPresentationMatchesPlatformScalerAndCapture() async throws {
        let device = try requiredMetalFXDevice()
        let (baseAssets, compiler) = try requiredMetalFXInputs()
        for hdr in [false, true] {
            let (document, assets) = try metalFXDocument(baseAssets: baseAssets, hdr: hdr)
            try await withMetalFXScale(0.5) {
                let driver = try WPEParitySceneDriver(device: device)
                defer { driver.cleanup() }
                try await driver.load(document: document, assets: assets,
                                      settings: .init(bloom: false, hdrPostProcessing: hdr),
                                      drawableSize: CGSize(width: 384, height: 256),
                                      pixelFormat: hdr ? .rgba16Float : .rgba8Unorm,
                                      compiler: compiler, diskCache: WPEParityShaderDiskCache(cachesURL: scratch))
                let renderer = try XCTUnwrap(driver.renderer)
                let layer = metalFXLayer(device: device, size: CGSize(width: 384, height: 256), hdr: hdr)
                let colorSpace = try XCTUnwrap(layer.colorspace)
                try await present(driver, layer: layer, label: hdr ? "HDR product" : "SDR product")
                XCTAssertTrue(renderer.skipped.isEmpty, "\(renderer.skipped)")
                XCTAssertEqual([renderer.backbuffer.width, renderer.backbuffer.height], [192, 128])
                let pass = try XCTUnwrap(driver.executor.lastPresentPass)
                XCTAssertTrue(pass.usedMetalFX)
                XCTAssertEqual(pass.colorTransfer, hdr ? .linear : .authored)
                let drawable = try XCTUnwrap(layer.lastTexture)
                let shown = try readBack(drawable, device: device)
                if !hdr {
                    let center = (128 * 384 + 96) * 4
                    for (channel, value) in [154, 13, 1].enumerated() {
                        XCTAssertLessThanOrEqual(abs(Int(shown[center + channel]) - value), 3,
                                                 "fixed native terminal color must keep its logical pixel location")
                    }
                    let outside = (16 * 384 + 256) * 4
                    XCTAssertTrue(shown[outside ..< outside + 3].allSatisfy { $0 <= 2 })
                }
                let reference = try nativeMetalFXReference(source: renderer.backbuffer, output: drawable,
                                                           queue: driver.executor.textureSourceCommandQueue)
                try assertMetalFXPixels(shown, reference, hdr: hdr, label: "actual present vs platform")
                let captureResult = await capture(driver, colorSpace: colorSpace)
                let captured = try XCTUnwrap(captureResult)
                XCTAssertEqual(captured.isEDR, hdr)
                XCTAssertEqual(captured.colorSpace?.name, layer.colorspace?.name)
                XCTAssertEqual([captured.texture.width, captured.texture.height], [384, 256])
                try assertMetalFXPixels(readBack(captured.texture, device: device), shown,
                                        hdr: hdr, label: "displayed capture vs actual drawable")
                if hdr {
                    let values = halfValues(shown)
                    XCTAssertTrue(stride(from: 0, to: values.count, by: 4).contains { values[$0] > 1.05 },
                                  "the real HDR scene's red highlight must reach the float drawable")
                }
            }
        }
        // A second real HDR product layout exercises the native bloom depth/texel/RV consumers.
        let (bloomDocument, bloomAssets) = try metalFXDocument(baseAssets: baseAssets, hdr: true, bloom: true)
        try await withMetalFXScale(0.5) {
            let driver = try WPEParitySceneDriver(device: device)
            defer { driver.cleanup() }
            try await driver.load(document: bloomDocument, assets: bloomAssets,
                                  settings: .init(bloom: true, hdrPostProcessing: true),
                                  drawableSize: CGSize(width: 384, height: 256), pixelFormat: .rgba16Float,
                                  compiler: compiler, diskCache: WPEParityShaderDiskCache(cachesURL: scratch))
            let layer = metalFXLayer(device: device, size: CGSize(width: 384, height: 256), hdr: true)
            try await present(driver, layer: layer, label: "physical HDR bloom")
            let renderer = try XCTUnwrap(driver.renderer)
            // physical128-high BB permits N=7, unlike logical256-high N=8.
            let frame = renderer.frames[0]
            // Original divided post targets have a two-pixel minimum, independently of bloom depth.
            let deepest = try actualMetalFXTarget(renderer, id: "_rt_128FrameBuffer", size: SIMD2(2, 2))
            XCTAssertEqual(deepest.pixelFormat, .rgba16Float)
            XCTAssertFalse(frame.resources.contains { $0.id == "_rt_256FrameBuffer" })
            let down = try XCTUnwrap(frame.draws.first { _, draw in
                if case let .post(post) = draw {
                    return post.shader == "hdr_downsample_bloom"
                }
                return false
            })
            guard case let .post(description) = down.value else { return XCTFail("HDR downsample absent") }
            let rv: [Float] = [1 / 192, 1 / 128, -1 / 192, -1 / 128]
            XCTAssertEqual(description.constants["g_RenderVar0"], rv)
            let actual = try XCTUnwrap(renderer.lastFrameDraws.first { $0.operation == down.key }?.draw)
            guard case let .vector(consumed)? = actual.constants[.fragment]?["g_RenderVar0"] else {
                return XCTFail("actual HDR draw did not consume RV0")
            }
            XCTAssertEqual(consumed, rv)
        }
        // A float producer cannot be handed to the spatial scaler as an 8-bit tone mapper.
        let (hdrDocument, assets) = try metalFXDocument(baseAssets: baseAssets, hdr: true)
        try await withMetalFXScale(0.5) {
            let driver = try WPEParitySceneDriver(device: device)
            defer { driver.cleanup() }
            try await driver.load(document: hdrDocument, assets: assets, settings: .init(hdrPostProcessing: true),
                                  drawableSize: CGSize(width: 384, height: 256), pixelFormat: .rgba8Unorm,
                                  compiler: compiler, diskCache: WPEParityShaderDiskCache(cachesURL: scratch))
            XCTAssertEqual(driver.executor.upscalePlan.verdict, .hdrScene)
            XCTAssertEqual(try XCTUnwrap(driver.renderer).backbuffer.pixelFormat, .rgba16Float)
            XCTAssertEqual(try XCTUnwrap(driver.renderer).backbuffer.width, 384)
            let layer = metalFXLayer(device: device, size: CGSize(width: 384, height: 256))
            try await present(driver, layer: layer, label: "float to8 native present")
            XCTAssertFalse(try XCTUnwrap(driver.executor.lastPresentPass).usedMetalFX)
        }
    }

    @objc func testMetalFXGeometryDemotionAndUnpresentedReplanKeepThePresentedSource() async throws {
        let device = try requiredMetalFXDevice()
        let (assets, compiler) = try requiredMetalFXInputs()
        let (document, sceneAssets) = try metalFXDocument(baseAssets: assets)
        try await withMetalFXScale(0.5) {
            let driver = try WPEParitySceneDriver(device: device)
            defer { driver.cleanup() }
            try await driver.load(document: document, assets: sceneAssets, settings: .init(bloom: false),
                                  drawableSize: CGSize(width: 384, height: 256), pixelFormat: .rgba8Unorm,
                                  compiler: compiler, diskCache: WPEParityShaderDiskCache(cachesURL: scratch))
            XCTAssertEqual(try XCTUnwrap(driver.renderer).backbuffer.width, 192, "builder's backing seed is used")
            driver.updateSurfaceGeometry(drawableSize: .zero)
            XCTAssertEqual(driver.drawableSize, CGSize(width: 384, height: 256))
            XCTAssertFalse(driver.needsReplan)
            let layer = metalFXLayer(device: device, size: CGSize(width: 513, height: 385))
            let colorSpace = try XCTUnwrap(layer.colorspace)
            try await present(driver, layer: layer, label: "first actual drawable corrects seed")
            XCTAssertEqual(driver.drawableSize, CGSize(width: 513, height: 385))
            XCTAssertTrue(driver.needsReplan)
            let drawableA = try XCTUnwrap(layer.lastTexture)
            XCTAssertTrue(try XCTUnwrap(driver.executor.lastPresentPass).usedMetalFX,
                          "this actual A must use MetalFX before testing active-to-native capture")
            let pixelsA = try readBack(drawableA, device: device)
            let sourceA = try ObjectIdentifier(XCTUnwrap(driver.renderer).backbuffer)
            // An inactive candidate must not discard the scaler needed to replay the last actual FX present.
            driver.setPresentFitMode(.center)
            let centered = await driver.replan()
            XCTAssertTrue(centered)
            XCTAssertEqual(driver.executor.upscalePlan.verdict, .fitModeIncompatible)
            XCTAssertEqual(try XCTUnwrap(driver.renderer).backbuffer.width, 384)
            XCTAssertNotNil(driver.executor.metalFXUpscaler)
            let inactiveResult = await capture(driver, colorSpace: colorSpace)
            let inactiveCapture = try XCTUnwrap(inactiveResult)
            try assertMetalFXPixels(readBack(inactiveCapture.texture, device: device), pixelsA, hdr: false,
                                    label: "unpresented center/native B replays last actual FX A")
            driver.setPresentFitMode(.stretch)
            let corrected = await driver.replan()
            XCTAssertTrue(corrected)
            XCTAssertEqual(try XCTUnwrap(driver.renderer).backbuffer.width, 256)
            XCTAssertNotEqual(try ObjectIdentifier(XCTUnwrap(driver.renderer).backbuffer), sourceA)
            let resultA = await capture(driver, colorSpace: colorSpace)
            let captureA = try XCTUnwrap(resultA)
            try assertMetalFXPixels(readBack(captureA.texture, device: device), pixelsA, hdr: false,
                                    label: "unpresented resized B retains A source and pass")
            try await present(driver, layer: layer, label: "resized B")
            let pixelsB = try readBack(XCTUnwrap(layer.lastTexture), device: device)
            let time = try XCTUnwrap(driver.renderer).instance.clock.time
            let scriptID = try ObjectIdentifier(XCTUnwrap(XCTUnwrap(driver.renderer).instance.script))
            // Real consumer seam: no scaler is available; encodePresent must demote the active reduced plan.
            driver.executor.metalFXUpscaler = nil
            let declined = try XCTUnwrap(driver.renderAndPresentFrame(
                layer: layer, timestamp: nextTimestamp(), pointer: SIMD2(0.5, 0.5)
            ))
            XCTAssertNotEqual(declined.status, .notEnqueued, "demotion is released only after this CB commits")
            XCTAssertNotEqual(declined.status, .enqueued)
            XCTAssertEqual(driver.executor.upscalePlan.verdict, .declinedAtPresent)
            XCTAssertTrue(driver.needsReplan)
            XCTAssertFalse(driver.executor.takePresentSideDemotion(), "Driver drained its own postcommit handoff")
            try await settle(driver, label: "declined frame")
            XCTAssertEqual(declined.status, .completed)
            XCTAssertNil(declined.error)
            let declinedPixels = try readBack(XCTUnwrap(layer.lastTexture), device: device)
            let nativeReplanned = await driver.replan()
            XCTAssertTrue(nativeReplanned)
            let native = try XCTUnwrap(driver.renderer)
            XCTAssertEqual([native.backbuffer.width, native.backbuffer.height], [513, 385])
            XCTAssertGreaterThanOrEqual(native.instance.clock.time, time)
            XCTAssertEqual(try ObjectIdentifier(XCTUnwrap(native.instance.script)), scriptID)
            let retainedResult = await capture(driver, colorSpace: colorSpace)
            let retained = try XCTUnwrap(retainedResult)
            try assertMetalFXPixels(readBack(retained.texture, device: device), declinedPixels, hdr: false,
                                    label: "unpresented native replan retains actual declined present")
            try await present(driver, layer: layer, label: "native after demotion")
            XCTAssertFalse(try XCTUnwrap(driver.executor.lastPresentPass).usedMetalFX)
            let nativePixels = try readBack(XCTUnwrap(layer.lastTexture), device: device)
            XCTAssertFalse(nativePixels.isEmpty)
            XCTAssertFalse(pixelsB.isEmpty)
            driver.cleanup()
            let cleanedCapture = await capture(driver, colorSpace: colorSpace)
            XCTAssertNil(cleanedCapture)
        }
        // These real product allocations must remain native before their first render, including span producer.
        let nativeCases: [(WPEPresentFitMode, Bool, CGSize, SIMD2<Int>, WPEMetalUpscalePlan.Verdict)] = [
            (.center, false, CGSize(width: 384, height: 256), SIMD2(384, 256), .fitModeIncompatible),
            (.cover, true, CGSize(width: 384, height: 256), SIMD2(384, 256), .settingOff),
            (.contain, false, CGSize(width: 385, height: 257), SIMD2(385, 257), .aspectMismatch),
            (.cover, false, CGSize(width: 64, height: 32), SIMD2(64, 32), .noHeadroom),
        ]
        try await withMetalFXScale(0.5) {
            for (fit, span, drawable, expected, verdict) in nativeCases {
                let driver = try WPEParitySceneDriver(device: device)
                defer { driver.cleanup() }
                driver.setPresentFitMode(fit)
                let frames = WPESceneSpanFrames()
                if span {
                    driver.spanFrames = frames
                }
                try await driver.load(document: document, assets: sceneAssets, settings: .init(bloom: false),
                                      drawableSize: drawable, pixelFormat: .rgba8Unorm, compiler: compiler,
                                      diskCache: WPEParityShaderDiskCache(cachesURL: scratch))
                let source = try XCTUnwrap(driver.renderer).backbuffer
                XCTAssertEqual(SIMD2(source.width, source.height), expected)
                XCTAssertEqual(driver.executor.upscalePlan.verdict, verdict)
                if span {
                    frames.reset(generation: driver.loadGeneration)
                    let command = try XCTUnwrap(driver.renderAndPublishSpanFrame(
                        to: frames, timestamp: nextTimestamp(), pointer: SIMD2(0.5, 0.5)
                    ))
                    try await settle(driver, label: "native span producer")
                    XCTAssertEqual(command.status, .completed)
                    XCTAssertNil(command.error)
                    let packet = try XCTUnwrap(frames.latest())
                    XCTAssertEqual([packet.texture.width, packet.texture.height], [384, 256])
                } else {
                    let layer = metalFXLayer(device: device, size: drawable)
                    try await present(driver, layer: layer, label: "native qualification \(verdict)")
                    XCTAssertFalse(try XCTUnwrap(driver.executor.lastPresentPass).usedMetalFX)
                }
            }
        }
    }

    @MainActor
    @objc func testMetalFXReplanKeepsADeclineObservedWhileBuilding() async throws {
        let device = try requiredMetalFXDevice()
        let (baseAssets, compiler) = try requiredMetalFXInputs()
        let (document, assets) = try metalFXDocument(baseAssets: baseAssets, missingAlbedo: true)
        let admissionPath = try XCTUnwrap(document.imageObjects.first).imageRelativePath
        for reusePreparedScene in [false, true] {
            let gate = MetalFXOneLookupGate()
            // Every candidate admits its image resources after target selection, on @concurrent makePlan.
            // This required data lookup survives prepared-scene reuse; optional autosize albedo probes do not.
            let guardedAssets = try WPEParityProgramAssets(sources: [
                .lookup(XCTUnwrap(assets.roots.first)) { path in
                    if path == admissionPath {
                        gate.blockOnceIfArmed()
                    }
                    return assets.data(path)
                },
            ])
            try await withMetalFXScale(0.5) {
                let driver = try WPEParitySceneDriver(device: device, reusePreparedScene: reusePreparedScene)
                XCTAssertEqual(driver.reusesPreparedScene, reusePreparedScene)
                defer { gate.release(); driver.cleanup() }
                try await driver.load(document: document, assets: guardedAssets, settings: .init(bloom: false),
                                      drawableSize: CGSize(width: 384, height: 256), pixelFormat: .rgba8Unorm,
                                      compiler: compiler, diskCache: WPEParityShaderDiskCache(cachesURL: scratch))
                let layer = metalFXLayer(device: device, size: CGSize(width: 384, height: 256))
                try await present(driver, layer: layer, label: "active A before blocked candidate")
                XCTAssertTrue(try XCTUnwrap(driver.executor.lastPresentPass).usedMetalFX)
                XCTAssertEqual(driver.executor.upscalePlan.verdict, .active)
                let previousID = try ObjectIdentifier(XCTUnwrap(driver.renderer))
                driver.setPresentFitMode(.stretch) // same actual extent, different cover crop/alignment
                XCTAssertTrue(driver.needsReplan)
                gate.arm()
                let candidate = Task { await driver.replan() }
                defer { gate.release(); candidate.cancel() }
                let entered = await XCTWaiter.fulfillment(of: [gate.entered], timeout: 15)
                XCTAssertEqual(entered, .completed, "the actual candidate must enter its controlled build window")
                _ = try XCTUnwrap(gate.didBlock ? true : nil, "no actual armed lookup was observed")
                XCTAssertEqual(try ObjectIdentifier(XCTUnwrap(driver.renderer)), previousID)
                XCTAssertEqual(driver.executor.upscalePlan.verdict, .active)

                driver.executor.metalFXUpscaler = nil
                let declined = try XCTUnwrap(driver.renderAndPresentFrame(
                    layer: layer, timestamp: nextTimestamp(), pointer: SIMD2(0.5, 0.5)
                ))
                XCTAssertNotEqual(declined.status, .notEnqueued)
                XCTAssertNotEqual(declined.status, .enqueued)
                XCTAssertEqual(driver.executor.lastPresentedDrawableSize, CGSize(width: 384, height: 256))
                XCTAssertEqual(driver.executor.upscalePlan.verdict, .declinedAtPresent)
                XCTAssertFalse(try XCTUnwrap(driver.executor.lastPresentPass).usedMetalFX)
                try await settle(driver, label: "decline while candidate is blocked")
                XCTAssertEqual(declined.status, .completed)
                XCTAssertNil(declined.error)

                gate.release()
                let published = await candidate.value
                XCTAssertTrue(published)
                XCTAssertEqual(driver.executor.upscalePlan.verdict, .declinedAtPresent,
                               "a stale active selection must not overwrite the actual present's sticky refusal")
                XCTAssertFalse(driver.needsReplan)
                let native = try XCTUnwrap(driver.renderer)
                XCTAssertNotEqual(ObjectIdentifier(native), previousID)
                XCTAssertEqual([native.backbuffer.width, native.backbuffer.height], [384, 256])
                try await present(driver, layer: layer, label: "native after interleaved decline")
                XCTAssertFalse(try XCTUnwrap(driver.executor.lastPresentPass).usedMetalFX)
            }
        }
    }

    @objc func testMetalFXKeepsNativeTerminalColorForUnormAndSRGBDrawables() async throws {
        let device = try requiredMetalFXDevice()
        let (baseAssets, compiler) = try requiredMetalFXInputs()
        let (document, assets) = try metalFXDocument(baseAssets: baseAssets)
        // Original util/solidlayer writes authored bytes (204,64,16). Native terminal sRGB decoding gives
        // UNORM (154,13,1), while an sRGB attachment encodes those linear values back to (204,64,16).
        for (format, expected): (MTLPixelFormat, [Int]) in [
            (.rgba8Unorm, [154, 13, 1, 255]), (.rgba8Unorm_srgb, [204, 64, 16, 255]),
        ] {
            for scale in [1.0, 0.5] {
                try await withMetalFXScale(scale) {
                    let driver = try WPEParitySceneDriver(device: device)
                    defer { driver.cleanup() }
                    try await driver.load(document: document, assets: assets, settings: .init(bloom: false),
                                          drawableSize: CGSize(width: 384, height: 256), pixelFormat: format,
                                          compiler: compiler, diskCache: WPEParityShaderDiskCache(cachesURL: scratch))
                    let layer = metalFXLayer(device: device, size: CGSize(width: 384, height: 256))
                    layer.pixelFormat = format
                    try await present(driver, layer: layer, label: "terminal color \(format.rawValue), q\(scale)")
                    XCTAssertEqual(try XCTUnwrap(driver.executor.lastPresentPass).usedMetalFX, scale < 1)
                    let pixels = try readBack(XCTUnwrap(layer.lastTexture), device: device)
                    let offset = (128 * 384 + 96) * 4 // Fixed flat panel interior, far from every filter edge.
                    for channel in 0 ..< 4 {
                        XCTAssertLessThanOrEqual(abs(Int(pixels[offset + channel]) - expected[channel]),
                                                 channel == 3 ? 0 : 1,
                                                 "format \(format.rawValue), q\(scale), channel \(channel)")
                    }
                    let colorSpace = try XCTUnwrap(layer.colorspace)
                    let captured = await capture(driver, colorSpace: colorSpace)
                    let capturePixels = try readBack(XCTUnwrap(captured).texture, device: device)
                    for channel in 0 ..< 4 {
                        XCTAssertEqual(capturePixels[offset + channel], pixels[offset + channel])
                    }
                }
            }
        }
    }

    private func requiredMetalFXDevice() throws -> MTLDevice {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        return try XCTUnwrap(MTLFXSpatialScalerDescriptor.supportsDevice(device) ? device : nil,
                             "required MetalFX product gate needs the registered supporting GPU")
    }

    private func requiredMetalFXInputs() throws -> (WPEParityProgramAssets, WPEParityHelperShaderCompiler) {
        do {
            let (_, assets) = try sceneInputs()
            return try (assets, makeCompiler())
        } catch {
            throw TestScratch.requiredInputError(error, failure: NSError(
                domain: "WPEParityMetalFXProductTests.RequiredInputs", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Required original assets/toolchain unavailable: \(error)"]
            ))
        }
    }

    private nonisolated(nonsending) func withMetalFXScale(_ scale: Double, _ body: () async throws -> Void) async throws {
        let defaults = UserDefaults.appScoped()
        guard defaults !== UserDefaults.standard else {
            throw NSError(domain: "WPEParityMetalFXProductTests.Isolation", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Product gate requires isolated test defaults"])
        }
        let key = WPEMetalFXSpatialUpscaler.renderScaleDefaultsKey
        let previous = defaults.object(forKey: key)
        defaults.set(scale, forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        XCTAssertEqual(WPEMetalFXSpatialUpscaler.renderScale, scale)
        try await body()
    }

    private func metalFXLayer(device: MTLDevice, size: CGSize, hdr: Bool = false) -> RecordingLayer {
        let layer = RecordingLayer()
        layer.device = device
        layer.pixelFormat = hdr ? .rgba16Float : .rgba8Unorm
        layer.colorspace = CGColorSpace(name: hdr ? CGColorSpace.extendedLinearSRGB : CGColorSpace.sRGB)
        layer.framebufferOnly = false
        layer.drawableSize = size
        WPEDisplayHDROutput.apply(to: layer, hdrOutputEnabled: hdr)
        return layer
    }

    @discardableResult
    private func actualMetalFXTarget(_ renderer: WPEParityFrameRenderer, id: WPEResourceID,
                                     size: SIMD2<Int>) throws -> MTLTexture {
        let texture = try XCTUnwrap(renderer.renderTarget(id), "missing actual target \(id)")
        XCTAssertEqual(SIMD2(texture.width, texture.height), size, "\(id)")
        return texture
    }

    private func metalFXDocument(baseAssets: WPEParityProgramAssets, hdr: Bool = false, bloom: Bool = false,
                                 targets: Bool = false, clippedPuppet: Bool = false, text: Bool = false,
                                 missingAlbedo: Bool = false)
        throws -> (WPESceneDocument, WPEParityProgramAssets) {
        let wpeRoot = try XCTUnwrap(baseAssets.roots.last)
        var sources: [WPEParityProgramAssets.Source] = [.directory(scratch)] + baseAssets.sources
        sources.append(.directory(wpeRoot.appending(path: "effects/tint")))
        var panel: [String: Any] = [
            "id": 10, "image": "models/util/solidlayer.json", "name": "fixed panel", "size": "128 64",
            "origin": "96 128 0", "color": hdr ? "1 0.25 0.0625" : "0.8 0.25 0.0625", "brightness": hdr ? 4 : 1, "solid": true,
            "alpha": ["value": 1, "script": "export function cursorClick(event) { thisLayer.alpha = 0.375; }"],
        ]
        var objects: [[String: Any]] = [panel, [
            "id": 900, "name": "screen input probe", "origin": ["value": "0 0 0", "script": """
            export function update(value) {
              return new Vec3(engine.screenResolution.x, engine.screenResolution.y, input.cursorScreenPosition.x);
            }
            """],
        ]]
        if targets {
            func pass(_ target: String? = nil, _ source: String = "previous") -> [String: Any] {
                var result: [String: Any] = ["material": "materials/util/passthrough.json",
                                             "bind": [["index": 0, "name": source]]]
                result["target"] = target
                return result
            }
            let effect: [String: Any] = ["fbos": [
                ["name": "thin", "format": "rgba8888", "width": 128, "height": 16, "unique": true],
                ["name": "fit", "format": "rgba8888", "width": 401, "height": 203, "fit": 75, "scale": 258, "unique": true],
                ["name": "history", "format": "rgba8888", "width": 64, "height": 32, "unique": true],
                ["name": "scratch", "format": "rgba8888", "width": 64, "height": 32, "unique": true],
                ["name": "shared", "format": "rgba8888", "width": 64, "height": 32],
            ], "passes": [pass("thin"), pass("fit", "thin"), pass("history", "fit"),
                          pass("scratch", "history"), ["command": "swap", "source": "history", "target": "scratch"],
                          pass("shared", "history"), pass(nil, "history")]]
            try writeMetalFXJSON(effect, path: "effects/metalfx-targets.json")
            try writeMetalFXJSON(["passes": [pass(nil, "shared")]], path: "effects/metalfx-shared.json")
            panel["effects"] = [["id": 7, "file": "effects/metalfx-targets.json", "visible": true]]
            objects[0] = panel
            objects.append(["id": 11, "image": "models/util/solidlayer.json", "size": "128 16",
                            "origin": "288 64 0", "effects": [["id": 8, "file": "effects/metalfx-shared.json"]]])
        }
        if clippedPuppet {
            let home = try URL(fileURLWithPath: String(cString: XCTUnwrap(getpwuid(getuid())).pointee.pw_dir))
            let package = ProcessInfo.processInfo.environment["WPE_METALFX_CLIP_PKG"].map { URL(fileURLWithPath: $0) }
                ?? home.appending(path: "Library/Application Support/Steam/steamapps/workshop/content/431960/3808922316/scene.pkg")
            let provider = try WPEPackageSceneAssetProvider(packageURL: package)
            let model = try WPEMdlParser.parse(data: provider.data(atRelativePath: "models/眼睛_puppet.mdl"))
            XCTAssertEqual(model.meshes.reduce(0) { $0 + $1.clipGroups.count }, 4, "required original eyes clip groups")
            sources.append(.lookup(package.deletingLastPathComponent()) { try? provider.data(atRelativePath: $0) })
            objects.append(["id": 90, "image": "models/眼睛.json", "origin": "288 192 0", "size": "128 64",
                            "scale": "0.04 0.04 1", "colorBlendMode": 5, "copybackground": false])
            // Native MSAA allocation requires an actual model. Keep its original mesh, material and textures;
            // the instance only isolates unrelated lighting/fog/reflection from this render-scale guard.
            let modelPackage = ProcessInfo.processInfo.environment["WPE_METALFX_MODEL_PKG"].map { URL(fileURLWithPath: $0) }
                ?? home.appending(path: "Library/Application Support/Steam/steamapps/workshop/content/431960/3437487219/scene.pkg")
            let modelProvider = try WPEPackageSceneAssetProvider(packageURL: modelPackage)
            let modelBytes = try modelProvider.data(atRelativePath: "models/Earth/Earth.mdl")
            XCTAssertFalse(try WPEMdlParser.parse(data: modelBytes).meshes.isEmpty)
            sources.append(.lookup(modelPackage.deletingLastPathComponent()) { try? modelProvider.data(atRelativePath: $0) })
            objects.append(["id": 91, "model": "models/Earth/Earth.mdl", "origin": "320 224 0",
                            "scale": "0.16 0.16 0.16", "angles": "0 0 0", "perspective": false, "solid": false,
                            "instance": ["combos": ["LIGHTING": 0, "FOG": 0, "REFLECTION": 0]]])
        }
        if text {
            objects.append(["id": 5, "name": "text relayout", "text": "Hi", "font": "fonts/NotoSans-Regular.ttf",
                            "pointsize": 8, "padding": "8 8", "origin": "256 192 0", "color": "1 1 1",
                            "effects": [["id": 9, "file": "effects/tint/effect.json", "visible": true,
                                         "passes": [["constantshadervalues": ["color": "1 1 1", "alpha": 1]]]]]])
        }
        if missingAlbedo {
            // Autosize layers size from their albedo file (missing: the 6×6 placeholder), read on every plan build.
            try writeMetalFXJSON(["material": "materials/metalfx-autosize.json", "autosize": true],
                                 path: "models/metalfx-autosize.json")
            let albedoPass: [String: Any] = ["shader": "flat", "blending": "translucent", "cullmode": "nocull",
                                             "depthtest": "disabled", "depthwrite": "disabled",
                                             "textures": ["metalfx-missing-albedo"]]
            try writeMetalFXJSON(["passes": [albedoPass]], path: "materials/metalfx-autosize.json")
            objects.append(["id": 12, "image": "models/metalfx-autosize.json", "origin": "288 192 0"])
        }
        let json: [String: Any] = [
            "camera": ["center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": 384, "height": 256], "clearenabled": true,
                        // Native HDR allocation needs scene bloom; the user setting independently disables its draws.
                        "clearcolor": "0 0 0", "hdr": hdr, "bloom": hdr || bloom || targets, "bloomhdriterations": 8,
                        "bloomhdrstrength": 0.1, "camerashake": false, "cameraparallax": false],
            "objects": objects,
        ]
        let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: json),
                                                        userValues: [:])
        return (document, WPEParityProgramAssets(sources: sources))
    }

    private func writeMetalFXJSON(_ value: Any, path: String) throws {
        let url = scratch.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: value).write(to: url)
    }

    /// Independent external consumer: production only supplies its already-rendered texture, not an algorithm.
    private func nativeMetalFXReference(source: MTLTexture, output: MTLTexture,
                                        queue: MTLCommandQueue) throws -> [UInt8] {
        let descriptor = MTLFXSpatialScalerDescriptor()
        descriptor.inputWidth = source.width
        descriptor.inputHeight = source.height
        descriptor.outputWidth = output.width
        descriptor.outputHeight = output.height
        descriptor.colorTextureFormat = source.pixelFormat
        descriptor.outputTextureFormat = output.pixelFormat
        descriptor.colorProcessingMode = source.pixelFormat == .rgba16Float ? .hdr : .perceptual
        let scaler = try XCTUnwrap(descriptor.makeSpatialScaler(device: source.device))
        XCTAssertTrue(source.usage.isSuperset(of: scaler.colorTextureUsage))
        let targetDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: output.pixelFormat, width: output.width, height: output.height, mipmapped: false
        )
        targetDescriptor.storageMode = .private
        targetDescriptor.usage = scaler.outputTextureUsage.union(.renderTarget)
        let target = try XCTUnwrap(source.device.makeTexture(descriptor: targetDescriptor))
        scaler.colorTexture = source
        scaler.outputTexture = target
        scaler.inputContentWidth = source.width
        scaler.inputContentHeight = source.height
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        scaler.encode(commandBuffer: command)
        command.commit()
        awaitCompletion(command)
        let raw = try readBack(target, device: source.device)
        guard source.pixelFormat == .rgba8Unorm, output.pixelFormat == .rgba8Unorm else { return raw }
        // Bare MetalFX returns authored/perceptual bytes. Apply the documented terminal sRGB transfer on CPU,
        // independently of the production shader/encoder. The separate fixed native color guard protects it.
        return raw.enumerated().map { index, byte in
            guard index % 4 != 3 else { return 255 }
            let encoded = Double(byte) / 255
            let linear = encoded <= 0.04045 ? encoded / 12.92 : pow((encoded + 0.055) / 1.055, 2.4)
            return UInt8(min(255, max(0, Int((linear * 255).rounded()))))
        }
    }

    private func awaitCompletion(_ command: MTLCommandBuffer) {
        command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed)
        XCTAssertNil(command.error)
    }

    private func halfValues(_ bytes: [UInt8]) -> [Float] {
        stride(from: 0, to: bytes.count, by: 2).map {
            Float(Float16(bitPattern: UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8))
        }
    }

    private func assertMetalFXPixels(_ actual: [UInt8], _ expected: [UInt8], hdr: Bool, label: String) throws {
        XCTAssertFalse(actual.isEmpty, label)
        XCTAssertEqual(actual.count, expected.count, label)
        guard actual.count == expected.count, !actual.isEmpty else { return }
        if hdr {
            let a = halfValues(actual), e = halfValues(expected)
            let rgb = a.indices.filter { $0 % 4 != 3 }
            XCTAssertTrue(rgb.allSatisfy { a[$0].isFinite && e[$0].isFinite }, label)
            let worst = rgb.reduce(Float.zero) { max($0, abs(a[$1] - e[$1])) }
            XCTAssertLessThanOrEqual(worst, 0.015, label)
            XCTAssertTrue(stride(from: 3, to: a.count, by: 4).allSatisfy { a[$0] == 1 }, label)
        } else {
            let worst = zip(actual.enumerated(), expected).reduce(0) { result, pair in
                pair.0.offset % 4 == 3 ? result : max(result, abs(Int(pair.0.element) - Int(pair.1)))
            }
            XCTAssertLessThanOrEqual(worst, 2, label)
            XCTAssertTrue(stride(from: 3, to: actual.count, by: 4).allSatisfy { actual[$0] == 255 }, label)
        }
    }
}

/// Test-only scheduling of an external read boundary. The armed bit clears before waiting, so present reads and
/// the replacement native candidate cannot block a second time. No renderer state or result is mocked here.
private final class MetalFXOneLookupGate: @unchecked Sendable {
    let entered = XCTestExpectation(description: "MetalFX candidate entered its first armed asset lookup")
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var armed = false
    private var blocked = false

    var didBlock: Bool {
        lock.withLock { blocked }
    }

    func arm() {
        lock.withLock { armed = true }
    }

    func blockOnceIfArmed() {
        let shouldWait = lock.withLock {
            guard armed else { return false }
            armed = false
            blocked = true
            return true
        }
        guard shouldWait else { return }
        entered.fulfill()
        semaphore.wait()
    }

    func release() {
        semaphore.signal()
    }
}
#endif
