import CoreMedia
import CoreVideo
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import simd
import Testing

/// A frame whose sRGB decode cannot be set up is refused and the last frame stays published;
/// republishing it through a plain unorm format would sample gamma bytes as linear.
@MainActor
@Suite("WPE video sRGB fallback refusal", .serialized)
struct WPEVideoSRGBFallbackRefusalTests {
    @Test("A failed sRGB BGRA wrap keeps the last frame instead of publishing a unorm wrap")
    func failedSRGBWrapKeepsTheLastFrame() throws {
        let harness = try Harness.make()
        defer { harness.tearDown() }

        // Nothing published yet: a refused first frame leaves the source empty.
        harness.source.forceSRGBWrapFailureForTesting = true
        try harness.source.ingestForTesting(pixelBuffer: Harness.bgra(fill: 128))
        #expect(harness.source.srgbWrapFailuresForTesting == 1)
        #expect(harness.source.texture(at: 0) == nil, "a refused first frame was published")

        harness.source.forceSRGBWrapFailureForTesting = false
        try harness.source.ingestForTesting(pixelBuffer: Harness.bgra(fill: 128))
        let baseline = try #require(harness.source.texture(at: 0))
        #expect(baseline.pixelFormat == .bgra8Unorm_srgb)

        harness.source.forceSRGBWrapFailureForTesting = true
        try harness.source.ingestForTesting(pixelBuffer: Harness.bgra(fill: 200))
        #expect(harness.source.srgbWrapFailuresForTesting == 2)
        #expect(!harness.source.hasStagedFrameWork, "a refused frame stayed staged")
        let current = try #require(harness.source.texture(at: 0))
        #expect(current === baseline, "the refused frame replaced the last frame")
        #expect(current.pixelFormat == .bgra8Unorm_srgb, "a non-sRGB wrap was published: \(current.pixelFormat)")

        // Nothing is latched: the next frame that wraps publishes normally.
        harness.source.forceSRGBWrapFailureForTesting = false
        try harness.source.ingestForTesting(pixelBuffer: Harness.bgra(fill: 200))
        let recovered = try #require(harness.source.texture(at: 0))
        #expect(recovered !== baseline)
        #expect(recovered.pixelFormat == .bgra8Unorm_srgb)
        #expect(harness.source.srgbWrapFailuresForTesting == 2)
    }

    @Test("A failed sRGB view of the working texture keeps the last frame instead of the unorm target")
    func failedSampleViewKeepsTheLastFrame() throws {
        let harness = try Harness.make()
        defer { harness.tearDown() }

        try harness.source.ingestForTesting(pixelBuffer: Harness.nv12(luma: 100, cb: 110, cr: 140))
        let baseline = try #require(harness.source.texture(at: 0))
        #expect(baseline.pixelFormat == .bgra8Unorm_srgb)
        #expect(harness.source.sampleViewFailuresForTesting == 0)

        // A new size allocates a new working texture, which is where the view is made.
        harness.source.forceSampleViewFailureForTesting = true
        try harness.source.ingestForTesting(pixelBuffer: Harness.nv12(luma: 200, cb: 90, cr: 160, size: 128))
        #expect(harness.source.sampleViewFailuresForTesting == 1)
        #expect(!harness.source.hasStagedFrameWork, "a refused frame stayed staged")
        let current = try #require(harness.source.texture(at: 0))
        #expect(current === baseline, "the refused frame replaced the last frame")
        #expect(current.pixelFormat == .bgra8Unorm_srgb, "the raw unorm target was handed out: \(current.pixelFormat)")

        // The half-built texture must not be cached: the next frame retries and publishes.
        harness.source.forceSampleViewFailureForTesting = false
        try harness.source.ingestForTesting(pixelBuffer: Harness.nv12(luma: 200, cb: 90, cr: 160, size: 128))
        let recovered = try #require(harness.source.texture(at: 0))
        #expect(recovered !== baseline)
        #expect(recovered.width == 128)
        #expect(recovered.pixelFormat == .bgra8Unorm_srgb)
        #expect(harness.source.sampleViewFailuresForTesting == 1)
    }

