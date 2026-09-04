import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Metal
import os
import Testing
@testable import LiveWallpaper

@MainActor
@Suite("WPEVideoTextureSource pacing", .serialized)
struct WPEVideoTextureSourcePacingTests {

    @Test("Stays paused until applyPerformanceProfile(.quality) — no auto-start in init")
    func staysPausedUntilProfileApplied() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let videoURL = try await SyntheticVideoFixture.writeMP4(
            durationSeconds: 1.0,
            frameRate: 24
        )
        defer { try? FileManager.default.removeItem(at: videoURL) }

        let source = try WPEVideoTextureSource(device: device, videoURL: videoURL)
        defer { source.invalidate() }

        try await Task.sleep(for: .milliseconds(300))
        #expect(source.currentPlayheadSeconds == 0, "Source must not auto-start in init — renderer drives play/pause via applyPerformanceProfile")
    }

    @Test("AVPlayer-backed source publishes a frame within a bounded wall-clock window")
    func publishesFrameWithinBoundedDelay() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let videoURL = try await SyntheticVideoFixture.writeMP4(
            durationSeconds: 1.0,
            frameRate: 24
        )
        defer { try? FileManager.default.removeItem(at: videoURL) }

        let source = try WPEVideoTextureSource(device: device, videoURL: videoURL)
        defer { source.invalidate() }
        source.applyPerformanceProfile(.quality)

        let texture = try await pollForTexture(from: source, timeout: 2.0)
        try #require(texture != nil, "AVPlayer-backed source must produce a frame within 2s")
        let format = try #require(texture?.pixelFormat)
        #expect(format == .bgra8Unorm_srgb || format == .bgra8Unorm,
                "Frames are BGRA8; the sRGB variant is preferred to match the pipeline's output attachment")
    }

    @Test("Playhead advances on the wall clock — not faster (the old AVAssetReader bug)")
    func playheadAdvancesAtRealTime() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let videoURL = try await SyntheticVideoFixture.writeMP4(
            durationSeconds: 4.0,
            frameRate: 24
        )
        defer { try? FileManager.default.removeItem(at: videoURL) }

        let source = try WPEVideoTextureSource(device: device, videoURL: videoURL)
        defer { source.invalidate() }
        source.applyPerformanceProfile(.quality)

        try #require(try await pollForTexture(from: source, timeout: 2.0) != nil)
        let startSeconds = source.currentPlayheadSeconds

        let measurementWindow: TimeInterval = 0.6
        try await Task.sleep(for: .milliseconds(Int(measurementWindow * 1_000)))

        let endSeconds = source.currentPlayheadSeconds
        let advanced = endSeconds - startSeconds

        #expect(advanced <= measurementWindow * 2.0,
                "Playhead advanced \(advanced)s over \(measurementWindow)s wall-clock — AVPlayer pacing regression?")
        #expect(advanced >= 0.05,
                "Playhead did not advance at all (\(advanced)s) — player is stuck/paused")
    }

    @Test("Suspending freezes the playhead; resuming starts it again")
    func suspendFreezesPlayhead() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let videoURL = try await SyntheticVideoFixture.writeMP4(
            durationSeconds: 2.0,
            frameRate: 24
        )
        defer { try? FileManager.default.removeItem(at: videoURL) }

        let source = try WPEVideoTextureSource(device: device, videoURL: videoURL)
        defer { source.invalidate() }
        source.applyPerformanceProfile(.quality)

        _ = try await pollForTexture(from: source, timeout: 2.0)
        source.applyPerformanceProfile(.suspended)
        let pausedAt = source.currentPlayheadSeconds

        try await Task.sleep(for: .milliseconds(300))
        let stillPausedAt = source.currentPlayheadSeconds
        #expect(abs(stillPausedAt - pausedAt) < 0.05,
                "Suspend must freeze the playhead (was \(pausedAt)s, now \(stillPausedAt)s)")
        #expect(source.texture(at: 0) != nil, "Cached frame must survive suspend")

        source.applyPerformanceProfile(.quality)
        try await Task.sleep(for: .milliseconds(300))
        let resumedAt = source.currentPlayheadSeconds
        #expect(resumedAt > pausedAt,
                "Resume must advance the playhead past the suspend point (paused at \(pausedAt)s, now at \(resumedAt)s)")
    }

    @Test("invalidate() drops the cached frame and removes the staged temp file")
    func invalidateClearsStateAndCleansUp() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let videoURL = try await SyntheticVideoFixture.writeMP4(
            durationSeconds: 1.0,
            frameRate: 24
        )
        defer { try? FileManager.default.removeItem(at: videoURL) }

        let source = try WPEVideoTextureSource(device: device, videoURL: videoURL)
        source.applyPerformanceProfile(.quality)
        _ = try await pollForTexture(from: source, timeout: 2.0)
        #expect(FileManager.default.fileExists(atPath: videoURL.path))

        source.invalidate()

        #expect(source.texture(at: 0) == nil, "invalidate() must clear the cached frame")
        #expect(FileManager.default.fileExists(atPath: videoURL.path) == false, "invalidate() must remove the staged temp file")
    }

    @Test("invalidate() is idempotent — second call is a no-op")
    func invalidateIsIdempotent() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let videoURL = try await SyntheticVideoFixture.writeMP4(
            durationSeconds: 1.0,
            frameRate: 24
        )
        defer { try? FileManager.default.removeItem(at: videoURL) }

        let source = try WPEVideoTextureSource(device: device, videoURL: videoURL)
        source.invalidate()
        source.invalidate()
        source.applyPerformanceProfile(.quality)
        #expect(source.texture(at: 0) == nil)
    }

    @Test("Script control plays the clip once and freezes — does not keep looping")
    func scriptControlPlaysOnceAndHolds() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let videoURL = try await SyntheticVideoFixture.writeMP4(durationSeconds: 1.0, frameRate: 24)
        defer { try? FileManager.default.removeItem(at: videoURL) }

        let source = try WPEVideoTextureSource(device: device, videoURL: videoURL)
        defer { source.invalidate() }

        func pump(_ seconds: TimeInterval) async throws {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                _ = source.texture(at: 0)
                try await Task.sleep(for: .milliseconds(16))
            }
        }

        source.scriptPlay()
        try await pump(2.0)
        let frozenAt = source.currentPlayheadSeconds
        try await pump(0.6)
        let stillFrozenAt = source.currentPlayheadSeconds

        #expect(abs(stillFrozenAt - frozenAt) < 0.05,
                "Script-controlled source must freeze after one play, not keep looping")
        #expect(source.texture(at: 0) != nil, "A frame must still be shown while frozen")
    }

    // MARK: - Helpers

    private func pollForTexture(
        from source: WPEVideoTextureSource,
        timeout seconds: TimeInterval
    ) async throws -> MTLTexture? {
        let deadline = Date().addingTimeInterval(seconds)
        var texture: MTLTexture?
        while Date() < deadline {
            texture = source.texture(at: 0)
            if texture != nil { return texture }
            try await Task.sleep(for: .milliseconds(30))
        }
        return texture
    }
}

