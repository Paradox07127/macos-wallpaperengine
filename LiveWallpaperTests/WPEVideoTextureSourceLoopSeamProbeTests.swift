import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Metal
import QuartzCore
import Testing
@testable import LiveWallpaper

/// Loop-seam regression gate: frame publication must not stall while
/// AVPlayerLooper rotates items. Guards two measured regressions (2026-08-20):
/// the item-level output being re-attached only AFTER the rotation froze the
/// last frame ~150 ms per wrap on the macOS 14 path, and a muted-but-present
/// audio track holding publication ~100 ms per wrap (fixed by the disk cache's
/// audio strip; fixtures here are audio-free, so this suite pins the output
/// plumbing, not the strip).
@MainActor
@Suite("WPEVideoTextureSource loop seam", .serialized)
struct WPEVideoTextureSourceLoopSeamProbeTests {

    /// Floor of the tolerated seam gap. Frame cadence is ~33 ms and the healthy
    /// measured seam is 31-44 ms; the pre-fix legacy failure was ~150 ms. The
    /// effective threshold is `max(0.09, 3 x median gap)`, so a loaded host
    /// that stretches every gap stretches the tolerance with it.
    private static let maxSeamGapFloor: TimeInterval = 0.09

    private struct Sample {
        let host: TimeInterval
        let playhead: TimeInterval
        let publishes: Int
    }

    private struct SeamMeasurement {
        let publishCount: Int
        let wrapCount: Int
        let seamGaps: [TimeInterval]
        let medianGap: TimeInterval
    }

    private func measureSeams(legacy: Bool) async throws -> SeamMeasurement {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let videoURL = try await LoopSeamVideoFixture.writeMP4(durationSeconds: 1.5, frameRate: 30)
        defer { try? FileManager.default.removeItem(at: videoURL) }

        let source = try WPEVideoTextureSource(
            device: device,
            videoURL: videoURL,
            forceLegacyItemLevelOutputForTesting: legacy
        )
        defer { source.invalidate() }
        source.applyPerformanceProfile(.quality)

        // Window starts at the first published frame, not at play(): startup
        // latency otherwise eats into the publish/wrap counts the assertions need.
        let firstFrameDeadline = CACurrentMediaTime() + 5.0
        while source.texture(at: 0) == nil {
            try #require(CACurrentMediaTime() < firstFrameDeadline,
                         "Source never published a first frame within 5s")
            try await Task.sleep(for: .milliseconds(10))
        }

        var samples: [Sample] = []
        let start = CACurrentMediaTime()
        while CACurrentMediaTime() - start < 5.5 {
            _ = source.texture(at: 0)
            samples.append(Sample(
                host: CACurrentMediaTime(),
                playhead: source.currentPlayheadSeconds,
                publishes: source.publishedFrameCountForTesting
            ))
            try await Task.sleep(for: .milliseconds(2))
        }

        // Wrap instants: playhead jumped backwards by more than half the clip.
        var wraps: [TimeInterval] = []
        for i in 1..<samples.count where samples[i].playhead + 0.5 < samples[i - 1].playhead {
            wraps.append(samples[i].host)
        }

        var publishTimes: [TimeInterval] = []
        for i in 1..<samples.count where samples[i].publishes > samples[i - 1].publishes {
            publishTimes.append(samples[i].host)
        }

        var gaps: [(start: TimeInterval, delta: TimeInterval)] = []
        for i in 1..<publishTimes.count {
            gaps.append((publishTimes[i - 1], publishTimes[i] - publishTimes[i - 1]))
        }
        let seamGaps = wraps.compactMap { wrap in
            gaps.first { $0.start <= wrap && $0.start + $0.delta >= wrap }?.delta
        }
        let sorted = gaps.map(\.delta).sorted()
        return SeamMeasurement(
            publishCount: publishTimes.count,
            wrapCount: wraps.count,
            seamGaps: seamGaps,
            medianGap: sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        )
    }

    private func assertSeamsAtFrameCadence(_ measurement: SeamMeasurement) {
        #expect(measurement.publishCount > 100,
                "Expected ~165 publishes over 5.5s of a 30fps clip, got \(measurement.publishCount) — source barely played, seam data is meaningless")
        #expect(measurement.wrapCount >= 2,
                "Expected the 1.5s clip to wrap at least twice in 5.5s, got \(measurement.wrapCount)")
        // Every wrap must be bracketed by publishes: a wrap with no publish
        // after it (frozen on the last frame) must fail, not fall out of the list.
        #expect(measurement.seamGaps.count == measurement.wrapCount,
                "\(measurement.wrapCount - measurement.seamGaps.count) wrap(s) had no bracketing publish — frame delivery stopped at the seam")
        let threshold = max(Self.maxSeamGapFloor, measurement.medianGap * 3)
        for gap in measurement.seamGaps {
            #expect(gap < threshold,
                    "Publish gap across a loop wrap was \(Int(gap * 1000)) ms (threshold \(Int(threshold * 1000)) ms) — the looper rotation stalled frame delivery")
        }
    }

    /// On macOS 14 this exercises the item-level path a second time — the
    /// player-level tap only exists on 15+ — which is redundant, not wrong.
    @Test("Player-level output keeps frame cadence across loop wraps (macOS 15+ path)")
    func playerLevelSeams() async throws {
        assertSeamsAtFrameCadence(try await measureSeams(legacy: false))
    }

    @Test("Item-level output keeps frame cadence across loop wraps (macOS 14 path)")
    func legacyItemLevelSeams() async throws {
        // Red before the per-item pre-attached outputs: ~150 ms per wrap.
        assertSeamsAtFrameCadence(try await measureSeams(legacy: true))
    }
}

private enum LoopSeamVideoFixture {
    static func writeMP4(durationSeconds: TimeInterval, frameRate: Int32) async throws -> URL {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wpe-loopseam-\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let width = 640
        let height = 360
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height
            ]
        )
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
        )
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let frameCount = Int(durationSeconds * Double(frameRate))
        for frame in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
            }
            guard let pool = adaptor.pixelBufferPool else { break }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
            guard let buffer else { break }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
                for row in 0..<height {
                    let value = UInt8(truncatingIfNeeded: row &+ frame &* 4)
                    memset(base.advanced(by: row * bytesPerRow), Int32(value), bytesPerRow)
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: frameRate))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? NSError(domain: "LoopSeamVideoFixture", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "AVAssetWriter finished with status \(writer.status.rawValue)"
            ])
        }
        return outputURL
    }
}