    @Test("A working texture whose clear never committed is neither handed out nor counted")
    func failedClearIsNotPublished() throws {
        let harness = try Harness.make()
        defer { harness.tearDown() }

        try harness.source.ingestForTesting(pixelBuffer: Harness.nv12(luma: 100, cb: 110, cr: 140))
        let baseline = try #require(harness.source.texture(at: 0))
        #expect(harness.source.workingTextureClearsForTesting == 1)

        harness.source.forceWorkingTextureClearFailureForTesting = true
        try harness.source.ingestForTesting(pixelBuffer: Harness.nv12(luma: 200, cb: 90, cr: 160, size: 128))
        #expect(harness.source.workingTextureClearsForTesting == 1, "a clear that never committed was counted")
        #expect(!harness.source.hasStagedFrameWork, "a refused frame stayed staged")
        let current = try #require(harness.source.texture(at: 0))
        #expect(current === baseline, "an uncleared working texture was handed out")
        #expect(current.width == 64)

        harness.source.forceWorkingTextureClearFailureForTesting = false
        try harness.source.ingestForTesting(pixelBuffer: Harness.nv12(luma: 200, cb: 90, cr: 160, size: 128))
        let recovered = try #require(harness.source.texture(at: 0))
        #expect(recovered !== baseline)
        #expect(recovered.width == 128)
        #expect(harness.source.workingTextureClearsForTesting == 2)
    }

    /// Control for the refusals above: on the success path the sampler decodes sRGB, so byte 128
    /// reads back as ~0.214 linear. A fallback that sampled the raw unorm bytes would read 0.5 here.
    @Test("Control: mid-gray bytes decode to linear through the sRGB wrap and the NV12 sample view")
    func successPathDecodesMidGrayToLinear() throws {
        let harness = try Harness.make()
        defer { harness.tearDown() }

        try harness.source.ingestForTesting(pixelBuffer: Harness.bgra(fill: 128))
        let wrapped = try #require(harness.source.texture(at: 0))
        let wrappedLinear = try harness.sampleRed(wrapped)
        #expect(abs(wrappedLinear - 0.214) < 0.01, "sRGB wrap decoded 128/255 to \(wrappedLinear), not ~0.214")

        // Video-range Y=128 leaves the BT.601 matrix as R'G'B' ≈ 0.511; the view decodes that.
        try harness.source.ingestForTesting(pixelBuffer: Harness.nv12(luma: 128, cb: 128, cr: 128))
        let converted = try #require(harness.source.texture(at: 0))
        let encoded = WPEVideoYCbCrConversion.make(kind: .bt601, fullRange: false)
            .apply(SIMD3(repeating: 128.0 / 255.0)).x
        let expected = Harness.srgbToLinear(encoded)
        let convertedLinear = try harness.sampleRed(converted)
        #expect(abs(convertedLinear - expected) < 0.01,
                "NV12 sample view decoded to \(convertedLinear), expected ~\(expected) (encoded \(encoded))")
    }

    // MARK: - Harness

    /// Zero-ticket admission plus an empty file keep `init` on the still-frame branch: nothing publishes until a test ingests.
    private struct Harness {
        let device: MTLDevice
        let queue: MTLCommandQueue
        let source: WPEVideoTextureSource
        let fileURL: URL

        static func make() throws -> Harness {
            let device = try #require(MTLCreateSystemDefaultDevice())
            let queue = try #require(device.makeCommandQueue())
            let fileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("wpe-srgb-refusal-\(UUID().uuidString).mp4")
            try Data().write(to: fileURL)
            let source = try WPEVideoTextureSource(
                device: device,
                videoURL: fileURL,
                commandQueue: queue,
                decoderAdmission: WPEVideoDecoderAdmission(limit: 0)
            )
            #expect(!source.isLiveDecoder, "harness must not spin up an AVPlayer")
            return Harness(device: device, queue: queue, source: source, fileURL: fileURL)
        }

        func tearDown() {
            source.invalidate()
            try? FileManager.default.removeItem(at: fileURL)
        }

        /// Red channel of `texture` as the renderer's own copy fragment samples it, into a float target.
        /// Runs on the source's queue, so it is ordered behind every conversion committed there.
        func sampleRed(_ texture: MTLTexture) throws -> Float {
            let library = try #require(device.makeDefaultLibrary())
            let pipelineDescriptor = MTLRenderPipelineDescriptor()
            pipelineDescriptor.vertexFunction = try #require(library.makeFunction(name: "wpe_fullscreen_vertex"))
            pipelineDescriptor.fragmentFunction = try #require(library.makeFunction(name: "wpe_copy_fragment"))
            pipelineDescriptor.colorAttachments[0].pixelFormat = .rgba32Float
            let pipeline = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)

            let targetDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba32Float, width: 4, height: 4, mipmapped: false
            )
            targetDescriptor.usage = [.renderTarget]
            targetDescriptor.storageMode = .private
            let target = try #require(device.makeTexture(descriptor: targetDescriptor))
            let readback = try #require(device.makeBuffer(length: 16, options: .storageModeShared))

            let commandBuffer = try #require(queue.makeCommandBuffer())
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            let encoder = try #require(commandBuffer.makeRenderCommandEncoder(descriptor: pass))
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()
            let blit = try #require(commandBuffer.makeBlitCommandEncoder())
            blit.copy(
                from: target, sourceSlice: 0, sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 1, y: 1, z: 0),
                sourceSize: MTLSize(width: 1, height: 1, depth: 1),
                to: readback, destinationOffset: 0,
                destinationBytesPerRow: 16, destinationBytesPerImage: 16
            )
            blit.endEncoding()
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            return readback.contents().bindMemory(to: Float.self, capacity: 4)[0]
        }

        static func srgbToLinear(_ value: Float) -> Float {
            value <= 0.04045 ? value / 12.92 : powf((value + 0.055) / 1.055, 2.4)
        }

        static func bgra(fill: UInt8, size: Int = 64) throws -> CVPixelBuffer {
            var pixelBuffer: CVPixelBuffer?
            let attributes: CFDictionary = [
                kCVPixelBufferMetalCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ] as CFDictionary
            let status = CVPixelBufferCreate(
                kCFAllocatorDefault, size, size, kCVPixelFormatType_32BGRA, attributes, &pixelBuffer
            )
            guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
                throw HarnessError.pixelBufferCreateFailed(status)
            }
            CVPixelBufferLockBaseAddress(buffer, [])
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
            let base = try #require(CVPixelBufferGetBaseAddress(buffer))
            memset(base, Int32(fill), CVPixelBufferGetBytesPerRow(buffer) * size)
            return buffer
        }

        static func nv12(luma: UInt8, cb: UInt8, cr: UInt8, size: Int = 64) throws -> CVPixelBuffer {
            var pixelBuffer: CVPixelBuffer?
            let attributes: CFDictionary = [
                kCVPixelBufferMetalCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ] as CFDictionary
            let status = CVPixelBufferCreate(
                kCFAllocatorDefault, size, size,
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                attributes, &pixelBuffer
            )
            guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
                throw HarnessError.pixelBufferCreateFailed(status)
            }
            CVPixelBufferLockBaseAddress(buffer, [])
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
            let lumaBase = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 0))
            let lumaRowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            for row in 0 ..< size {
                memset(lumaBase + row * lumaRowBytes, Int32(luma), size)
            }
            let chromaRowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
            let chromaBase = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 1))
                .bindMemory(to: UInt8.self, capacity: chromaRowBytes * (size / 2))
            for row in 0 ..< (size / 2) {
                for column in 0 ..< (size / 2) {
                    chromaBase[row * chromaRowBytes + column * 2] = cb
                    chromaBase[row * chromaRowBytes + column * 2 + 1] = cr
                }
            }
            return buffer
        }
    }

    private enum HarnessError: Error {
        case pixelBufferCreateFailed(CVReturn)
    }
}

