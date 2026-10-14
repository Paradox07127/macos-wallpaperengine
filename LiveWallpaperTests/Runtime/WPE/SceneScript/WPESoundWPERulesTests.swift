#if !LITE_BUILD
import AVFoundation
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Testing

/// WPE 2.8.42's sound layer rules, which only parity scenes opt into.
struct WPESoundWPERulesTests {
    @Test("The old renderer's rules stay the default")
    func legacyRulesAreTheDefault() throws {
        let root = try Self.makeRoot(files: ["a.wav"])
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = WPESoundRuntime(resolver: Self.resolver(root))
        defer { runtime.stop() }
        #expect(runtime.rules == .legacy)
        #expect(WPESoundPathScheduler(playbackMode: "loop", seed: 1).rules == .legacy)

        #expect(runtime.prepare(sounds: [Self.sound(paths: ["a.wav"], mode: "loop", volume: 0.5)]) == 1)
        #expect(try #require(runtime.debugTrackSnapshots().first).playerVolume == 0.5)
    }

    @Test("Loop picks every file uniformly at random, repeats allowed")
    func loopPicksRandomly() throws {
        var scheduler = WPESoundPathScheduler(playbackMode: "loop", seed: 17, rules: .wpe)
        var random = WPESoundSeededRandomNumberGenerator(seed: 17)
        var picks: [Int] = []
        var expected: [Int] = []
        for _ in 0 ..< 12 {
            let pick = try #require(scheduler.candidates(pathCount: 3).first)
            scheduler.didSchedule(index: pick, pathCount: 3)
            picks.append(pick)
            expected.append(min(Int(random.unitInterval() * 3), 2))
        }
        #expect(picks == expected)
        #expect(picks != (0 ..< 12).map { $0 % 3 })
    }

    @Test("Single plays one randomly picked file once")
    func singlePlaysOnce() throws {
        var scheduler = WPESoundPathScheduler(playbackMode: "single", seed: 5, rules: .wpe)
        var random = WPESoundSeededRandomNumberGenerator(seed: 5)
        let pick = try #require(scheduler.candidates(pathCount: 4).first)
        #expect(pick == min(Int(random.unitInterval() * 4), 3))
        scheduler.didSchedule(index: pick, pathCount: 4)
        #expect(scheduler.candidates(pathCount: 4).isEmpty)

        let root = try Self.makeRoot(files: ["a.wav", "b.wav"])
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = WPESoundRuntime(resolver: Self.resolver(root), rules: .wpe)
        defer { runtime.stop() }
        runtime.setMuted(true)
        #expect(runtime.prepare(sounds: [Self.sound(paths: ["a.wav", "b.wav"], mode: "single")]) == 1)
        #expect(try #require(runtime.debugTrackSnapshots().first).scheduledSegmentCount == 1)
    }

    @Test("Random plays at once, then waits mintime...maxtime after the file ends")
    func randomWaitsAfterTheFileEnds() throws {
        let root = try Self.makeRoot(files: ["a.wav"])
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = WPESoundRuntime(resolver: Self.resolver(root), rules: .wpe)
        defer { runtime.stop() }
        runtime.setMuted(true)
        #expect(runtime.prepare(sounds: [Self.sound(paths: ["a.wav"], mode: "random", minTime: 2, maxTime: 5)]) == 1)
        var snapshot = try #require(runtime.debugTrackSnapshots().first)
        #expect(snapshot.scheduledSegmentCount == 1, "the first play has no delay")
        #expect(snapshot.pendingDelay == nil)
        runtime.setMuted(false)
        runtime.advance(by: 100)
        #expect(try #require(runtime.debugTrackSnapshots().first).scheduledSegmentCount == 1)

        runtime.debugCompleteHeadSegment(forSoundID: "s")
        snapshot = try #require(runtime.debugTrackSnapshots().first)
        let delay = try #require(snapshot.pendingDelay)
        #expect((2 ... 5).contains(delay))
        #expect(snapshot.scheduledSegmentCount == 0)

        runtime.advance(by: delay - 0.05)
        #expect(try #require(runtime.debugTrackSnapshots().first).scheduledSegmentCount == 0)
        runtime.advance(by: 0.1)
        snapshot = try #require(runtime.debugTrackSnapshots().first)
        #expect(snapshot.scheduledSegmentCount == 1)
        #expect(snapshot.pendingDelay == nil)
    }

    @Test("Gain is volume squared times the master gain")
    func gainIsVolumeSquared() throws {
        let root = try Self.makeRoot(files: ["a.wav"])
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = WPESoundRuntime(resolver: Self.resolver(root), rules: .wpe)
        defer { runtime.stop() }
        #expect(runtime.prepare(sounds: [Self.sound(paths: ["a.wav"], mode: "loop", volume: 0.5, startSilent: true)]) == 1)
        #expect(try #require(runtime.debugTrackSnapshots().first).playerVolume == 0.25)
        runtime.setMasterVolume(0.5)
        #expect(try #require(runtime.debugTrackSnapshots().first).playerVolume == 0.125)
        runtime.setMuted(true)
        #expect(try #require(runtime.debugTrackSnapshots().first).playerVolume == 0)
    }

