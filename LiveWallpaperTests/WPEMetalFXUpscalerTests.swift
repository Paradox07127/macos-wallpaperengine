import CoreGraphics
import Metal
import MetalFX
import Testing
@testable import LiveWallpaper

@Suite("WPE MetalFX spatial upscaler")
struct WPEMetalFXUpscalerTests {

    // MARK: - Render-scale key semantics

    @Test("Render scale clamps to [0.25, 1.0] and defaults to 1.0")
    func renderScaleClampAndDefault() {
        #expect(WPEMetalFXSpatialUpscaler.renderScale(fromRaw: nil) == 1.0)
        #expect(WPEMetalFXSpatialUpscaler.renderScale(fromRaw: 0.75) == 0.75)
        #expect(WPEMetalFXSpatialUpscaler.renderScale(fromRaw: 0.25) == 0.25)
        #expect(WPEMetalFXSpatialUpscaler.renderScale(fromRaw: 1.0) == 1.0)
        // Below range clamps up, above range clamps down (= experiment off).
        #expect(WPEMetalFXSpatialUpscaler.renderScale(fromRaw: 0.0) == 0.25)
        #expect(WPEMetalFXSpatialUpscaler.renderScale(fromRaw: 2.0) == 1.0)
        #expect(WPEMetalFXSpatialUpscaler.renderScale(fromRaw: .nan) == 1.0)
        #expect(WPEMetalFXSpatialUpscaler.renderScale(fromRaw: .infinity) == 1.0)
    }

    @Test("Scaled dimension floors, aligns to 2, and never drops below 64")
    func scaledDimensionRules() {
        #expect(WPEMetalFXSpatialUpscaler.scaledDimension(3840, scale: 0.75) == 2880)
        #expect(WPEMetalFXSpatialUpscaler.scaledDimension(2160, scale: 0.75) == 1620)
        // 2234 × 0.75 = 1675.5 → floor 1675 → even 1674.
        #expect(WPEMetalFXSpatialUpscaler.scaledDimension(2234, scale: 0.75) == 1674)
        // Tiny inputs floor at 64.
        #expect(WPEMetalFXSpatialUpscaler.scaledDimension(100, scale: 0.25) == 64)
    }

    // MARK: - Eligibility (pure)