extension WPEVideoSRGBFallbackRefusalTests {
    @Test("Failed player-level publication retries the same PTS and only success deduplicates it")
    func failedPlayerFrameRetriesSamePTS() throws {
        let harness = try Harness.make()
        defer { harness.tearDown() }
        let frame = try Harness.bgra(fill: 128)
        let pts = CMTime(value: 1, timescale: 30)
        harness.source.forceSRGBWrapFailureForTesting = true
        harness.source.ingestPlayerLevelFrameForTesting(pixelBuffer: frame, presentationTime: pts)
        #expect(harness.source.lastPlayerPresentationTimeForTesting == nil)
        #expect(!harness.source.hasStagedFrameWork)
        harness.source.forceSRGBWrapFailureForTesting = false
        harness.source.ingestPlayerLevelFrameForTesting(pixelBuffer: frame, presentationTime: pts)
        #expect(harness.source.lastPlayerPresentationTimeForTesting == pts)
        #expect(harness.source.hasStagedFrameWork)
        #expect(harness.source.driveStagedFrameWorkForTesting())
        let count = harness.source.publishedFrameCountForTesting
        harness.source.ingestPlayerLevelFrameForTesting(pixelBuffer: frame, presentationTime: pts)
        #expect(harness.source.publishedFrameCountForTesting == count)
    }