    @Test("Zero gain freezes the random-mode timer")
    func zeroGainFreezesTheTimer() throws {
        let root = try Self.makeRoot(files: ["a.wav"])
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = WPESoundRuntime(resolver: Self.resolver(root), rules: .wpe)
        defer { runtime.stop() }
        runtime.setMuted(true)
        #expect(runtime.prepare(sounds: [Self.sound(paths: ["a.wav"], mode: "random", minTime: 1, maxTime: 1)]) == 1)
        runtime.debugCompleteHeadSegment(forSoundID: "s")
        #expect(try #require(runtime.debugTrackSnapshots().first).pendingDelay == 1)

        runtime.advance(by: 10)
        #expect(try #require(runtime.debugTrackSnapshots().first).pendingDelay == 1, "muted")
        runtime.setMuted(false)
        runtime.setVolume(0, forSoundID: "s")
        runtime.advance(by: 10)
        #expect(try #require(runtime.debugTrackSnapshots().first).pendingDelay == 1, "zero volume")

        runtime.setVolume(1, forSoundID: "s")
        runtime.advance(by: 0.5)
        #expect(try #require(runtime.debugTrackSnapshots().first).pendingDelay == 0.5)
        runtime.advance(by: 0.5)
        let snapshot = try #require(runtime.debugTrackSnapshots().first)
        #expect(snapshot.pendingDelay == nil)
        #expect(snapshot.scheduledSegmentCount == 1)
    }

