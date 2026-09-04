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
        #expect(WPEMetalFXSpatialUpscaler.renderScale(fromRaw: 0.0) == 0.25)
        #expect(WPEMetalFXSpatialUpscaler.renderScale(fromRaw: 2.0) == 1.0)
        #expect(WPEMetalFXSpatialUpscaler.renderScale(fromRaw: .nan) == 1.0)
        #expect(WPEMetalFXSpatialUpscaler.renderScale(fromRaw: .infinity) == 1.0)
    }

    @Test("Scaled dimension floors, aligns to 2, and never drops below 64")
    func scaledDimensionRules() {
        #expect(WPEMetalFXSpatialUpscaler.scaledDimension(3840, scale: 0.75) == 2880)
        #expect(WPEMetalFXSpatialUpscaler.scaledDimension(2160, scale: 0.75) == 1620)
        #expect(WPEMetalFXSpatialUpscaler.scaledDimension(2234, scale: 0.75) == 1674)
        #expect(WPEMetalFXSpatialUpscaler.scaledDimension(100, scale: 0.25) == 64)
    }

    // MARK: - Eligibility (pure)

    @Test("contain/cover need an exactly equal aspect; center never qualifies")
    func eligibilityFitModeSemantics() {
        #expect(WPEMetalFXSpatialUpscaler.preScalerRejection(
            fitMode: .contain,
            sourceWidth: 2880, sourceHeight: 1620,
            drawableWidth: 3840, drawableHeight: 2160
        ) == nil)
        #expect(WPEMetalFXSpatialUpscaler.preScalerRejection(
            fitMode: .contain,
            sourceWidth: 3838, sourceHeight: 2160,
            drawableWidth: 3840, drawableHeight: 2160
        ) == .aspectMismatch)
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

    // MARK: - Production-path gates (assertions, not probes)

    /// The SDR combination the renderer actually ships. Unlike the probes
    /// below this one ASSERTS: a device that reports spatial-scaler support and
    /// then refuses the shipping format pair is a real regression, and the
    /// old probe-only coverage let exactly that pass green.
    @Test("The shipping SDR combo really creates a scaler on a supporting device")
    func shippingSDRComboCreatesScaler() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        guard MTLFXSpatialScalerDescriptor.supportsDevice(device) else {
            print("[metalfx] device reports no spatial-scaler support; nothing to gate")
            return
        }
        let descriptor = MTLFXSpatialScalerDescriptor()
        descriptor.inputWidth = 2880
        descriptor.inputHeight = 1620
        descriptor.outputWidth = 3840
        descriptor.outputHeight = 2160
        descriptor.colorTextureFormat = .rgba8Unorm_srgb
        descriptor.outputTextureFormat = .rgba8Unorm_srgb
        descriptor.colorProcessingMode = .perceptual
        #expect(
            descriptor.makeSpatialScaler(device: device) != nil,
            "supporting device refused the shipping SDR format pair"
        )
    }

    /// First coverage of the production entry point itself: the probes only
    /// exercised `MTLFXSpatialScaler` directly, never our eligibility gate,
    /// usage checks, alpha-fix pipeline or outcome counters.
    @Test("encodeIfEligible encodes an eligible frame and declines center")
    func encodeIfEligibleCoversProductionPath() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        guard MTLFXSpatialScalerDescriptor.supportsDevice(device) else { return }
        let library = try #require(device.makeDefaultLibrary())
        let queue = try #require(device.makeCommandQueue())

        let probeDescriptor = MTLFXSpatialScalerDescriptor()
        probeDescriptor.inputWidth = 2880
        probeDescriptor.inputHeight = 1620
        probeDescriptor.outputWidth = 3840
        probeDescriptor.outputHeight = 2160
        probeDescriptor.colorTextureFormat = .rgba8Unorm_srgb
        probeDescriptor.outputTextureFormat = .rgba8Unorm_srgb
        probeDescriptor.colorProcessingMode = .perceptual
        let probe = try #require(probeDescriptor.makeSpatialScaler(device: device))

        func makeTexture(_ width: Int, _ height: Int, usage: MTLTextureUsage) throws -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm_srgb, width: width, height: height, mipmapped: false
            )
            descriptor.storageMode = .private
            descriptor.usage = usage
            return try #require(device.makeTexture(descriptor: descriptor))
        }
        // The usage set production actually allocates for the scene output
        // (`makeOutputTexture`). Asserting the contract here is what keeps a
        // per-frame `usageMismatch` fallback from hiding behind test textures
        // that were built from the scaler's own requirement.
        #expect(
            MTLTextureUsage([.renderTarget, .shaderRead]).isSuperset(of: probe.colorTextureUsage),
            "scene-output usage no longer satisfies the scaler's input requirement"
        )
        let source = try makeTexture(2880, 1620, usage: probe.colorTextureUsage)
        // `.renderTarget` for the alpha-fix pass the scaler itself does not require.
        let output = try makeTexture(3840, 2160, usage: probe.outputTextureUsage.union(.renderTarget))

        let upscaler = WPEMetalFXSpatialUpscaler(device: device, library: library)
        let commandBuffer = try #require(queue.makeCommandBuffer())

        #expect(upscaler.encodeIfEligible(
            source: source, drawableTexture: output, fitMode: .stretch, commandBuffer: commandBuffer
        ))

        // center keeps source pixels 1:1, so a full-rect scale is never right.
        // The return value IS the contract — the caller runs the classic present
        // pass on false.
        #expect(upscaler.encodeIfEligible(
            source: source, drawableTexture: output, fitMode: .center, commandBuffer: commandBuffer
        ) == false)

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        #expect(commandBuffer.status == .completed, "\(String(describing: commandBuffer.error))")
    }

    // MARK: - Real-device probes (creation/encode must not crash; outcome is logged)

    @Test("Spatial scaler probe: production srgb combo 2880x1620 -> 3840x2160")
    func spatialScalerProbeProductionFormats() throws {
        try runScalerProbe(inputFormat: .rgba8Unorm_srgb, label: "rgba8Unorm_srgb")
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
