import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Metal
import Testing
import VideoToolbox
@testable import LiveWallpaper

/// End-to-end coverage for two branches the hermetic NV12 tests cannot reach:
/// the HDR (PQ) fallback driven by a real 10-bit HEVC clip, and the
/// pre-macOS-15 item-level (`AVPlayerItemVideoOutput`) frame path.
@MainActor
@Suite("WPEVideoTextureSource HDR and legacy output", .serialized)
struct WPEVideoHDRAndLegacyOutputTests {

    // MARK: - Task: real HDR (PQ) end-to-end

    @Test("A real 10-bit HEVC PQ clip pins outputs to BGRA exactly once and keeps publishing")
    func hdrPQClipTakesBGRAFallbackEndToEnd() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let videoURL = try await SyntheticHDRVideoFixture.writeHEVCMain10(transfer: .pq)
        defer { try? FileManager.default.removeItem(at: videoURL) }

        // Fixture sanity: the container must genuinely carry HEVC + PQ tags,
        // otherwise the assertions below prove nothing.
        let asset = AVURLAsset(url: videoURL)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let formatDescription = try #require(try await track.load(.formatDescriptions).first)
        #expect(CMFormatDescriptionGetMediaSubType(formatDescription) == kCMVideoCodecType_HEVC)
        let transfer = CMFormatDescriptionGetExtension(
            formatDescription, extensionKey: kCMFormatDescriptionExtension_TransferFunction
        ) as? String
        #expect(transfer == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String),
                "fixture must be PQ-tagged, got \(transfer ?? "nil")")

        let source = try WPEVideoTextureSource(device: device, videoURL: videoURL)
        defer { source.invalidate() }
        source.applyPerformanceProfile(.quality)

        var texture: MTLTexture?
        var sawBiPlanarPublish = false
        let deadline = Date().addingTimeInterval(8.0)
        while Date() < deadline {
            texture = source.texture(at: 0)
            if source.lastPublishPathForTesting == .biPlanar { sawBiPlanarPublish = true }
            if texture != nil { break }
            try await Task.sleep(for: .milliseconds(30))
        }

        // (a) HDR detection fired and the outputs rebuilt to BGRA exactly once.
        #expect(source.didForceBGRAOutputForTesting, "PQ clip must trigger the HDR fallback")
        #expect(source.bgraFallbackRebuildCountForTesting == 1,
                "outputs must rebuild exactly once, got \(source.bgraFallbackRebuildCountForTesting)")
        // (b) Frames still publish after the rebuild.
        let frame = try #require(texture, "HDR clip must still publish frames after the BGRA rebuild")
        #expect(frame.width == 64)
        #expect(frame.height == 64)
        #expect(frame.pixelFormat == .bgra8Unorm_srgb || frame.pixelFormat == .bgra8Unorm)
        // (c) No NV12 conversion was ever attempted on the HDR clip.
        #expect(!sawBiPlanarPublish, "PQ frames must never take the NV12 matrix path")
        #expect(source.lastPublishPathForTesting == .bgra)
    }

    // MARK: - Task: legacy item-level output path

    @Test("Forced item-level output (macOS 14 path) publishes frames from an SDR clip")
    func legacyItemLevelOutputPublishesFrames() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let videoURL = try await SyntheticHDRVideoFixture.writeSDRH264()
        defer { try? FileManager.default.removeItem(at: videoURL) }

        let source = try WPEVideoTextureSource(
            device: device,
            videoURL: videoURL,
            forceLegacyItemLevelOutputForTesting: true
        )
        defer { source.invalidate() }
        source.applyPerformanceProfile(.quality)

        var texture: MTLTexture?
        let deadline = Date().addingTimeInterval(5.0)
        while Date() < deadline {
            texture = source.texture(at: 0)
            if texture != nil { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        let frame = try #require(texture, "item-level output must publish a frame within 5s")
        #expect(frame.width == 64)
        #expect(frame.height == 64)
        #expect(frame.pixelFormat == .bgra8Unorm_srgb || frame.pixelFormat == .bgra8Unorm)
        let path = try #require(source.lastPublishPathForTesting)
        #expect(path == .biPlanar || path == .bgra)
    }
}

// MARK: - Fixtures

private enum SyntheticHDRVideoFixture {
    enum Transfer {
        case pq
        case hlg
    }

