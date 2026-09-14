import AVFoundation
import CoreMedia
import Foundation
import Testing

@Suite("System wallpaper renderer guard")
struct SystemWallpaperRendererGuardTests {

    private func renderer() throws -> String {
        try RepositoryRoot.source("SystemWallpaperProvider/VideoRenderer.swift")
    }

    private func handler() throws -> String {
        try RepositoryRoot.source("SystemWallpaperProvider/WallpaperXPCHandler.swift")
    }

    /// One member's full text, sliced to the closing brace at member indentation:
    /// a fixed-length prefix would shrink as the comment above the code grows.
    private func member(_ source: String, from marker: String) throws -> String {
        let start = try #require(source.range(of: marker), "no \(marker) in source")
        let body = source[start.lowerBound...]
        guard let end = body.range(of: "\n    }\n") else { return String(body) }
        return String(body[..<end.upperBound])
    }

    // MARK: - Registry confinement

    @Test("Every registry access runs on the lifecycle queue")
    func selectedChoicesDidChangeHopsToTheLifecycleQueue() throws {
        let source = try handler()
        let body = try member(source, from: "func selectedChoicesDidChange")
        let hop = try #require(body.range(of: "Self.queue.async"), "the body never reaches the lifecycle queue")
        let heartbeat = try #require(body.range(of: "Self.writeActiveHeartbeat("))
        #expect(
            hop.lowerBound < heartbeat.lowerBound,
            "registry.all is read before the queue hop — that is the race"
        )
    }

    // MARK: - Loop seam

    /// Zero-sample buffers are edit-list markers, not frames: a trailing one
    /// carries the asset's full duration and would park the next loop past it.
    @Test("The loop seam ignores zero-sample marker buffers")
    func loopSeamIgnoresMarkerBuffers() throws {
        let source = try renderer()
        let shift = try member(source, from: "private func shift(")
        #expect(
            shift.contains("CMSampleBufferGetNumSamples(sample) > 0"),
            "maxSampleEnd must only count buffers that actually carry media"
        )
    }

    @Test("AVAssetReader emits markers and anchors a mid-file range on a sync sample")
    func assetReaderMarkersAndSyncAnchoring() async throws {
        let url = try Self.makeKeyframedMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)

        let fromTop = try Self.readHead(asset: asset, track: track, from: nil, count: 2)
        #expect(
            fromTop.contains { $0.sampleCount == 0 },
            "no marker buffer — the numSamples guard would be pointless"
        )

        let midGOP = CMTime(seconds: 3.5, preferredTimescale: 600)
        let resumed = try Self.readHead(asset: asset, track: track, from: midGOP, count: 3)
        let firstFrame = try #require(resumed.first { $0.sampleCount > 0 })
        #expect(firstFrame.isSync, "supply after a flush must start on a sync sample")
        #expect(
            firstFrame.pts < midGOP,
            "the reader is expected to back up to the sync sample at or before the requested start"
        )
    }

    // MARK: - Decoder loss and deep pause

    @Test("Losing the decoder is observed and recovered with a flush")
    func decoderLossIsObservedAndFlushed() throws {
        let source = try renderer()
        #expect(
            source.contains("requiresFlushToResumeDecodingDidChangeNotification"),
            "nothing observes the renderer losing its decoder"
        )
        let recovery = try member(source, from: "private func handleDecoderLoss")
        #expect(recovery.contains("renderer.flush()"), "only a flush clears the failed status")
        #expect(recovery.contains("openReader("), "after a flush the supply has to restart at a sync sample")
    }

    @Test("Deep pause drops the queued frames it is about to re-read")
    func deepPauseFlushesTheQueue() throws {
        let source = try renderer()
        let enter = try member(source, from: "private func enterDeepPause")
        #expect(enter.contains("renderer.flush()"), "the queued future frames survive into the resume")
    }

    // MARK: - Re-acquire framing

    @Test("Re-acquire reframes the video sublayer, not just the root layer")
    func reacquireResizesTheVideoLayer() throws {
        let source = try handler()
        let reframe = try #require(
            source.range(of: "surface.bridge.reframe(")
                .map { String(source[$0.lowerBound...].prefix(900)) }
        )
        #expect(
            reframe.contains("surface.renderer.layer.frame"),
            "the sublayer keeps the previous display's size"
        )
    }

    // MARK: - Power and thermal

    @Test("Thermal, low-power and AC/battery changes re-apply the policy")
    func powerConditionChangesReapplyPolicy() throws {
        let bridge = try RepositoryRoot.source("SystemWallpaperProvider/WallpaperXPCBridge.swift")
        #expect(bridge.contains("thermalStateDidChangeNotification"), "thermal changes are not observed")
        #expect(bridge.contains("NSProcessInfoPowerStateDidChange"), "Low Power Mode changes are not observed")
        #expect(
            bridge.contains("IOPSNotificationCreateRunLoopSource"),
            "AC↔battery is not NSProcessInfoPowerStateDidChange on macOS; it needs the IOKit source"
        )
        #expect(bridge.contains("WallpaperXPCHandler.reapplyPolicy"), "nothing re-applies the policy")
    }

    // MARK: - Fixture

    private struct Head {
        let pts: CMTime
        let sampleCount: CMItemCount
        let isSync: Bool
    }

    private static func readHead(
        asset: AVURLAsset, track: AVAssetTrack, from start: CMTime?, count: Int
    ) throws -> [Head] {
        let reader = try AVAssetReader(asset: asset)
        if let start {
            reader.timeRange = CMTimeRange(start: start, duration: .positiveInfinity)
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        reader.startReading()
        defer { reader.cancelReading() }

        var head: [Head] = []
        while head.count < count, let sample = output.copyNextSampleBuffer() {
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                as? [[CFString: Any]]
            let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
            head.append(Head(pts: CMSampleBufferGetPresentationTimeStamp(sample),
                             sampleCount: CMSampleBufferGetNumSamples(sample),
                             isSync: !notSync))
        }
        return head
    }

    /// 6 s of H.264 with a keyframe every 2 s, so 3.5 s is reliably mid-GOP.
    private static func makeKeyframedMovie() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("seam-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 320,
            AVVideoHeightKey: 240,
            AVVideoCompressionPropertiesKey: [
                AVVideoMaxKeyFrameIntervalDurationKey: 2.0,
                AVVideoAverageBitRateKey: 400_000,
            ] as [String: Any],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
        )
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0 ..< 180 {
            while !input.isReadyForMoreMediaData { usleep(500) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 320, 240, kCVPixelFormatType_32BGRA, nil, &buffer)
            guard let buffer else { break }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                memset(base, Int32(frame % 251), CVPixelBufferGetDataSize(buffer))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        return url
    }
}