    @Test("contain/cover need an exactly equal aspect; center never qualifies")
    func eligibilityFitModeSemantics() {
        // 16:9 -> 16:9 exact: contain/cover degenerate to the stretch mapping.
        #expect(WPEMetalFXSpatialUpscaler.preScalerRejection(
            fitMode: .contain,
            sourceWidth: 2880, sourceHeight: 1620,
            drawableWidth: 3840, drawableHeight: 2160
        ) == nil)
        // A 2px-off aspect would letterbox under contain — the scaler would
        // stretch that letterbox away, so exact equality is required.
        #expect(WPEMetalFXSpatialUpscaler.preScalerRejection(
            fitMode: .contain,
            sourceWidth: 3838, sourceHeight: 2160,
            drawableWidth: 3840, drawableHeight: 2160
        ) == .aspectMismatch)
        // center keeps source pixels 1:1 — a fullscreen scale is never right.
        #expect(WPEMetalFXSpatialUpscaler.preScalerRejection(
            fitMode: .center,
            sourceWidth: 2880, sourceHeight: 1620,
            drawableWidth: 3840, drawableHeight: 2160
        ) == .fitMode)
    }

    @Test("Source larger than the drawable is rejected (spatial only upscales)")
    func eligibilityRejectsDownscale() {
        let rejection = WPEMetalFXSpatialUpscaler.preScalerRejection(
            fitMode: .stretch,
            sourceWidth: 4096, sourceHeight: 2160,
            drawableWidth: 3840, drawableHeight: 2160
        )
        #expect(rejection == .sourceExceedsDrawable)
    }

    @Test("Stretch ignores aspect: full-rect to full-rect at any ratio")
    func eligibilityStretchIgnoresAspect() {
        // 16:9 source onto a 16:10 drawable — stretch and the scaler both map
        // the full source rect onto the full drawable, so this now qualifies.
        let rejection = WPEMetalFXSpatialUpscaler.preScalerRejection(
            fitMode: .stretch,
            sourceWidth: 2880, sourceHeight: 1620,
            drawableWidth: 3840, drawableHeight: 2400
        )
        #expect(rejection == nil)
    }

    @Test("Matching stretch upscale passes the pre-scaler checks")
    func eligibilityAcceptsMatchingUpscale() {
        let rejection = WPEMetalFXSpatialUpscaler.preScalerRejection(
            fitMode: .stretch,
            sourceWidth: 2880, sourceHeight: 1620,
            drawableWidth: 3840, drawableHeight: 2160
        )
        #expect(rejection == nil)
    }

    // MARK: - Real-device probes
    //
    // These are probes, not gates: whether a given (format, size) combination
    // yields a scaler is exactly the intelligence this experiment exists to
    // gather (no public format-support table). The assertions only require that
    // creation doesn't crash and that a created scaler encodes without error;
    // the created/not-created outcome is printed to the test log.

    @Test("Spatial scaler probe: production srgb combo 2880x1620 -> 3840x2160")
    func spatialScalerProbeProductionFormats() throws {
        // The production pair: scene output and drawable are both rgba8Unorm_srgb.
        try runScalerProbe(inputFormat: .rgba8Unorm_srgb, label: "rgba8Unorm_srgb")
    }

    @Test("Spatial scaler probe: rgba16Float input -> bgra8 output (HDR case)")
    func spatialScalerProbeRGBA16Float() throws {
        try runScalerProbe(inputFormat: .rgba16Float, label: "rgba16Float")
        // NOTE: production now rejects HDR input pre-scaler (.hdrInput) — this
        // probe only tracks whether the OS would accept the combination.
    }

    private func runScalerProbe(inputFormat: MTLPixelFormat, label: String) throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            print("[metalfx-probe] no Metal device; skipping")
            return
        }
        guard MTLFXSpatialScalerDescriptor.supportsDevice(device) else {
            print("[metalfx-probe] MTLFXSpatialScaler unsupported on \(device.name)")
            return
        }
        let descriptor = MTLFXSpatialScalerDescriptor()
        descriptor.inputWidth = 2880
        descriptor.inputHeight = 1620
        descriptor.outputWidth = 3840
        descriptor.outputHeight = 2160
        descriptor.colorTextureFormat = inputFormat
        descriptor.outputTextureFormat = .rgba8Unorm_srgb
        descriptor.colorProcessingMode = .perceptual
        let scaler = descriptor.makeSpatialScaler(device: device)
        print(
            "[metalfx-probe] \(label) -> rgba8Unorm_srgb 2880x1620 -> 3840x2160: "
                + "created=\(scaler != nil) device=\(device.name)"
        )
        guard let scaler else { return }

        func makeTexture(format: MTLPixelFormat, width: Int, height: Int, usage: MTLTextureUsage) throws -> MTLTexture {
            let texDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format, width: width, height: height, mipmapped: false
            )
            texDescriptor.storageMode = .private
            texDescriptor.usage = usage
            return try #require(device.makeTexture(descriptor: texDescriptor))
        }

        let input = try makeTexture(
            format: inputFormat, width: 2880, height: 1620, usage: scaler.colorTextureUsage
        )
        let output = try makeTexture(
            format: .rgba8Unorm_srgb, width: 3840, height: 2160, usage: scaler.outputTextureUsage
        )
        let queue = try #require(device.makeCommandQueue())
        let commandBuffer = try #require(queue.makeCommandBuffer())
        scaler.colorTexture = input
        scaler.inputContentWidth = input.width
        scaler.inputContentHeight = input.height
        scaler.outputTexture = output
        scaler.encode(commandBuffer: commandBuffer)
        scaler.colorTexture = nil
        scaler.outputTexture = nil
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        #expect(commandBuffer.status == .completed, "\(label) scaler encode failed: \(String(describing: commandBuffer.error))")
        #expect(commandBuffer.error == nil)
        print("[metalfx-probe] \(label) encode status=\(commandBuffer.status.rawValue) error=\(String(describing: commandBuffer.error))")
    }
}
