import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Metal
import simd
import Testing
@testable import LiveWallpaper

/// NV12 (biplanar YCbCr) video decode path: coefficient pins against the
/// published BT.601/709/2020 constants, colorimetry-attachment selection,
/// HDR→BGRA fallback, and a hermetic shader-vs-CPU numeric check on a
/// hand-built NV12 pixel buffer.
@MainActor
@Suite("WPEVideoTextureSource NV12", .serialized)
struct WPEVideoNV12ConversionTests {

    // MARK: - Matrix coefficient pins (CPU reference)

    @Test("BT.601 video-range coefficients match the published constants")
    func bt601VideoRangeCoefficients() {
        let c = WPEVideoYCbCrConversion.make(kind: .bt601, fullRange: false)
        // Columns: 0 = Y, 1 = Cb, 2 = Cr; rows R, G, B.
        #expect(abs(c.matrix.columns.0.x - 1.1644) < 0.001)
        #expect(abs(c.matrix.columns.0.y - 1.1644) < 0.001)
        #expect(abs(c.matrix.columns.0.z - 1.1644) < 0.001)
        #expect(abs(c.matrix.columns.2.x - 1.596) < 0.001)   // Cr → R
        #expect(abs(c.matrix.columns.1.y - -0.3918) < 0.001) // Cb → G
        #expect(abs(c.matrix.columns.2.y - -0.813) < 0.001)  // Cr → G
        #expect(abs(c.matrix.columns.1.z - 2.017) < 0.001)   // Cb → B
        #expect(c.matrix.columns.1.x == 0)                   // Cb → R
        #expect(c.matrix.columns.2.z == 0)                   // Cr → B
        #expect(abs(c.offset.x - 16.0 / 255.0) < 0.0001)
        #expect(abs(c.offset.y - 128.0 / 255.0) < 0.0001)
    }

    @Test("BT.709 video-range coefficients match the published constants")
    func bt709VideoRangeCoefficients() {
        let c = WPEVideoYCbCrConversion.make(kind: .bt709, fullRange: false)
        #expect(abs(c.matrix.columns.2.x - 1.7927) < 0.001)   // Cr → R
        #expect(abs(c.matrix.columns.1.y - -0.2132) < 0.001)  // Cb → G
        #expect(abs(c.matrix.columns.2.y - -0.5329) < 0.001)  // Cr → G
        #expect(abs(c.matrix.columns.1.z - 2.1124) < 0.001)   // Cb → B
    }

    @Test("BT.2020 and full-range variants")
    func bt2020AndFullRange() {
        let bt2020 = WPEVideoYCbCrConversion.make(kind: .bt2020, fullRange: false)
        // 2 * (1 - 0.2627) * 255/224
        #expect(abs(bt2020.matrix.columns.2.x - 1.6787) < 0.001)

        let full601 = WPEVideoYCbCrConversion.make(kind: .bt601, fullRange: true)
        #expect(full601.matrix.columns.0.x == 1.0)
        #expect(abs(full601.matrix.columns.2.x - 1.402) < 0.001) // Cr → R without range expansion
        #expect(full601.offset.x == 0)
        #expect(abs(full601.offset.y - 128.0 / 255.0) < 0.0001)
    }

    @Test("Video-range black and white map to 0 and 1")
    func videoRangeEndpoints() {
        let c = WPEVideoYCbCrConversion.make(kind: .bt709, fullRange: false)
        let black = c.apply(SIMD3(16.0 / 255.0, 128.0 / 255.0, 128.0 / 255.0))
        let white = c.apply(SIMD3(235.0 / 255.0, 128.0 / 255.0, 128.0 / 255.0))
        #expect(simd_length(black) < 0.005)
        #expect(simd_length(white - SIMD3<Float>(1, 1, 1)) < 0.005)
    }

    // MARK: - Colorimetry attachment selection

