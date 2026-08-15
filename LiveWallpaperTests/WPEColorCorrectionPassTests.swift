#if !LITE_BUILD
import LiveWallpaperCore
import Metal
import Testing
@testable import LiveWallpaper

/// Pixel-level verification of the engine colour-correction pass.
///
/// A rendering change cannot be signed off by reading the shader — this pushes
/// known colours through the real pipeline and asserts on the bytes that come
/// back, which is the only claim about a GPU pass worth making.
@Suite("Engine colour correction pass", .serialized)
struct WPEColorCorrectionPassTests {

    private struct Harness {
        let device: MTLDevice
        let queue: MTLCommandQueue
        let pipeline: MTLRenderPipelineState
    }

    private func harness() throws -> Harness {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        // `makeDefaultLibrary()` with no bundle, exactly as the executor does:
        // tests run inside the app host, so the app's own .metallib is the
        // default one. Passing the test bundle instead finds no library at all.
        let library = try #require(device.makeDefaultLibrary())
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "wpe_fullscreen_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "wpe_color_correction_fragment")
        descriptor.colorAttachments[0].pixelFormat = .rgba8Unorm
        return Harness(
            device: device, queue: queue,
            pipeline: try device.makeRenderPipelineState(descriptor: descriptor)
        )
    }

    /// Runs one opaque RGB triple through the pass and returns what came out.
    private func grade(
        _ rgb: (UInt8, UInt8, UInt8),
        _ correction: WPEEngineColorCorrection
    ) throws -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let h = try harness()

        let sourceDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false
        )
        sourceDescriptor.usage = [.shaderRead]
        let source = try #require(h.device.makeTexture(descriptor: sourceDescriptor))
        var input: [UInt8] = [rgb.0, rgb.1, rgb.2, 255]
        source.replace(
            region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
            withBytes: &input, bytesPerRow: 4
        )

        let destinationDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false
        )
        destinationDescriptor.usage = [.renderTarget, .shaderRead]
        let destination = try #require(h.device.makeTexture(descriptor: destinationDescriptor))

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = destination
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store

        let buffer = try #require(h.queue.makeCommandBuffer())
        let encoder = try #require(buffer.makeRenderCommandEncoder(descriptor: pass))
        encoder.setRenderPipelineState(h.pipeline)
        var uniforms = WPEColorCorrectionUniforms(
            brightness: Float(correction.brightness),
            contrast: Float(correction.contrast),
            saturation: Float(correction.saturation),
            hueRadians: Float(correction.hueDegrees * .pi / 180)
        )
        encoder.setFragmentTexture(source, index: 0)
        encoder.setFragmentBytes(
            &uniforms, length: MemoryLayout<WPEColorCorrectionUniforms>.stride, index: 0
        )
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
        #expect(buffer.error == nil)

        var out = [UInt8](repeating: 0, count: 4)
        destination.getBytes(
            &out, bytesPerRow: 4, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0
        )
        return (out[0], out[1], out[2], out[3])
    }

    @Test("Neutral settings leave every channel where it was")
    func neutralIsIdentity() throws {
        // The control the rest of the suite rests on: if this drifts, every
        // other expectation below is measuring the wrong baseline.
        let out = try grade((37, 211, 102), .neutral)
        #expect(abs(Int(out.r) - 37) <= 1)
        #expect(abs(Int(out.g) - 211) <= 1)
        #expect(abs(Int(out.b) - 102) <= 1)
        #expect(out.a == 255)
    }

    @Test("Zero saturation collapses to that colour's own luma, not to mid grey")
    func zeroSaturationIsLuma() throws {
        let out = try grade((37, 211, 102), WPEEngineColorCorrection(
            brightness: 0, contrast: 1, saturation: 0, hueDegrees: 0
        ))
        #expect(out.r == out.g)
        #expect(out.g == out.b)
        // Rec. 709 on that colour: dominated by the green channel, so the result
        // must land well above mid grey. Collapsing to 128 would mean the shader
        // is averaging rather than weighting.
        #expect(out.r > 140)
    }

    @Test("Contrast pushes away from mid grey in both directions")
    func contrastExpandsAroundMidGrey() throws {
        let boosted = WPEEngineColorCorrection(
            brightness: 0, contrast: 1.6, saturation: 1, hueDegrees: 0
        )
        let dark = try grade((80, 80, 80), boosted)
        let light = try grade((180, 180, 180), boosted)
        #expect(dark.r < 80)
        #expect(light.r > 180)

        // Mid grey is the pivot and must not move.
        let pivot = try grade((128, 128, 128), boosted)
        #expect(abs(Int(pivot.r) - 128) <= 2)
    }

    @Test("Brightness is additive and clamps instead of wrapping")
    func brightnessClamps() throws {
        let out = try grade((200, 200, 200), WPEEngineColorCorrection(
            brightness: 0.5, contrast: 1, saturation: 1, hueDegrees: 0
        ))
        // Wrapping would produce a dark pixel from a bright one — the classic
        // symptom of an unclamped additive term.
        #expect(out.r == 255)
    }

    @Test("A hue rotation moves the colour and preserves the grey-axis component")
    func hueRotationPreservesGreyAxis() throws {
        let out = try grade((200, 60, 60), WPEEngineColorCorrection(
            brightness: 0, contrast: 1, saturation: 1, hueDegrees: 120
        ))
        #expect(Int(out.r) != 200, "a 120° rotation must actually move the colour")

        // What an axis rotation actually conserves is the projection onto the
        // grey axis — r+g+b — not Rec. 709 luma. Asserting luma here failed, and
        // it was the assertion that was wrong: rotating a saturated red toward
        // green necessarily raises perceived brightness (0.2126 → 0.7152).
        //
        // This is a known, deliberate divergence from `CIHueAdjust`, which the
        // video path uses and which rotates in a luma-preserving space. The two
        // agree on direction and on neutral; they differ in how much a strongly
        // saturated colour brightens. Revisit if a preset ever makes that visible.
        let before = 200 + 60 + 60
        let after = Int(out.r) + Int(out.g) + Int(out.b)
        #expect(abs(after - before) <= 6)
    }

    @Test("The real preset's grade is visibly different from no grade at all")
    func observedPresetGradeChangesPixels() throws {
        // Preset 3544156790's published values, through the parser rather than
        // hand-computed, so this covers the mapping and the shader together.
        let correction = try #require(WPEEngineColorCorrection.parse([
            "wec_e": .bool(true), "wec_brs": .number(50), "wec_con": .number(80),
            "wec_hue": .number(46), "wec_sa": .number(80)
        ]))
        let plain = try grade((120, 90, 160), .neutral)
        let graded = try grade((120, 90, 160), correction)
        let delta = abs(Int(graded.r) - Int(plain.r))
            + abs(Int(graded.g) - Int(plain.g))
            + abs(Int(graded.b) - Int(plain.b))
        #expect(delta > 10, "the author's grade must reach the pixels, not just the model")
    }
}
#endif
