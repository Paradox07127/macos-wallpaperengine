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
        #expect(runtime.prepare(sounds: [Self.sound(paths: ["a.wav"], mode: "random")],
                                randomDelays: ["s": (minTime: 2, maxTime: 5)]) == 1)
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
        #expect(runtime.prepare(sounds: [Self.sound(paths: ["a.wav"], mode: "random")],
                                randomDelays: ["s": (minTime: 1, maxTime: 1)]) == 1)
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

    @Test("mintime and maxtime are read from the authored sound objects")
    func authoredRandomDelays() throws {
        let json = #"""
        {
            "camera": {"center":"0 0 0"},
            "general": {"orthogonalprojection":{"width":100,"height":100,"auto":true}},
            "objects": [
                {"id": 7, "name": "Plain", "type": "sound", "sound": ["a.wav"], "playbackmode": "random",
                 "mintime": 3, "maxtime": 7},
                {"id": 8, "name": "Bound", "type": "sound", "sound": ["b.wav"], "playbackmode": "random",
                 "mintime": {"user": "lo", "value": 1.5}, "maxtime": 2.5},
                {"id": 9, "name": "Unset", "type": "sound", "sound": ["c.wav"]}
            ]
        }
        """#
        let document = try WPESceneDocumentParser.parse(data: Data(json.utf8))
        let delays = WPESoundRuntime.authoredRandomDelays(in: document)
        #expect(delays["7"]?.minTime == 3)
        #expect(delays["7"]?.maxTime == 7)
        #expect(delays["8"]?.minTime == 1.5)
        #expect(delays["8"]?.maxTime == 2.5)
        #expect(delays["9"]?.minTime == 0)
        #expect(delays["9"]?.maxTime == 0)
    }

    private static func sound(paths: [String], mode: String, volume: Double = 1,
                              startSilent: Bool = false) -> WPESceneSoundObject {
        WPESceneSoundObject(id: "s", name: "S", soundRelativePaths: paths, volume: volume, playbackMode: mode,
                            startSilent: startSilent)
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