    @Test("Matrix kind follows the attachment, with an SD/HD heuristic fallback")
    func matrixKindSelection() {
        #expect(WPEVideoYCbCrConversion.kind(
            matrixAttachment: kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String, sourceHeight: 480
        ) == .bt709)
        #expect(WPEVideoYCbCrConversion.kind(
            matrixAttachment: kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String, sourceHeight: 2160
        ) == .bt601)
        #expect(WPEVideoYCbCrConversion.kind(
            matrixAttachment: kCVImageBufferYCbCrMatrix_ITU_R_2020 as String, sourceHeight: 2160
        ) == .bt2020)
        #expect(WPEVideoYCbCrConversion.kind(matrixAttachment: nil, sourceHeight: 480) == .bt601)
        #expect(WPEVideoYCbCrConversion.kind(matrixAttachment: nil, sourceHeight: 1080) == .bt709)
    }

    // MARK: - HDR detection

    @Test("PQ/HLG transfer functions are flagged HDR; SDR transfers are not")
    func hdrTransferDetection() throws {
        let pq = try Self.makeNV12PixelBuffer(width: 64, height: 64, luma: 128, cb: 128, cr: 128)
        CVBufferSetAttachment(
            pq, kCVImageBufferTransferFunctionKey,
            kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, .shouldPropagate
        )
        #expect(WPEVideoTextureSource.isHDRTransfer(pq))

        let hlg = try Self.makeNV12PixelBuffer(width: 64, height: 64, luma: 128, cb: 128, cr: 128)
        CVBufferSetAttachment(
            hlg, kCVImageBufferTransferFunctionKey,
            kCVImageBufferTransferFunction_ITU_R_2100_HLG, .shouldPropagate
        )
        #expect(WPEVideoTextureSource.isHDRTransfer(hlg))

        let sdr = try Self.makeNV12PixelBuffer(width: 64, height: 64, luma: 128, cb: 128, cr: 128)
        CVBufferSetAttachment(
            sdr, kCVImageBufferTransferFunctionKey,
            kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate
        )
        #expect(!WPEVideoTextureSource.isHDRTransfer(sdr))

        let untagged = try Self.makeNV12PixelBuffer(width: 64, height: 64, luma: 128, cb: 128, cr: 128)
        #expect(!WPEVideoTextureSource.isHDRTransfer(untagged))
    }

    // MARK: - Hermetic shader-vs-CPU numeric check

    @Test("NV12 ingest converts through the shader to the CPU reference values")
    func nv12IngestMatchesCPUReference() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let videoURL = try await SyntheticNV12VideoFixture.writeMP4(durationSeconds: 0.5)
        defer { try? FileManager.default.removeItem(at: videoURL) }
        let source = try WPEVideoTextureSource(device: device, videoURL: videoURL)
        defer { source.invalidate() }

        // Mid-range YCbCr with real chroma so a wrong matrix, offset, or
        // swapped Cb/Cr shows up as a large channel error.
        let (y, cb, cr): (UInt8, UInt8, UInt8) = (120, 90, 170)
        let buffer = try Self.makeNV12PixelBuffer(width: 64, height: 64, luma: y, cb: cb, cr: cr)
        CVBufferSetAttachment(
            buffer, kCVImageBufferYCbCrMatrixKey,
            kCVImageBufferYCbCrMatrix_ITU_R_601_4, .shouldPropagate
        )
        source.ingestForTesting(pixelBuffer: buffer)

        #expect(source.lastPublishPathForTesting == .biPlanar)
        let texture = try #require(source.texture(at: 0))
        #expect(texture.pixelFormat == .bgra8Unorm_srgb)
        #expect(texture.width == 64)
        #expect(texture.height == 64)

        let reference = WPEVideoYCbCrConversion.make(kind: .bt601, fullRange: false)
            .apply(SIMD3(Float(y) / 255.0, Float(cb) / 255.0, Float(cr) / 255.0))
        let expected = SIMD3<Int>(
            Int((reference.x * 255).rounded()),
            Int((reference.y * 255).rounded()),
            Int((reference.z * 255).rounded())
        )
        // The conversion pass runs on the source's own queue in tests — poll the
        // readback until the GPU pass lands.
        let matched = try await Self.pollReadbackBGRA(texture: texture, device: device) { bgra in
            abs(Int(bgra[2]) - expected.x) <= 2
                && abs(Int(bgra[1]) - expected.y) <= 2
                && abs(Int(bgra[0]) - expected.z) <= 2
                && bgra[3] == 255
        }
        #expect(matched, "shader output must match CPU reference \(expected) within ±2")
    }

    // MARK: - Explicit fallback branches

    @Test("HDR-tagged NV12 pins outputs to BGRA and never enters the matrix path")
    func hdrIngestPinsBGRAOutputs() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let videoURL = try await SyntheticNV12VideoFixture.writeMP4(durationSeconds: 0.5)
        defer { try? FileManager.default.removeItem(at: videoURL) }
        let source = try WPEVideoTextureSource(device: device, videoURL: videoURL)
        defer { source.invalidate() }

        let pq = try Self.makeNV12PixelBuffer(width: 64, height: 64, luma: 128, cb: 128, cr: 128)
        CVBufferSetAttachment(
            pq, kCVImageBufferTransferFunctionKey,
            kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, .shouldPropagate
        )
        source.ingestForTesting(pixelBuffer: pq)

        #expect(source.didForceBGRAOutputForTesting)
        #expect(source.lastPublishPathForTesting == nil, "HDR frame must not publish through the NV12 path")
        #expect(source.texture(at: 0) == nil)

        // After the fallback, BGRA buffers take the legacy wrap path unchanged.
        let bgra = try Self.makeBGRAPixelBuffer(width: 64, height: 64, fillByte: 90)
        source.ingestForTesting(pixelBuffer: bgra)
        #expect(source.lastPublishPathForTesting == .bgra)
        let texture = try #require(source.texture(at: 0))
        #expect(texture.pixelFormat == .bgra8Unorm_srgb || texture.pixelFormat == .bgra8Unorm)
    }

    // MARK: - AVFoundation integration (format negotiation)

    @Test("A playing SDR H.264 source negotiates the biplanar path end-to-end")
    func avPlayerDeliversBiPlanarFrames() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let videoURL = try await SyntheticNV12VideoFixture.writeMP4(durationSeconds: 1.0)
        defer { try? FileManager.default.removeItem(at: videoURL) }
        let source = try WPEVideoTextureSource(device: device, videoURL: videoURL)
        defer { source.invalidate() }
        source.applyPerformanceProfile(.quality)

        var texture: MTLTexture?
        let deadline = Date().addingTimeInterval(3.0)
        while Date() < deadline {
            texture = source.texture(at: 0)
            if texture != nil { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        let frame = try #require(texture, "AVPlayer-backed source must publish a frame within 3s")
        #expect(source.lastPublishPathForTesting == .biPlanar,
                "SDR H.264 must negotiate NV12, not fall back to BGRA")
        #expect(frame.pixelFormat == .bgra8Unorm_srgb)
        #expect(frame.width == 64)
        #expect(frame.height == 64)

        // The fixture is uniform gray per frame — conversion must keep it gray.
        source.applyPerformanceProfile(.suspended)
        let isGray = try await Self.pollReadbackBGRA(texture: frame, device: device) { bgra in
            let channels = [Int(bgra[0]), Int(bgra[1]), Int(bgra[2])]
            let spread = (channels.max() ?? 0) - (channels.min() ?? 0)
            return spread <= 12 && bgra[3] == 255 && channels[0] > 20 && channels[0] < 250
        }
        #expect(isGray, "uniform gray input must stay gray through the YCbCr matrix")
    }

    // MARK: - Wrapper lifetime (retirement fences)

    @Test("Replaced frames keep their CV wrappers until a GPU fence completes")
    func replacedFrameWrappersOutliveTheirPublish() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let videoURL = try await SyntheticNV12VideoFixture.writeMP4(durationSeconds: 0.5)
        defer { try? FileManager.default.removeItem(at: videoURL) }
        let source = try WPEVideoTextureSource(device: device, videoURL: videoURL)
        defer { source.invalidate() }

        let first = try Self.makeNV12PixelBuffer(width: 64, height: 64, luma: 100, cb: 110, cr: 140)
        source.ingestForTesting(pixelBuffer: first)
        let second = try Self.makeNV12PixelBuffer(width: 64, height: 64, luma: 180, cb: 120, cr: 130)
        source.ingestForTesting(pixelBuffer: second)

        // The first frame's wrappers moved into a pending retirement fenced by
        // the second publish's conversion buffer — they must not have been
        // dropped synchronously at replacement.
        #expect(source.pendingRetirementCountForTesting > 0,
                "replaced frame must be fence-retired, not released at publish")
    }

    @Test("Completed fences release retired wrappers on a later publish (no unbounded growth)")
    func sweepReleasesCompletedRetirements() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let videoURL = try await SyntheticNV12VideoFixture.writeMP4(durationSeconds: 0.5)
        defer { try? FileManager.default.removeItem(at: videoURL) }
        let source = try WPEVideoTextureSource(device: device, videoURL: videoURL)
        defer { source.invalidate() }

        // Publish a burst, then keep publishing slowly: once the GPU catches
        // up, each new publish sweeps the completed fences, so the pending
        // count must settle at 1 (only the entry appended by that publish).
        for step in 0..<6 {
            let buffer = try Self.makeNV12PixelBuffer(
                width: 64, height: 64, luma: UInt8(60 + step * 20), cb: 100, cr: 150
            )
            source.ingestForTesting(pixelBuffer: buffer)
        }
        var settled = false
        let deadline = Date().addingTimeInterval(3.0)
        while Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
            let buffer = try Self.makeNV12PixelBuffer(width: 64, height: 64, luma: 90, cb: 100, cr: 150)
            source.ingestForTesting(pixelBuffer: buffer)
            if source.pendingRetirementCountForTesting == 1 {
                settled = true
                break
            }
        }
        #expect(settled, "completed retirements must be swept — pending stuck at \(source.pendingRetirementCountForTesting)")
    }

    @Test("Invalidate fences the still-published frame, not just replaced ones")
    func invalidateFencesTheCurrentFrame() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let videoURL = try await SyntheticNV12VideoFixture.writeMP4(durationSeconds: 0.5)
        defer { try? FileManager.default.removeItem(at: videoURL) }
        let source = try WPEVideoTextureSource(device: device, videoURL: videoURL)

        // One publish only: nothing has been replaced, so `pendingRetirements`
        // is the empty case the drain used to walk right past — the published
        // frame's wrappers were released with no fence at all.
        let only = try Self.makeNV12PixelBuffer(width: 64, height: 64, luma: 120, cb: 110, cr: 140)
        source.ingestForTesting(pixelBuffer: only)
        let fencesAfterPublish = source.retirementFencesCreatedForTesting

        source.invalidate()
        #expect(
            source.retirementFencesCreatedForTesting > fencesAfterPublish,
            "invalidate released the published frame without fencing it"
        )
        #expect(source.pendingRetirementCountForTesting == 0,
                "every fence must be waited out before teardown")
    }

    @Test("Suspending playback releases retired wrappers instead of holding a frame")
    func suspendReleasesRetiredWrappers() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let videoURL = try await SyntheticNV12VideoFixture.writeMP4(durationSeconds: 0.5)
        defer { try? FileManager.default.removeItem(at: videoURL) }
        let source = try WPEVideoTextureSource(device: device, videoURL: videoURL)
        defer { source.invalidate() }

        let first = try Self.makeNV12PixelBuffer(width: 64, height: 64, luma: 100, cb: 110, cr: 140)
        source.ingestForTesting(pixelBuffer: first)
        let second = try Self.makeNV12PixelBuffer(width: 64, height: 64, luma: 180, cb: 120, cr: 130)
        source.ingestForTesting(pixelBuffer: second)
        #expect(source.pendingRetirementCountForTesting > 0)

        // Pausing stops publishes, so the sweep at the top of `publish` will
        // never run again — a retired 4K NV12 plane pair (~12 MiB, ~32 MiB on
        // BGRA) would sit there for the whole suspension.
        source.applyPerformanceProfile(.suspended)
        #expect(source.pendingRetirementCountForTesting == 0,
                "suspend must drain fenced retirements, not hold a frame for the whole pause")
    }

    @Test("Invalidate with conversion work in flight: no crash, full teardown")
    func invalidateWithInFlightConversions() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let videoURL = try await SyntheticNV12VideoFixture.writeMP4(durationSeconds: 0.5)
        defer { try? FileManager.default.removeItem(at: videoURL) }
        let source = try WPEVideoTextureSource(device: device, videoURL: videoURL)

        // Burst of publishes so conversion command buffers are still in flight
        // when invalidate() lands — the earlier hardening attempt crashed in
        // exactly this window (completed handler vs. pool teardown).
        for step in 0..<12 {
            let buffer = try Self.makeNV12PixelBuffer(
                width: 256, height: 256, luma: UInt8(40 + step * 15), cb: 90, cr: 160
            )
            source.ingestForTesting(pixelBuffer: buffer)
        }
        #expect(source.pendingRetirementCountForTesting > 0)

        source.invalidate()

        #expect(source.pendingRetirementCountForTesting == 0,
                "invalidate must drain and release every pending retirement")
        #expect(source.texture(at: 0) == nil)
        // Idempotent re-entry stays safe after the drain.
        source.invalidate()
    }

    // MARK: - Helpers

    /// Polls a 1-pixel (0,0) readback until `predicate` passes or 2s elapse.
    private static func pollReadbackBGRA(
        texture: MTLTexture,
        device: MTLDevice,
        predicate: ([UInt8]) -> Bool
    ) async throws -> Bool {
        let queue = try #require(device.makeCommandQueue())
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            let bgra = try readbackPixel(texture: texture, queue: queue)
            if predicate(bgra) { return true }
            try await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    private static func readbackPixel(texture: MTLTexture, queue: MTLCommandQueue) throws -> [UInt8] {
        let buffer = try #require(queue.device.makeBuffer(length: 4, options: .storageModeShared))
        let commandBuffer = try #require(queue.makeCommandBuffer())
        let blit = try #require(commandBuffer.makeBlitCommandEncoder())
        blit.copy(
            from: texture, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: 1, height: 1, depth: 1),
            to: buffer, destinationOffset: 0,
            destinationBytesPerRow: 4, destinationBytesPerImage: 4
        )
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        let pointer = buffer.contents().bindMemory(to: UInt8.self, capacity: 4)
        return [pointer[0], pointer[1], pointer[2], pointer[3]]
    }

    private static func makeNV12PixelBuffer(
        width: Int, height: Int, luma: UInt8, cb: UInt8, cr: UInt8
    ) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes: CFDictionary = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ] as CFDictionary
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            attributes, &pixelBuffer
        )
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            throw FixtureError.pixelBufferCreateFailed(status)
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let lumaBase = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 0))
        let lumaRowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        for row in 0..<height {
            memset(lumaBase + row * lumaRowBytes, Int32(luma), width)
        }
        let chromaBase = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 1))
            .bindMemory(to: UInt8.self, capacity: CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) * (height / 2))
        let chromaRowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        for row in 0..<(height / 2) {
            for column in 0..<(width / 2) {
                chromaBase[row * chromaRowBytes + column * 2] = cb
                chromaBase[row * chromaRowBytes + column * 2 + 1] = cr
            }
        }
        return buffer
    }

    private static func makeBGRAPixelBuffer(width: Int, height: Int, fillByte: UInt8) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes: CFDictionary = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ] as CFDictionary
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes, &pixelBuffer
        )
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            throw FixtureError.pixelBufferCreateFailed(status)
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = try #require(CVPixelBufferGetBaseAddress(buffer))
        memset(base, Int32(fillByte), CVPixelBufferGetBytesPerRow(buffer) * height)
        return buffer
    }

    private enum FixtureError: Error {
        case pixelBufferCreateFailed(CVReturn)
    }
}