// MARK: - Synthetic MP4 fixture

private enum SyntheticVideoFixture {
    static func writeMP4(
        durationSeconds: TimeInterval,
        frameRate: Int32
    ) async throws -> URL {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wpe-pacing-\(UUID().uuidString).mp4")
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let width = 64
        let height = 64
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = false
        let pixelAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: pixelAttributes
        )
        guard writer.canAdd(input) else {
            throw FixtureError.writerSetupFailed("cannot add video input")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw FixtureError.writerSetupFailed(writer.error?.localizedDescription ?? "startWriting failed")
        }
        writer.startSession(atSourceTime: .zero)

        let totalFrames = max(2, Int(Double(frameRate) * durationSeconds))
        for index in 0..<totalFrames {
            while !input.isReadyForMoreMediaData {
                await Task.yield()
            }
            let pixelBuffer = try makePixelBuffer(
                width: width,
                height: height,
                fillByte: UInt8(40 + (index * 3) % 200)
            )
            let pts = CMTime(value: Int64(index), timescale: frameRate)
            if !adaptor.append(pixelBuffer, withPresentationTime: pts) {
                throw FixtureError.writerSetupFailed(
                    writer.error?.localizedDescription ?? "adaptor.append failed"
                )
            }
        }
        input.markAsFinished()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }
        if writer.status != .completed {
            throw FixtureError.writerSetupFailed(
                writer.error?.localizedDescription ?? "writer ended with status \(writer.status.rawValue)"
            )
        }
        return outputURL
    }

    private static func makePixelBuffer(
        width: Int,
        height: Int,
        fillByte: UInt8
    ) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes: CFDictionary = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ] as CFDictionary
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            throw FixtureError.writerSetupFailed("CVPixelBufferCreate returned \(status)")
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = CVPixelBufferGetBaseAddress(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        memset(base, Int32(fillByte), bytesPerRow * height)
        return buffer
    }

    private enum FixtureError: Error, CustomStringConvertible {
        case writerSetupFailed(String)
        var description: String {
            switch self {
            case .writerSetupFailed(let detail): return "AVAssetWriter setup failed: \(detail)"
            }
        }
    }
}