    @Test("HDR fallback does not consume the old output PTS and accepts its BGRA replacement")
    func fallbackRetriesReplacementAtSamePTS() throws {
        let harness = try Harness.make()
        defer { harness.tearDown() }
        let pts = CMTime(value: 2, timescale: 30)
        let hdr = try Harness.nv12(luma: 128, cb: 128, cr: 128)
        CVBufferSetAttachment(hdr, kCVImageBufferTransferFunctionKey,
                              kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, .shouldPropagate)
        harness.source.ingestPlayerLevelFrameForTesting(pixelBuffer: hdr, presentationTime: pts)
        #expect(harness.source.didForceBGRAOutputForTesting)
        #expect(harness.source.lastPlayerPresentationTimeForTesting == nil)
        #expect(!harness.source.hasStagedFrameWork)
        try harness.source.ingestPlayerLevelFrameForTesting(pixelBuffer: Harness.bgra(fill: 128), presentationTime: pts)
        #expect(harness.source.lastPlayerPresentationTimeForTesting == pts)
        #expect(harness.source.driveStagedFrameWorkForTesting())
    }

    @Test("A failed resized conversion aborts the scene and retries without publishing clear black", arguments: [false, true])
    func conversionFailureAbortsSceneAndRetries(bgraBaseline: Bool) throws {
        let harness = try Harness.make()
        defer { harness.tearDown() }
        let executor = try WPEMetalRenderExecutor(device: harness.device)
        let initial = try bgraBaseline ? Harness.bgra(fill: 128) : Harness.nv12(luma: 100, cb: 128, cr: 128)
        harness.source.ingestForTesting(pixelBuffer: initial)
        let previous = try #require(harness.source.publishedTextureForTesting)
        _ = try harness.sampleRed(previous) // fence the harness queue before the executor queue reads it
        let pass = WPERenderPass(id: "video.0", phase: .material, shader: "commands/copy",
                                 source: .image("video"), target: .scene, textures: [0: .image("video")], binds: [:],
                                 constants: [:], combos: [:], blending: "disabled", cullMode: "nocull", depthTest: "disabled", depthWrite: "disabled")
        let prepared = WPEPreparedRenderPass(pass: pass,
                                             shader: WPEShaderProgram(name: pass.shader, vertexSource: "", fragmentSource: "", isBuiltin: true),
                                             textureBindings: [0: .image("video")], comboValues: [:], uniformValues: [:])
        let graph = WPERenderLayer(objectID: "video", objectName: "Video", imagePath: "video", materialPath: nil,
                                   geometry: .identity, compositeA: "a", compositeB: "b", localFBOs: [], passes: [pass])
        let pipeline = WPEPreparedRenderPipeline(layers: [.init(graphLayer: graph, passes: [prepared])])
        let baseline = try executor.render(pipeline: pipeline, size: CGSize(width: 2, height: 2), textures: ["video": previous])
        let baselineRed = try harness.sampleRed(baseline)
        try harness.source.ingestForTesting(pixelBuffer: Harness.nv12(luma: 200, cb: 128, cr: 128, size: 128), drivesFrame: false)
        let staged = try #require(harness.source.texture(at: 0))
        #expect(staged !== previous)
        let fence = try #require(harness.queue.makeCommandBuffer())
        fence.commit(); fence.waitUntilCompleted() // allocation clear only; no conversion
        let retirements = harness.source.retirementFencesCreatedForTesting
        harness.source.forceConversionEncoderFailureForTesting = true
        executor.stageTextureWork([harness.source])
        #expect(throws: WPEMetalRenderExecutorError.commandBufferFailed) {
            try executor.render(pipeline: pipeline, size: CGSize(width: 2, height: 2), textures: ["video": staged])
        }
        #expect(harness.source.publishedTextureForTesting === previous)
        #expect(harness.source.hasStagedFrameWork)
        #expect(harness.source.retirementFencesCreatedForTesting == retirements)
        #expect(try harness.sampleRed(baseline) == baselineRed)
        harness.source.forceConversionEncoderFailureForTesting = false
        executor.stageTextureWork([harness.source])
        let recovered = try executor.render(pipeline: pipeline, size: CGSize(width: 2, height: 2), textures: ["video": staged])
        #expect(!harness.source.hasStagedFrameWork)
        #expect(harness.source.publishedTextureForTesting === staged)
        #expect(harness.source.retirementFencesCreatedForTesting == retirements + 1)
        #expect(try harness.sampleRed(recovered) > baselineRed + 0.1)
    }
}