// MARK: - Synthetic MP4 fixture (uniform gray frames)

private enum SyntheticNV12VideoFixture {
    static func writeMP4(durationSeconds: TimeInterval) async throws -> URL {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wpe-nv12-\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let width = 64
        let height = 64
        let frameRate: Int32 = 24
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
        )
        guard writer.canAdd(input) else { throw WriterError.setupFailed("cannot add input") }
        writer.add(input)
        guard writer.startWriting() else {
            throw WriterError.setupFailed(writer.error?.localizedDescription ?? "startWriting failed")
        }
        writer.startSession(atSourceTime: .zero)
        let totalFrames = max(2, Int(Double(frameRate) * durationSeconds))
        for index in 0..<totalFrames {
            while !input.isReadyForMoreMediaData { await Task.yield() }
            var pixelBuffer: CVPixelBuffer?
            let status = CVPixelBufferCreate(
                kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &pixelBuffer
            )
            guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
                throw WriterError.setupFailed("CVPixelBufferCreate returned \(status)")
            }
            CVPixelBufferLockBaseAddress(buffer, [])
            let base = CVPixelBufferGetBaseAddress(buffer)
            memset(base, Int32(60 + (index * 5) % 160), CVPixelBufferGetBytesPerRow(buffer) * height)
            CVPixelBufferUnlockBaseAddress(buffer, [])
            let pts = CMTime(value: Int64(index), timescale: frameRate)
            guard adaptor.append(buffer, withPresentationTime: pts) else {
                throw WriterError.setupFailed(writer.error?.localizedDescription ?? "append failed")
            }
        }
        input.markAsFinished()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else {
            throw WriterError.setupFailed(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")
        }
        return outputURL
    }

    private enum WriterError: Error {
        case setupFailed(String)
    }
}
