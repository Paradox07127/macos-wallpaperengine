import CoreGraphics
import Foundation
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

    @Test("Non-stretch fit modes are rejected")
    func eligibilityRejectsFitMode() {
        let rejection = WPEMetalFXSpatialUpscaler.preScalerRejection(
            fitMode: .contain,
            sourceWidth: 2880, sourceHeight: 1620,
            drawableWidth: 3840, drawableHeight: 2160
        )
        #expect(rejection == .fitMode)
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

    @Test("Aspect mismatch beyond 0.5% is rejected")
    func eligibilityRejectsAspectMismatch() {
        // 16:9 source onto a 16:10 drawable.
        let rejection = WPEMetalFXSpatialUpscaler.preScalerRejection(
            fitMode: .stretch,
            sourceWidth: 2880, sourceHeight: 1620,
            drawableWidth: 3840, drawableHeight: 2400
        )
        #expect(rejection == .aspectMismatch)
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

    @Test("Spatial scaler probe: bgra8 2880x1620 -> 3840x2160")
    func spatialScalerProbeBGRA8() throws {
        try runScalerProbe(inputFormat: .bgra8Unorm, label: "bgra8Unorm")
    }

    @Test("Spatial scaler probe: rgba16Float input -> bgra8 output (HDR case)")
    func spatialScalerProbeRGBA16Float() throws {
        try runScalerProbe(inputFormat: .rgba16Float, label: "rgba16Float")
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
        descriptor.outputTextureFormat = .bgra8Unorm
        descriptor.colorProcessingMode = .perceptual
        let scaler = descriptor.makeSpatialScaler(device: device)
        print(
            "[metalfx-probe] \(label) -> bgra8Unorm 2880x1620 -> 3840x2160: "
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
            format: .bgra8Unorm, width: 3840, height: 2160, usage: scaler.outputTextureUsage
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