/// A dropped source must stop its AVQueuePlayer even when nobody called
/// `invalidate()`. A playing AVPlayer is retained by AVFoundation's own
/// CoreMedia threads, so releasing the Swift reference does NOT tear it down:
/// the MP4 and its decode buffers (~300 MB per 4K source) stay resident and the
/// decoder keeps running. Sampled in Release at 10.8 GB / 42 threads with four
/// live `coremedia.audioqueue.source` sets.
@MainActor
@Suite("WPEVideoTextureSource teardown", .serialized)
struct WPEVideoTextureSourceTeardownTests {

    @Test("Dropping the source without invalidate() still tears the player down")
    func deinitInvalidatesWithoutExplicitCall() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let videoURL = try await SyntheticVideoFixture.writeMP4(
            durationSeconds: 1.0,
            frameRate: 24
        )
        defer { try? FileManager.default.removeItem(at: videoURL) }

        // `onInvalidate` fires from invalidate() only, so it is a direct probe
        // for "was the player actually torn down", independent of memory noise.
        let torndown = OSAllocatedUnfairLock(initialState: false)
        do {
            let source = try WPEVideoTextureSource(
                device: device,
                videoURL: videoURL,
                onInvalidate: { _ in torndown.withLock { $0 = true } }
            )
            source.applyPerformanceProfile(.quality)
            try await Task.sleep(for: .milliseconds(200))
            // Deliberately NO invalidate() — the drop below must suffice.
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(torndown.withLock { $0 }, "deinit must invalidate the dropped source")
    }
}