    /// 64x64, 10 frames, HEVC Main10 from P010-style
    /// (`kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange`) source buffers with
    /// BT.2020 primaries/matrix and the requested transfer function.
    static func writeHEVCMain10(transfer: Transfer) async throws -> URL {
        let transferFunction: (video: String, cv: CFString)
        switch transfer {
        case .pq:
            transferFunction = (
                AVVideoTransferFunction_SMPTE_ST_2084_PQ,
                kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
            )
        case .hlg:
            transferFunction = (
                AVVideoTransferFunction_ITU_R_2100_HLG,
                kCVImageBufferTransferFunction_ITU_R_2100_HLG
            )
        }
        let width = 64
        let height = 64
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                kVTCompressionPropertyKey_ProfileLevel as String: kVTProfileLevel_HEVC_Main10_AutoLevel
            ],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: transferFunction.video,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020
            ]
        ]
        return try await write(
            videoSettings: videoSettings,
            sourcePixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            frameCount: 10
        ) { buffer, frameIndex in
            CVBufferSetAttachment(
                buffer, kCVImageBufferColorPrimariesKey,
                kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate
            )
            CVBufferSetAttachment(
                buffer, kCVImageBufferTransferFunctionKey,
                transferFunction.cv, .shouldPropagate
            )
            CVBufferSetAttachment(
                buffer, kCVImageBufferYCbCrMatrixKey,
                kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate
            )
            // 10-bit biplanar: samples are left-justified in 16-bit words.
            let luma10 = UInt16(200 + frameIndex * 40) << 6
            let chroma10 = UInt16(512) << 6
            CVPixelBufferLockBaseAddress(buffer, [])
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
            if let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) {
                let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
                for row in 0..<CVPixelBufferGetHeightOfPlane(buffer, 0) {
                    let rowPointer = (base + row * rowBytes).bindMemory(to: UInt16.self, capacity: width)
                    for column in 0..<width { rowPointer[column] = luma10 }
                }
            }
            if let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) {
                let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
                for row in 0..<CVPixelBufferGetHeightOfPlane(buffer, 1) {
                    let rowPointer = (base + row * rowBytes).bindMemory(to: UInt16.self, capacity: width)
                    for column in 0..<width { rowPointer[column] = chroma10 }
                }
            }
        }
    }

    /// Plain 64x64 SDR H.264 clip (BGRA source frames) for the legacy path.
    static func writeSDRH264() async throws -> URL {
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 64,
            AVVideoHeightKey: 64
        ]
        return try await write(
            videoSettings: videoSettings,
            sourcePixelFormat: kCVPixelFormatType_32BGRA,
            frameCount: 24
        ) { buffer, frameIndex in
            CVPixelBufferLockBaseAddress(buffer, [])
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                memset(base, Int32(60 + (frameIndex * 5) % 160),
                       CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer))
            }
        }
    }

    private static func write(
        videoSettings: [String: Any],
        sourcePixelFormat: OSType,
        frameCount: Int,
        fill: (CVPixelBuffer, Int) -> Void
    ) async throws -> URL {
        let width = videoSettings[AVVideoWidthKey] as? Int ?? 64
        let height = videoSettings[AVVideoHeightKey] as? Int ?? 64
        let frameRate: Int32 = 24
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wpe-hdr-fixture-\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: sourcePixelFormat,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
        )
        guard writer.canAdd(input) else {
            throw FixtureError.writerFailed("cannot add input for settings \(videoSettings)")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw FixtureError.writerFailed(writer.error.map { "\($0)" } ?? "startWriting failed")
        }
        writer.startSession(atSourceTime: .zero)
        for index in 0..<frameCount {
            while !input.isReadyForMoreMediaData { await Task.yield() }
            var pixelBuffer: CVPixelBuffer?
            var status = kCVReturnError
            if let pool = adaptor.pixelBufferPool {
                status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
            }
            if status != kCVReturnSuccess {
                status = CVPixelBufferCreate(
                    kCFAllocatorDefault, width, height, sourcePixelFormat, nil, &pixelBuffer
                )
            }
            guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
                throw FixtureError.writerFailed("pixel buffer create returned \(status)")
            }
            fill(buffer, index)
            let pts = CMTime(value: Int64(index), timescale: frameRate)
            guard adaptor.append(buffer, withPresentationTime: pts) else {
                throw FixtureError.writerFailed(writer.error.map { "\($0)" } ?? "append failed at frame \(index)")
            }
        }
        input.markAsFinished()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else {
            throw FixtureError.writerFailed(
                writer.error.map { "\($0)" } ?? "finishWriting status \(writer.status.rawValue)"
            )
        }
        return outputURL
    }

    private enum FixtureError: Error, CustomStringConvertible {
        case writerFailed(String)

        var description: String {
            switch self {
            case let .writerFailed(message): return "AVAssetWriter fixture failed: \(message)"
            }
        }
    }
}