    @Test("Sub-milliscale WPE master-gain changes reach streams and the zero-gain timer gate")
    func subMilligainChangesStillReachWPEStreams() throws {
        let root = try Self.makeRoot(files: ["a.wav"])
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = WPESoundRuntime(resolver: Self.resolver(root), rules: .wpe)
        defer { runtime.stop() }
        runtime.setMuted(true)
        #expect(runtime.prepare(sounds: [Self.sound(paths: ["a.wav"], mode: "random", minTime: 1, maxTime: 1)]) == 1)
        runtime.debugCompleteHeadSegment(forSoundID: "s")
        runtime.setMasterVolume(0.0005)
        runtime.setMuted(false)
        #expect(try #require(runtime.debugTrackSnapshots().first).playerVolume == Float(0.0005))
        runtime.advance(by: 0.25)
        #expect(try #require(runtime.debugTrackSnapshots().first).pendingDelay == 0.75)

        runtime.setMasterVolume(0)
        #expect(try #require(runtime.debugTrackSnapshots().first).playerVolume == 0)
        runtime.advance(by: 10)
        #expect(try #require(runtime.debugTrackSnapshots().first).pendingDelay == 0.75)

        runtime.setMasterVolume(0.0005)
        #expect(try #require(runtime.debugTrackSnapshots().first).playerVolume == Float(0.0005))
        runtime.advance(by: 0.75)
        let resumed = try #require(runtime.debugTrackSnapshots().first)
        #expect(resumed.pendingDelay == nil)
        #expect(resumed.scheduledSegmentCount == 1)

        let legacy = WPESoundRuntime(resolver: Self.resolver(root))
        defer { legacy.stop() }
        #expect(legacy.prepare(sounds: [Self.sound(paths: ["a.wav"], mode: "loop", startSilent: true)]) == 1)
        legacy.setMasterVolume(0.0005)
        legacy.setMasterVolume(0)
        #expect(try #require(legacy.debugTrackSnapshots().first).playerVolume == Float(0.0005),
                "legacy retains its existing gain-coalescing behavior")
    }

    @Test("A random track waits for the user-resolved mintime/maxtime, not the authored default")
    func randomWaitUsesUserResolvedBounds() throws {
        let json = #"""
        {
            "camera": {"center":"0 0 0"},
            "general": {"orthogonalprojection":{"width":100,"height":100,"auto":true}},
            "objects": [
                {"id": 7, "name": "Bound", "type": "sound", "sound": ["a.wav"], "playbackmode": "random",
                 "mintime": {"user": "delay", "value": 1}, "maxtime": {"user": "delay", "value": 1}}
            ]
        }
        """#
        let document = try WPESceneDocumentParser.parse(data: Data(json.utf8), userValues: ["delay": .number(4)])
        let root = try Self.makeRoot(files: ["a.wav"])
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = WPESoundRuntime(resolver: Self.resolver(root), rules: .wpe)
        defer { runtime.stop() }
        runtime.setMuted(true)
        #expect(runtime.prepare(sounds: document.soundObjects) == 1)
        runtime.debugCompleteHeadSegment(forSoundID: "7")
        #expect(try #require(runtime.debugTrackSnapshots().first).pendingDelay == 4)
    }

    @Test("Random bounds are captured when a file starts, preserving its already selected wait")
    func changingRandomBoundsAffectsNextPlayOnly() throws {
        let root = try Self.makeRoot(files: ["a.wav"])
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = WPESoundRuntime(resolver: Self.resolver(root), rules: .wpe)
        defer { runtime.stop() }
        runtime.setMuted(true)
        #expect(runtime.prepare(sounds: [Self.sound(paths: ["a.wav"], mode: "random", minTime: 1, maxTime: 1)]) == 1)
        runtime.setRandomDelay(minTime: 2, maxTime: 2, forSoundID: "s")
        runtime.setMuted(false)
        try #require(runtime.play(), "This consumer guard requires a working audio output")
        runtime.setRandomDelay(minTime: 3, maxTime: 3, forSoundID: "s")
        runtime.debugCompleteHeadSegment(forSoundID: "s")
        #expect(try #require(runtime.debugTrackSnapshots().first).pendingDelay == 2,
                "Changing bounds during playback must not change the wait selected when it started")
        runtime.advance(by: 2)
        runtime.debugCompleteHeadSegment(forSoundID: "s")
        #expect(try #require(runtime.debugTrackSnapshots().first).pendingDelay == 3)

        // Missing fields keep the last authored/observed value rather than resetting it to zero.
        runtime.setRandomDelay(minTime: 4, maxTime: nil, forSoundID: "s")
        #expect(try #require(runtime.debugTrackSnapshots().first).pendingDelay == 3)
        runtime.advance(by: 3)
        runtime.debugCompleteHeadSegment(forSoundID: "s")
        let next = try #require(runtime.debugTrackSnapshots().first?.pendingDelay)
        #expect((3 ... 4).contains(next))
        runtime.setRandomDelay(minTime: nil, maxTime: nil, forSoundID: "missing-owner")
        #expect(try #require(runtime.debugTrackSnapshots().first).pendingDelay == next)
    }

    @Test("Master volume 0 pauses WPE playback and a later volume resumes it")
    func zeroAppVolumePausesPlayback() throws {
        let root = try Self.makeRoot(files: ["a.wav"])
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = WPESoundRuntime(resolver: Self.resolver(root), rules: .wpe)
        defer { runtime.stop() }
        #expect(runtime.prepare(sounds: [Self.sound(paths: ["a.wav"], mode: "loop")]) == 1)
        // AVAudioEngine.start() needs an output device; bail on headless hosts.
        guard runtime.play() else { return }

        runtime.setMasterVolume(0)
        #expect(!runtime.debugEngineIsRunning())
        runtime.setMasterVolume(0.5)
        #expect(runtime.debugEngineIsRunning())
        #expect(try #require(runtime.debugTrackSnapshots().first).isEnabled)
    }

    @Test("A track paused by script stays paused when the master volume returns")
    func scriptPausedTrackStaysPausedAfterVolumeReturns() throws {
        let root = try Self.makeRoot(files: ["a.wav", "b.wav"])
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = WPESoundRuntime(resolver: Self.resolver(root), rules: .wpe)
        defer { runtime.stop() }
        #expect(runtime.prepare(sounds: [
            Self.sound(id: "a", paths: ["a.wav"], mode: "loop"),
            Self.sound(id: "b", paths: ["b.wav"], mode: "loop"),
        ]) == 2)
        guard runtime.play() else { return }
        runtime.applyScriptCommand(.pause, layer: "b")

        runtime.setMasterVolume(0)
        #expect(!runtime.debugEngineIsRunning())
        runtime.setMasterVolume(0.5)
        #expect(runtime.debugEngineIsRunning())
        let tracks = Dictionary(uniqueKeysWithValues: runtime.debugTrackSnapshots().map { ($0.id, $0) })
        #expect(tracks["a"]?.isEnabled == true)
        #expect(tracks["b"]?.isEnabled == false)
    }

    @Test("The old renderer keeps the engine running at master volume 0")
    func legacyZeroAppVolumeKeepsRunning() throws {
        let root = try Self.makeRoot(files: ["a.wav"])
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = WPESoundRuntime(resolver: Self.resolver(root))
        defer { runtime.stop() }
        #expect(runtime.prepare(sounds: [Self.sound(paths: ["a.wav"], mode: "loop")]) == 1)
        guard runtime.play() else { return }

        runtime.setMasterVolume(0)
        #expect(runtime.debugEngineIsRunning())
        #expect(try #require(runtime.debugTrackSnapshots().first).playerVolume == 0)
    }

    private static func sound(id: String = "s", paths: [String], mode: String, volume: Double = 1,
                              startSilent: Bool = false, minTime: Double = 0,
                              maxTime: Double = 0) -> WPESceneSoundObject {
        WPESceneSoundObject(id: id, name: id, soundRelativePaths: paths, volume: volume, playbackMode: mode,
                            startSilent: startSilent, minTime: minTime, maxTime: maxTime)
    }

    private static func resolver(_ root: URL) -> WPEMultiRootResourceResolver {
        WPEMultiRootResourceResolver(primaryRootURL: root, dependencyMounts: [])
    }

    /// Ten-second silent files, so no real completion lands while a test drives the timer.
    private static func makeRoot(files: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPESoundWPERules-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 80000))
        buffer.frameLength = 80000
        buffer.floatChannelData?[0].update(repeating: 0, count: 80000)
        for name in files {
            let file = try AVAudioFile(forWriting: root.appendingPathComponent(name), settings: format.settings)
            try file.write(from: buffer)
        }
        return root
    }
}
#endif