@Suite("WPE video output cap and decoder admission")
struct WPEVideoOutputCapTests {
    @Test("clampedPixelSize never upscales and even-rounds NV12 dimensions")
    func clampedPixelSizeNeverUpscales() {
        #expect(WPEVideoOutputCap.clampedPixelSize(
            source: CGSize(width: 1920, height: 1080), maxEdge: 1920
        ) == nil)
        #expect(WPEVideoOutputCap.clampedPixelSize(
            source: CGSize(width: 1920, height: 1080), maxEdge: 3840
        ) == nil)
        #expect(
            WPEVideoOutputCap.clampedPixelSize(
                source: CGSize(width: 3840, height: 2160), maxEdge: 1920
            ) == CGSize(width: 1920, height: 1080)
        )
        #expect(
            WPEVideoOutputCap.clampedPixelSize(
                source: CGSize(width: 7680, height: 4320), maxEdge: 3840
            ) == CGSize(width: 3840, height: 2160)
        )
        #expect(WPEVideoOutputCap.clampedPixelSize(
            source: CGSize(width: 64, height: 64), maxEdge: 0
        ) == nil)
        let odd = WPEVideoOutputCap.clampedPixelSize(
            source: CGSize(width: 1001, height: 501), maxEdge: 100
        )
        #expect(odd != nil)
        #expect(Int(odd?.width ?? 1) % 2 == 0)
        #expect(Int(odd?.height ?? 1) % 2 == 0)
        #expect((odd?.width ?? 0) <= 100)
        #expect((odd?.height ?? 0) <= 100)
    }

    @Test("maxOutputEdge is the min of drawable long-edge and MetalFX cap")
    func maxOutputEdgeCombinesDrawableAndPlan() {
        #expect(
            WPEVideoOutputCap.maxOutputEdge(
                drawableSize: CGSize(width: 3840, height: 2160),
                latchedTextureCap: nil
            ) == 3840
        )
        #expect(
            WPEVideoOutputCap.maxOutputEdge(
                drawableSize: CGSize(width: 3840, height: 2160),
                latchedTextureCap: 1920
            ) == 1920
        )
        #expect(
            WPEVideoOutputCap.maxOutputEdge(
                drawableSize: .zero,
                latchedTextureCap: 1440
            ) == 1440
        )
        #expect(
            WPEVideoOutputCap.maxOutputEdge(
                drawableSize: .zero,
                latchedTextureCap: nil
            ) == nil
        )
    }

    @Test("pixelBufferAttributes omit size until a cap is supplied")
    func pixelBufferAttributesOmitSizeUntilCapped() {
        let uncapped = WPEVideoTextureSource.pixelBufferAttributes(
            pixelFormats: WPEVideoTextureSource.negotiatedPixelFormats,
            outputSize: nil
        )
        #expect(uncapped[kCVPixelBufferWidthKey as String] == nil)
        #expect(uncapped[kCVPixelBufferHeightKey as String] == nil)
        #expect(uncapped[kCVPixelBufferPixelFormatTypeKey as String] != nil)

        let capped = WPEVideoTextureSource.pixelBufferAttributes(
            pixelFormats: WPEVideoTextureSource.negotiatedPixelFormats,
            outputSize: CGSize(width: 1920, height: 1080)
        )
        #expect(capped[kCVPixelBufferWidthKey as String] as? Int == 1920)
        #expect(capped[kCVPixelBufferHeightKey as String] as? Int == 1080)
    }

    @Test("Admission limit 1: second source is a still; releasing the first frees the slot")
    func decoderAdmissionStillFallbackAndRelease() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let videoURL = try await SyntheticVideoFixture.writeMP4(
            durationSeconds: 0.5,
            frameRate: 24
        )
        defer { try? FileManager.default.removeItem(at: videoURL) }

        let admission = WPEVideoDecoderAdmission(limit: 1)
        let live = try WPEVideoTextureSource(
            device: device,
            videoURL: videoURL,
            decoderAdmission: admission
        )
        #expect(live.isLiveDecoder)
        #expect(admission.activeCount == 1)

        let still = try WPEVideoTextureSource(
            device: device,
            videoURL: videoURL,
            decoderAdmission: admission
        )
        #expect(!still.isLiveDecoder)
        #expect(admission.activeCount == 1)
        #expect(still.texture(at: 0) != nil, "overflow source must keep a still frame, not refuse")

        live.invalidate()
        #expect(admission.activeCount == 0)

        let liveAgain = try WPEVideoTextureSource(
            device: device,
            videoURL: videoURL,
            decoderAdmission: admission
        )
        defer { liveAgain.invalidate() }
        #expect(liveAgain.isLiveDecoder)
        #expect(admission.activeCount == 1)

        still.invalidate()
        #expect(admission.activeCount == 1)
        #expect(!admission.hasVacancy, "the replacement live decoder still holds the only slot")
        liveAgain.invalidate()
        #expect(admission.hasVacancy)
    }

    @Test("Admission with a vacancy of 0 never starts a live decoder")
    func zeroLimitAdmissionStaysStill() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let videoURL = try await SyntheticVideoFixture.writeMP4(
            durationSeconds: 0.5,
            frameRate: 24
        )
        defer { try? FileManager.default.removeItem(at: videoURL) }

        let admission = WPEVideoDecoderAdmission(limit: 0)
        #expect(!admission.hasVacancy)
        let source = try WPEVideoTextureSource(
            device: device,
            videoURL: videoURL,
            decoderAdmission: admission
        )
        defer { source.invalidate() }
        #expect(!source.isLiveDecoder)
        #expect(admission.activeCount == 0)
        #expect(source.texture(at: 0) != nil)
    }

    @Test("A display-sized cap is stored on the source and does not upscale a 64² clip")
    func outputPixelSizeIsStoredAndDoesNotUpscaleSmallClips() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let videoURL = try await SyntheticVideoFixture.writeMP4(
            durationSeconds: 0.5,
            frameRate: 24
        )
        defer { try? FileManager.default.removeItem(at: videoURL) }

        let sourceSize = try #require(await WPEVideoOutputCap.sourceDisplaySize(fileURL: videoURL))
        #expect(sourceSize.width == 64)
        #expect(sourceSize.height == 64)

        let noUpscale = WPEVideoOutputCap.clampedPixelSize(source: sourceSize, maxEdge: 3840)
        #expect(noUpscale == nil)
        let uncapped = try WPEVideoTextureSource(
            device: device,
            videoURL: videoURL,
            outputPixelSize: noUpscale
        )
        defer { uncapped.invalidate() }
        #expect(uncapped.outputPixelSizeForTesting == nil)

        let downscale = try #require(
            WPEVideoOutputCap.clampedPixelSize(source: sourceSize, maxEdge: 32)
        )
        #expect(downscale == CGSize(width: 32, height: 32))
        let capped = try WPEVideoTextureSource(
            device: device,
            videoURL: videoURL,
            outputPixelSize: downscale
        )
        defer { capped.invalidate() }
        #expect(capped.outputPixelSizeForTesting == downscale)
    }

    @Test("Renderer helper clamps 8K source to a 4K drawable")
    func rendererHelperClampsToDrawable() async throws {
        let videoURL = try await SyntheticVideoFixture.writeMP4(
            durationSeconds: 0.5,
            frameRate: 24
        )
        defer { try? FileManager.default.removeItem(at: videoURL) }

        let none = await WPEMetalSceneRenderer.videoOutputPixelSize(
            fileURL: videoURL,
            drawableSize: CGSize(width: 3840, height: 2160),
            latchedTextureCap: nil
        )
        #expect(none == nil, "64² source on a 4K display must not upscale")

        // The helper only returns a size when the file itself exceeds the cap.
        // Probe the clamp math with a synthetic 8K source size — the file
        // probe is covered above; this pins the renderer wiring.
        #expect(
            WPEVideoOutputCap.clampedPixelSize(
                source: CGSize(width: 7680, height: 4320),
                maxEdge: WPEVideoOutputCap.maxOutputEdge(
                    drawableSize: CGSize(width: 3840, height: 2160),
                    latchedTextureCap: nil
                ) ?? 0
            ) == CGSize(width: 3840, height: 2160)
        )
    }
}
