import AVFoundation
import CoreMedia
import CoreVideo
import CryptoKit
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

    @Test("Explicit nonlooping script playback reaches the endpoint and holds")
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

        source.scriptSetLoop(false)
        source.scriptPlay()
        try await pump(2.0)
        let frozenAt = source.currentPlayheadSeconds
        try await pump(0.6)
        let stillFrozenAt = source.currentPlayheadSeconds

        #expect(abs(stillFrozenAt - frozenAt) < 0.05,
                "An explicitly nonlooping source must freeze at its endpoint")
        #expect(source.texture(at: 0) != nil, "A frame must still be shown while frozen")
        let ended = try #require(source.scriptPlaybackSnapshot)
        #expect(!ended.loop && !ended.isPlaying)
        #expect(ended.currentTime == ended.duration)
    }

    @Test("Policy resume restores a script-started video without a second play command")
    func policyResumeRestoresScriptPlayback() async throws {
        try await withScriptVideo { source in
            source.scriptPlay()
            try await requirePlayheadAdvance(source, after: 0)
            source.applyPerformanceProfile(.suspended)
            try await requireFrozenPlayhead(source)
            let pausedAt = source.currentPlayheadSeconds
            source.applyPerformanceProfile(.quality)
            try await requirePlayheadAdvance(source, after: pausedAt)
        }
    }

    @Test("A script play received while policy-suspended waits for policy resume")
    func scriptPlayCannotBypassPolicySuspend() async throws {
        try await withScriptVideo { source in
            source.applyPerformanceProfile(.suspended)
            source.scriptPlay()
            try await requireFrozenPlayhead(source)
            #expect(source.currentPlayheadSeconds < 0.05)
            source.applyPerformanceProfile(.quality)
            try await requirePlayheadAdvance(source, after: 0)
        }
    }

    @Test("Explicit script pause survives repeated policy suspend/resume")
    func policyResumeDoesNotOverrideScriptPause() async throws {
        try await withScriptVideo { source in
            source.scriptPlay()
            try await requirePlayheadAdvance(source, after: 0)
            source.scriptPause()
            source.applyPerformanceProfile(.suspended)
            source.applyPerformanceProfile(.quality)
            source.applyPerformanceProfile(.quality)
            try await requireFrozenPlayhead(source)
        }
    }

    @Test("Script stop while suspended rewinds and stays stopped after resume")
    func scriptStopSurvivesPolicyResume() async throws {
        try await withScriptVideo { source in
            source.scriptPlay()
            try await requirePlayheadAdvance(source, after: 0)
            source.applyPerformanceProfile(.suspended)
            source.scriptStop()
            try await Task.sleep(for: .milliseconds(150))
            source.applyPerformanceProfile(.quality)
            try await requireFrozenPlayhead(source)
            #expect(source.currentPlayheadSeconds < 0.1)
        }
    }

    @Test("Taking script control with a seek retains pre-suspend automatic playback intent")
    func scriptSeekPreservesAutomaticPlaybackIntent() async throws {
        try await withScriptVideo { source in
            source.applyPerformanceProfile(.quality)
            try await requirePlayheadAdvance(source, after: 0)
            source.applyPerformanceProfile(.suspended)
            source.scriptSetCurrentTime(1)
            try await Task.sleep(for: .milliseconds(150))
            try await requireFrozenPlayhead(source)
            let pausedAt = source.currentPlayheadSeconds
            source.applyPerformanceProfile(.quality)
            try await requirePlayheadAdvance(source, after: pausedAt)
        }
    }

    @Test("Policy resume preserves a script video's natural end hold")
    func policyResumePreservesScriptEndHold() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let url = try await SyntheticVideoFixture.writeMP4(durationSeconds: 0.5, frameRate: 24)
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try WPEVideoTextureSource(device: device, videoURL: url)
        defer { source.invalidate() }
        source.scriptSetLoop(false)
        source.scriptPlay()
        try await pump(source, for: .seconds(2))
        source.applyPerformanceProfile(.suspended)
        source.applyPerformanceProfile(.quality)
        try await requireFrozenPlayhead(source)
        #expect(source.texture(at: 0) != nil)
        let snapshot = try #require(source.scriptPlaybackSnapshot)
        #expect(snapshot.currentTime == snapshot.duration)
        #expect(!snapshot.isPlaying)
        #expect(!snapshot.loop)
    }

    @Test("Script play preserves default looping across natural endpoints")
    func scriptPlayKeepsDefaultLooping() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let url = try await SyntheticVideoFixture.writeMP4(durationSeconds: 0.5, frameRate: 24)
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try WPEVideoTextureSource(device: device, videoURL: url)
        defer { source.invalidate() }
        source.scriptPlay()
        try await pump(source, for: .seconds(2))
        let snapshot = try #require(source.scriptPlaybackSnapshot)
        #expect(snapshot.loop)
        #expect(snapshot.isPlaying)
        #expect(source.isActivelyPlaying)
        #expect(source.texture(at: 0) != nil)
    }

    @Test("Measured rates change the real clock and retain intent through policy suspension", arguments: [0.5, 1.0, 2.0])
    func measuredPlaybackRates(_ rate: Double) async throws {
        try await withScriptVideo { source in
            source.scriptPlay()
            try await requirePlayheadAdvance(source, after: 0)
            source.scriptSetRate(rate)
            source.applyPerformanceProfile(.suspended)
            try await requireFrozenPlayhead(source)
            source.applyPerformanceProfile(.quality)
            let before = source.currentPlayheadSeconds
            let clock = ContinuousClock()
            let start = clock.now
            try await pump(source, for: .milliseconds(500))
            let elapsed = start.duration(to: clock.now)
            let parts = elapsed.components
            let seconds = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
            let advanced = source.currentPlayheadSeconds - before
            #expect(abs(advanced - seconds * rate) < 0.15)
            #expect(source.scriptPlaybackSnapshot?.rate == rate)
            #expect(source.texture(at: 0) != nil)
        }
    }

    @Test("Warm paused seek and stop retain the previously supplied texture")
    func pausedTransportRetainsPresentation() async throws {
        try await withScriptVideo { source in
            source.scriptPlay()
            try await requirePlayheadAdvance(source, after: 0)
            let presented = try #require(source.texture(at: 0))
            source.scriptPause()
            source.scriptSetCurrentTime(1.5)
            try await pump(source, for: .milliseconds(200))
            #expect(source.texture(at: 0) === presented)
            source.scriptSetCurrentTime(0.25)
            try await pump(source, for: .milliseconds(200))
            #expect(source.texture(at: 0) === presented)
            source.scriptStop()
            try await pump(source, for: .milliseconds(200))
            #expect(source.texture(at: 0) === presented)
            #expect(source.scriptPlaybackSnapshot?.isPlaying == false)
        }
    }

    #if !LITE_BUILD
    @Test(
        "Paused seek acknowledgment survives a play-pause without an owner update",
        .enabled(if: TestScratch.externalFixtureURL(pathKey: "WPE_PAUSED_SEEK_VIDEO") != nil)
    )
    func pausedSeekAcknowledgmentWithoutPlaybackAdvance() async throws {
        let fixture = try #require(TestScratch.externalFixtureURL(pathKey: "WPE_PAUSED_SEEK_VIDEO"))
        let fixtureHash = try SHA256.hash(data: Data(contentsOf: fixture)).map { String(format: "%02x", $0) }.joined()
        try #require(fixtureHash == "9532741c157d1464378042b67436a7fbc33078a874658517ce0315730865a73c")
        let source = try WPEVideoTextureSource(
            device: #require(MTLCreateSystemDefaultDevice()), videoURL: fixture, onInvalidate: { _ in }
        )
        defer { source.invalidate() }
        source.scriptPlay()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            _ = source.texture(at: 0)
            _ = source.driveStagedFrameWorkForTesting()
            if source.currentPlayheadSeconds > 0.35,
               source.scriptPlaybackSnapshot?.hasPresentedFrame == true {
                break
            }
            try await Task.sleep(for: .milliseconds(16))
        }
        source.scriptPause()
        try #require(source.currentPlayheadSeconds > 0.25)
        try #require(source.scriptPlaybackSnapshot?.hasPresentedFrame == true)
        let retained = try #require(source.texture(at: 0))
        source.scriptSetCurrentTime(0.25)
        #expect(source.scriptPlaybackSnapshot?.currentTime == 0.25)
        try await pump(source, for: .milliseconds(200))
        source.scriptSetCurrentTime(0.5)
        try await pump(source, for: .milliseconds(200))
        #expect(source.scriptPlaybackSnapshot?.currentTime == 0.25)
        source.scriptPlay()
        source.scriptPause()
        source.scriptSetCurrentTime(0.75)
        try await pump(source, for: .milliseconds(200))
        #expect(source.scriptPlaybackSnapshot?.currentTime == 0.25)
        #expect(source.scriptPlaybackSnapshot?.isPlaying == false)
        #expect(source.texture(at: 0) === retained)
        source.scriptStop()
        try await pump(source, for: .milliseconds(200))
        #expect(source.scriptPlaybackSnapshot?.currentTime == 0.25)
        #expect(source.texture(at: 0) === retained)
    }
    #endif

    #if !LITE_BUILD
    @Test(
        "Actual playback re-arms paused seek acknowledgement without a wrap",
        .enabled(if: TestScratch.externalFixtureURL(pathKey: "WPE_PAUSED_SEEK_LONG_VIDEO") != nil)
    )
    func pausedSeekAcknowledgmentAfterUnwrappedPlayback() async throws {
        let fixture = try #require(TestScratch.externalFixtureURL(pathKey: "WPE_PAUSED_SEEK_LONG_VIDEO"))
        let fixtureHash = try SHA256.hash(data: Data(contentsOf: fixture)).map { String(format: "%02x", $0) }.joined()
        try #require(fixtureHash == "e94b0d83397784e4674454af45930190f41f20884db0801189adf0744e22e911")
        let source = try WPEVideoTextureSource(
            device: #require(MTLCreateSystemDefaultDevice()), videoURL: fixture, onInvalidate: { _ in }
        )
        defer { source.invalidate() }
        source.scriptPlay()
        let warmDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < warmDeadline {
            _ = source.texture(at: 0)
            _ = source.driveStagedFrameWorkForTesting()
            if source.currentPlayheadSeconds > 0.35,
               source.scriptPlaybackSnapshot?.hasPresentedFrame == true {
                break
            }
            try await Task.sleep(for: .milliseconds(16))
        }
        try #require(source.scriptPlaybackSnapshot?.duration == 20)
        try #require(source.scriptPlaybackSnapshot?.hasPresentedFrame == true)
        source.scriptPause()
        try #require(source.currentPlayheadSeconds > 0.25)
        source.scriptSetCurrentTime(0.25)
        try await pump(source, for: .milliseconds(200))
        source.scriptSetCurrentTime(0.5)
        try await pump(source, for: .milliseconds(200))
        #expect(source.scriptPlaybackSnapshot?.currentTime == 0.25)
        source.scriptPlay()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline, source.currentPlayheadSeconds <= 0.52 {
            try await Task.sleep(for: .milliseconds(8))
        }
        try #require(source.currentPlayheadSeconds > 0.52)
        try #require(source.currentPlayheadSeconds < 20)
        let firstOwnerUpdate = try #require(source.scriptPlaybackSnapshot)
        #expect(firstOwnerUpdate.acknowledgedPausedSeekTime == nil)
        #expect(firstOwnerUpdate.currentTime > 0.5)
        _ = source.texture(at: 0)
        _ = source.driveStagedFrameWorkForTesting()
        source.scriptPause()
        source.scriptSetCurrentTime(0.75)
        #expect(source.scriptPlaybackSnapshot?.currentTime == 0.75)
        try await pump(source, for: .milliseconds(200))
        #expect(source.scriptPlaybackSnapshot?.currentTime == 0.75)
    }
    #endif

    #if !LITE_BUILD
    @Test("Finite unqualified seeks release held source readback", arguments: [-0.25, 0, 4, 5])
    func unqualifiedSeekReleasesAcknowledgment(_ target: Double) async throws {
        try await withScriptVideo { source in
            source.scriptPlay()
            try await requirePlayheadAdvance(source, after: 0)
            _ = source.driveStagedFrameWorkForTesting()
            try #require(source.scriptPlaybackSnapshot?.hasPresentedFrame == true)
            source.scriptPause()
            source.scriptSetCurrentTime(1.5)
            #expect(source.scriptPlaybackSnapshot?.acknowledgedPausedSeekTime == 1.5)
            source.scriptSetCurrentTime(.nan)
            #expect(source.scriptPlaybackSnapshot?.acknowledgedPausedSeekTime == 1.5)
            source.scriptSetCurrentTime(target)
            let immediate = try #require(source.scriptPlaybackSnapshot)
            #expect(immediate.acknowledgedPausedSeekTime == nil)
            #expect(immediate.currentTime == immediate.decoderCurrentTime)
            try await pump(source, for: .milliseconds(200))
            let settled = try #require(source.scriptPlaybackSnapshot)
            #expect(settled.acknowledgedPausedSeekTime == nil)
            #expect(settled.currentTime == settled.decoderCurrentTime)
        }
    }

    @Test(
        "Stop without a pending acknowledgement reports actual decoder completion",
        .enabled(if: TestScratch.externalFixtureURL(pathKey: "WPE_PAUSED_SEEK_VIDEO") != nil)
    )
    func stopWithoutAcknowledgmentObservation() async throws {
        let fixture = try #require(TestScratch.externalFixtureURL(pathKey: "WPE_PAUSED_SEEK_VIDEO"))
        let source = try WPEVideoTextureSource(
            device: #require(MTLCreateSystemDefaultDevice()), videoURL: fixture, onInvalidate: { _ in }
        )
        defer { source.invalidate() }
        source.scriptPlay()
        try await requirePlayheadAdvance(source, after: 0)
        _ = source.driveStagedFrameWorkForTesting()
        try #require(source.scriptPlaybackSnapshot?.hasPresentedFrame == true)
        source.scriptPause()
        let before = try #require(source.scriptPlaybackSnapshot)
        var evaluation = before
        evaluation.applyEvaluationIntent(.stop)
        #expect(evaluation.currentTime == 0)
        source.scriptStop()
        let immediate = try #require(source.scriptPlaybackSnapshot)
        #expect(immediate.acknowledgedPausedSeekTime == nil)
        #expect(immediate.currentTime == immediate.decoderCurrentTime)
        try await pump(source, for: .milliseconds(200))
        let settled = try #require(source.scriptPlaybackSnapshot)
        #expect(abs(settled.currentTime) < 0.05)
        if let output = TestScratch.externalFixtureURL(pathKey: "WPE_PAUSED_SEEK_OUTPUT") {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let record: [String: Any] = [
                "beforeSourceTime": before.currentTime,
                "sameEvaluationTime": evaluation.currentTime,
                "immediateSourceTime": immediate.currentTime,
                "immediateDecoderTime": immediate.decoderCurrentTime ?? -1,
                "settledSourceTime": settled.currentTime,
                "nativeSameEvaluationCompatibility": "source timing separately observed",
            ]
            try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("mac-stop-without-seek.json"), options: .atomic)
        }
    }
    #endif

    #if !LITE_BUILD
    @Test(
        "Observe exact-fixture paused seek source and VM clocks (opt-in, not native acceptance)",
        .enabled(if: TestScratch.externalFixtureURL(pathKey: "WPE_PAUSED_SEEK_VIDEO") != nil),
        arguments: ["B", "I", "F", "K"]
    )
    func observeRealPausedSeek(history: String) async throws {
        let fixture = try #require(TestScratch.externalFixtureURL(pathKey: "WPE_PAUSED_SEEK_VIDEO"))
        let output = try #require(TestScratch.externalFixtureURL(pathKey: "WPE_PAUSED_SEEK_OUTPUT"))
        let bytes = try Data(contentsOf: fixture)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        try #require(hash == "9532741c157d1464378042b67436a7fbc33078a874658517ce0315730865a73c")
        let staged = FileManager.default.temporaryDirectory
            .appendingPathComponent("wpe-paused-seek-\(UUID().uuidString).mp4")
        try bytes.write(to: staged, options: .atomic)
        defer { try? FileManager.default.removeItem(at: staged) }
        let device = try #require(MTLCreateSystemDefaultDevice())
        let source = try WPEVideoTextureSource(device: device, videoURL: staged)
        defer { source.invalidate() }
        try #require(source.isLiveDecoder)

        let shared = WPESharedScriptState(layers: [
            .init(id: "video", name: "video", size: SIMD2(256, 128), origin: .zero,
                  index: 0, parentName: nil),
        ])
        let instance = try WPELayerScriptInstance(script: """
        export function update() {
            const video = thisLayer.getVideoTexture();
            shared.beforeTime = video.getCurrentTime();
            shared.beforePlaying = video.isPlaying();
            if (shared.operation === 1) video.play();
            if (shared.operation === 2) video.pause();
            if (shared.operation === 3) { video.pause(); video.setCurrentTime(1.5); }
            if (shared.operation === 4) video.setCurrentTime(0.25);
            if (shared.operation === 5) video.setCurrentTime(0.75);
            if (shared.operation === 6) video.setCurrentTime(0.5);
            shared.sameTime = video.getCurrentTime();
            shared.samePlaying = video.isPlaying();
        }
        """, shared: shared, ownLayerName: "video", ownObjectID: "video")
        #expect(instance.initialOutput.own.videoCommands.isEmpty)
        var checkpoints: [[String: Any]] = []
        var evaluations: [[String: Any]] = []
        var qualification: [String: Any] = [:]
        var durationQualified = false
        var completed = false
        var retained: MTLTexture?
        let artifact = output.appendingPathComponent("mac-paused-seek-\(history)-\(UUID().uuidString).json")
        defer {
            do {
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                let payload: [String: Any] = [
                    "schema": 1, "history": history, "fixtureSHA256": hash,
                    "fixturePath": fixture.path, "completed": completed,
                    "nativeCompatibility": "not-assessed", "ownerLane": "MainActor",
                    "clock": "ProcessInfo.systemUptime-seconds", "pumpSleepMilliseconds": 16,
                    "os": ProcessInfo.processInfo.operatingSystemVersionString,
                    "checkpoints": checkpoints, "evaluations": evaluations,
                    "qualification": qualification,
                ]
                let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: artifact, options: .atomic)
            } catch {
                Issue.record("Cannot write paused seek observation: \(error)")
            }
        }

        func sample(_ label: String) throws -> WPEVideoPlaybackSnapshot {
            let started = ProcessInfo.processInfo.systemUptime
            let playhead = source.currentPlayheadSeconds
            let texture = source.texture(at: 0)
            if source.hasStagedFrameWork {
                try #require(source.driveStagedFrameWorkForTesting())
            }
            let snapshot = try #require(source.scriptPlaybackSnapshot)
            let sampled = ProcessInfo.processInfo.systemUptime
            shared.publishVideoPlayback(["video": snapshot], sourceKeys: ["video": "framecode.mp4"])
            shared.set("operation", 0)
            let readback = try #require(instance.tick())
            #expect(readback.own.videoCommands.isEmpty)
            let vmTime = try #require(shared.get("sameTime") as? Double)
            let vmPlaying = try #require(shared.get("samePlaying") as? Bool)
            #expect(vmTime == snapshot.currentTime)
            #expect(vmPlaying == snapshot.isPlaying)
            #expect(playhead.isFinite && snapshot.currentTime.isFinite)
            #expect(snapshot.duration.isFinite && snapshot.duration >= 0)
            if durationQualified {
                #expect(snapshot.duration == 2)
            }
            #expect(snapshot.loop && snapshot.rate == 1)
            if label == "pause.before" || label == "pause.seek1_5.before" {
                retained = try #require(texture)
            }
            if retained != nil, !snapshot.isPlaying {
                #expect(texture === retained)
            }
            checkpoints.append([
                "label": label, "sampleStartedUptime": started, "sourceSampledUptime": sampled,
                "sampleFinishedUptime": ProcessInfo.processInfo.systemUptime,
                "currentPlayheadSeconds": playhead, "snapshotCurrentTime": snapshot.currentTime,
                "snapshotDuration": snapshot.duration, "isPlaying": snapshot.isPlaying,
                "rate": snapshot.rate, "loop": snapshot.loop,
                "hasPresentedFrame": snapshot.hasPresentedFrame,
                "sourceGeneration": snapshot.sourceGeneration.uuidString,
                "textureIdentity": texture.map { String(describing: ObjectIdentifier($0)) } ?? "nil",
                "matchesRetainedTexture": retained.map { texture === $0 } ?? false,
                "publishedVMCurrentTime": vmTime, "publishedVMIsPlaying": vmPlaying,
            ])
            return snapshot
        }

        func command(_ label: String, operation: Int, expected: [WPELayerVideoCommand]) throws {
            let before = try sample(label + ".before")
            shared.set("operation", operation)
            let evaluatedAt = ProcessInfo.processInfo.systemUptime
            let commands = try #require(instance.tick()).own.videoCommands
            try #require(commands == expected)
            let vmBefore = try #require(shared.get("beforeTime") as? Double)
            let vmSame = try #require(shared.get("sameTime") as? Double)
            let vmPlaying = try #require(shared.get("samePlaying") as? Bool)
            let requestedTargets = commands.compactMap { intent -> Double? in
                if case let .seek(seconds) = intent {
                    return seconds
                }
                return nil
            }
            #expect(vmBefore == before.currentTime)
            let commitStarted = ProcessInfo.processInfo.systemUptime
            for intent in commands {
                switch intent {
                case .play: source.scriptPlay()
                case .pause: source.scriptPause()
                case let .seek(seconds): source.scriptSetCurrentTime(seconds)
                case .stop, .setRate, .setLoop:
                    Issue.record("Unexpected observation command: \(intent)")
                }
            }
            evaluations.append([
                "label": label, "evaluationStartedUptime": evaluatedAt,
                "commitStartedUptime": commitStarted,
                "commitFinishedUptime": ProcessInfo.processInfo.systemUptime,
                "publishedBeforeCurrentTime": before.currentTime,
                "sameEvaluationBeforeTime": vmBefore, "sameEvaluationCurrentTime": vmSame,
                "sameEvaluationIsPlaying": vmPlaying,
                "typedCommands": commands.map { String(describing: $0) },
                "requestedSeekTargetsSeconds": requestedTargets,
            ])
            _ = try sample(label + ".same")
        }

        func updates(_ label: String) async throws {
            for iteration in 1 ... 10 {
                _ = source.texture(at: 0)
                try await Task.sleep(for: .milliseconds(16))
                _ = try sample(label + ".u\(iteration)")
            }
        }

        try command("warm.play", operation: 1, expected: [.play])
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        let minimumWarmTime = history == "F" ? 1.6 : 0.35
        while ContinuousClock.now < deadline, source.currentPlayheadSeconds < minimumWarmTime {
            _ = source.texture(at: 0)
            try await Task.sleep(for: .milliseconds(16))
        }
        let warm = try sample("warm.qualified")
        qualification["advancingWarmSource"] = warm.currentTime >= minimumWarmTime
        try #require(warm.currentTime >= minimumWarmTime)
        try #require(warm.duration == 2)
        qualification["committedWarmSourceFrame"] = warm.hasPresentedFrame
        try #require(warm.hasPresentedFrame)
        durationQualified = true
        retained = try #require(source.texture(at: 0))
        if history == "B" {
            try command("pause.seek1_5", operation: 3, expected: [.pause, .seek(1.5)])
            try await updates("pause.seek1_5")
        } else {
            try command("pause", operation: 2, expected: [.pause])
            try await updates("pause")
        }
        let frozenBefore = try sample("pause.freeze.before")
        try await pump(source, for: .milliseconds(300))
        let paused = try sample("pause.freeze.after")
        #expect(abs(paused.currentTime - frozenBefore.currentTime) < 0.05)
        #expect(!paused.isPlaying)
        #expect(source.texture(at: 0) === retained)
        let pausedPlayhead = source.currentPlayheadSeconds
        qualification["actualPausedBeforeFirstSeparateSeek"] = paused.currentTime
        qualification["actualPausedPlayheadBeforeFirstSeparateSeek"] = pausedPlayhead
        qualification["actualPausedAboveQuarterSecond"] = pausedPlayhead > 0.25 && paused.currentTime > 0.25
        qualification["priorSeekAt1_5WithinFreezeTolerance"] = history == "B" && abs(paused.currentTime - 1.5) < 0.05
        try #require(pausedPlayhead > 0.25 && paused.currentTime > 0.25)

        let firstTarget = history == "K" ? 0.75 : 0.25
        try command("paused.seek\(firstTarget)", operation: history == "K" ? 5 : 4, expected: [.seek(firstTarget)])
        try await updates("paused.seek\(firstTarget)")
        #expect(source.texture(at: 0) === retained)
        #expect(source.scriptPlaybackSnapshot?.isPlaying == false)
        if history == "F" || history == "K" {
            try command("paused.seek0_5", operation: 6, expected: [.seek(0.5)])
            try await updates("paused.seek0_5")
            #expect(source.texture(at: 0) === retained)
            #expect(source.scriptPlaybackSnapshot?.isPlaying == false)
        }
        try command("resume.play", operation: 1, expected: [.play])
        try await updates("resume.play")
        #expect(source.scriptPlaybackSnapshot?.isPlaying == true)
        completed = true
    }
    #endif

    private func withScriptVideo(
        _ operation: (WPEVideoTextureSource) async throws -> Void
    ) async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let url = try await SyntheticVideoFixture.writeMP4(durationSeconds: 4, frameRate: 24)
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try WPEVideoTextureSource(device: device, videoURL: url)
        defer { source.invalidate() }
        try await operation(source)
    }

    private func pump(_ source: WPEVideoTextureSource, for duration: Duration) async throws {
        let deadline = ContinuousClock.now.advanced(by: duration)
        while ContinuousClock.now < deadline {
            _ = source.texture(at: 0)
            try await Task.sleep(for: .milliseconds(16))
        }
    }

    private func requireFrozenPlayhead(_ source: WPEVideoTextureSource) async throws {
        let before = source.currentPlayheadSeconds
        try await pump(source, for: .milliseconds(300))
        #expect(abs(source.currentPlayheadSeconds - before) < 0.05)
    }

    private func requirePlayheadAdvance(_ source: WPEVideoTextureSource, after position: Double) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline, source.currentPlayheadSeconds < position + 0.15 {
            _ = source.texture(at: 0)
            try await Task.sleep(for: .milliseconds(16))
        }
        #expect(source.currentPlayheadSeconds >= position + 0.15)
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
        var encoded = false
        defer {
            if !encoded {
                if writer.status == .writing {
                    writer.cancelWriting()
                }
                try? FileManager.default.removeItem(at: outputURL)
            }
        }
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
        encoded = true
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

        // helper 只在文件本身超过 cap 时才返回尺寸,所以这里用合成的 8K
        // 源尺寸单独探 clamp 数学。
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
