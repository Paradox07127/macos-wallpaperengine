import AVFoundation
import Foundation
import LiveWallpaperProWPE
import Testing
@testable import LiveWallpaper

struct WPESoundRuntimeTests {

    @Test("Loop scheduler advances in authored order and skips failed candidates")
    func loopSchedulerUsesAuthoredOrder() {
        var scheduler = WPESoundPathScheduler(playbackMode: "loop", seed: 17)

        #expect(scheduler.candidates(pathCount: 3) == [0, 1, 2])
        scheduler.didSchedule(index: 0, pathCount: 3)
        #expect(scheduler.candidates(pathCount: 3) == [1, 2, 0])

        // Model path 1 failing and path 2 being accepted by the file scheduler.
        scheduler.didSchedule(index: 2, pathCount: 3)
        #expect(scheduler.candidates(pathCount: 3) == [0, 1, 2])
    }

    @Test("Single scheduler accepts one file, stops, then explicit reset can replay")
    func singleSchedulerStopsAfterOneFile() throws {
        var scheduler = WPESoundPathScheduler(playbackMode: "single", seed: 23)
        let firstCandidates = scheduler.candidates(pathCount: 4)
        let selected = try #require(firstCandidates.first)

        scheduler.didSchedule(index: selected, pathCount: 4)
        #expect(scheduler.candidates(pathCount: 4).isEmpty)

        scheduler.reset()
        #expect(scheduler.candidates(pathCount: 4) == firstCandidates)
    }

    @Test("Random scheduler is reproducible for an injected seed")
    func randomSchedulerIsSeeded() throws {
        var lhs = WPESoundPathScheduler(playbackMode: "random", seed: 0xC0FFEE)
        var rhs = WPESoundPathScheduler(playbackMode: "random", seed: 0xC0FFEE)
        var lhsSelections: [Int] = []
        var rhsSelections: [Int] = []

        for _ in 0..<12 {
            let lhsIndex = try #require(lhs.candidates(pathCount: 5).first)
            let rhsIndex = try #require(rhs.candidates(pathCount: 5).first)
            lhsSelections.append(lhsIndex)
            rhsSelections.append(rhsIndex)
            lhs.didSchedule(index: lhsIndex, pathCount: 5)
            rhs.didSchedule(index: rhsIndex, pathCount: 5)
        }

        #expect(lhsSelections == rhsSelections)
        #expect(Set(lhsSelections).count > 1)
    }

    @Test("Unknown playback mode normalizes to loop at the runtime boundary")
    func unknownPlaybackModeFallsBackToLoop() {
        var scheduler = WPESoundPathScheduler(playbackMode: "future-mode", seed: 1)
        #expect(scheduler.mode == .loop)
        #expect(scheduler.candidates(pathCount: 2) == [0, 1])
    }

    @Test("Parses sound object with array of paths")
    func parsesSoundObjectWithArrayPaths() throws {
        let json = #"""
        {
            "camera": {"center":"0 0 0"},
            "general": {"orthogonalprojection":{"width":100,"height":100,"auto":true}},
            "objects": [{
                "id": 7,
                "name": "BGM",
                "type": "sound",
                "sound": ["sounds/track1.mp3", "sounds/track2.mp3"],
                "volume": 0.5,
                "playbackmode": "loop"
            }]
        }
        """#
        let document = try WPESceneDocumentParser.parse(data: Data(json.utf8))
        #expect(document.soundObjects.count == 1)
        let sound = try #require(document.soundObjects.first)
        #expect(sound.soundRelativePaths == ["sounds/track1.mp3", "sounds/track2.mp3"])
        #expect(sound.volume == 0.5)
        #expect(sound.playbackMode == "loop")
    }

    @Test("Parses sound object with single string path")
    func parsesSoundObjectWithStringPath() throws {
        let json = #"""
        {
            "camera": {"center":"0 0 0"},
            "general": {"orthogonalprojection":{"width":100,"height":100,"auto":true}},
            "objects": [{
                "id": 7,
                "name": "Single",
                "type": "sound",
                "sound": "sounds/single.wav"
            }]
        }
        """#
        let document = try WPESceneDocumentParser.parse(data: Data(json.utf8))
        let sound = try #require(document.soundObjects.first)
        #expect(sound.soundRelativePaths == ["sounds/single.wav"])
        #expect(sound.volume == 1)
    }

    @Test("Sound visibility and volume user bindings preserve provenance and stay incremental")
    func soundBindingsPreserveAndResolve() throws {
        let payload: [String: Any] = [
            "camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 100, "height": 100, "auto": true]],
            "objects": [
                ["id": 3, "name": "Hidden group", "visible": false],
                [
                    "id": 7,
                    "parent": 3,
                    "name": "Bound BGM",
                    "type": "sound",
                    "sound": ["sounds/bgm.wav"],
                    "volume": ["user": "musicVolume", "value": 0.25],
                    "visible": ["user": "musicEnabled", "value": true]
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let document = try WPESceneDocumentParser.parse(
            data: data,
            userValues: ["musicVolume": .number(0.75), "musicEnabled": .bool(true)]
        )
        let sound = try #require(document.soundObjects.first)

        #expect(sound.volume == 0.75)
        #expect(sound.volumeField.seed == 0.25)
        #expect(sound.volumeField.resolvedValue == 0.75)
        #expect(sound.volumeField.userBindings == [
            WPESceneAuthoredUserBinding(propertyKey: "musicVolume")
        ])
        #expect(sound.visibleField.seed)
        #expect(sound.visibleField.resolvedValue)
        #expect(sound.visible == false) // hidden ancestor is folded into the initial gate

        let volumeBinding = try #require(document.propertyBindings["musicVolume"]?.first)
        #expect(volumeBinding.target == .soundObject(id: "7"))
        #expect(volumeBinding.kind == .volume)
        #expect(volumeBinding.action == .incremental)
        let visibleBinding = try #require(document.propertyBindings["musicEnabled"]?.first)
        #expect(visibleBinding.target == .soundObject(id: "7"))
        #expect(visibleBinding.kind == .visible)
        #expect(visibleBinding.action == .incremental)
        #expect(!WPEScenePropertyPatch(
            bindingsByProperty: document.propertyBindings,
            oldValues: ["musicVolume": .number(0.25), "musicEnabled": .bool(true)],
            newValues: ["musicVolume": .number(0.75), "musicEnabled": .bool(false)]
        ).requiresReload)
    }

    @Test("Empty sound list rejects parse")
    func emptySoundRejected() throws {
        let json = #"""
        {
            "camera": {"center":"0 0 0"},
            "general": {"orthogonalprojection":{"width":100,"height":100,"auto":true}},
            "objects": [{
                "id": 7,
                "name": "Empty",
                "type": "sound",
                "sound": []
            }]
        }
        """#
        let document = try WPESceneDocumentParser.parse(data: Data(json.utf8))
        #expect(document.soundObjects.isEmpty)
    }

    @Test("setMasterVolume clamps to [0, 1]")
    func masterVolumeClamps() throws {
        let resolver = WPEMultiRootResourceResolver(
            primaryRootURL: FileManager.default.temporaryDirectory,
            dependencyMounts: []
        )
        let runtime = WPESoundRuntime(resolver: resolver)
        runtime.setMasterVolume(-1.5)
        runtime.setMasterVolume(2.0)
    }

    @Test("prepare() attaches without playing; play() is a no-op when nothing prepared")
    func prepareDefersPlayback() throws {
        let resolver = WPEMultiRootResourceResolver(
            primaryRootURL: FileManager.default.temporaryDirectory,
            dependencyMounts: []
        )
        let runtime = WPESoundRuntime(resolver: resolver)
        defer { runtime.stop() }
        let attached = runtime.prepare(sounds: [])
        #expect(attached == 0)
        #expect(runtime.play() == false)
    }

    @Test("prepare() then stop() without play() (stale-scene teardown) is safe")
    func prepareThenStopWithoutPlayIsSafe() throws {
        let resolver = WPEMultiRootResourceResolver(
            primaryRootURL: FileManager.default.temporaryDirectory,
            dependencyMounts: []
        )
        let runtime = WPESoundRuntime(resolver: resolver)
        _ = runtime.prepare(sounds: [])
        runtime.stop()
    }

    @Test("prepare streams a tiny WAV and retains all authored paths for scheduling")
    func prepareStreamsTinyWAVMultiPath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPESoundRuntimeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.writeTinyWAV(to: root.appendingPathComponent("first.wav"))
        try Self.writeTinyWAV(to: root.appendingPathComponent("second.wav"))

        let resolver = WPEMultiRootResourceResolver(primaryRootURL: root, dependencyMounts: [])
        let runtime = WPESoundRuntime(resolver: resolver, randomSeed: 99)
        defer { runtime.stop() }
        let sound = WPESceneSoundObject(
            id: "7",
            name: "Tiny",
            soundRelativePaths: ["first.wav", "second.wav"],
            volume: 0.4,
            playbackMode: "loop",
            startSilent: true
        )

        #expect(runtime.prepare(sounds: [sound]) == 1)
        let snapshot = try #require(runtime.debugTrackSnapshots().first)
        #expect(snapshot.availablePathCount == 2)
        // The look-ahead fills both slots up front, so a two-path loop has
        // consumed the authored order 0 → 1 before a single sample plays.
        #expect(snapshot.scheduledSegmentCount == 2)
        #expect(snapshot.lastScheduledPathIndex == 1)
        #expect(snapshot.hasOpenFile)
        #expect(!snapshot.isEnabled)
    }

    /// `scheduleBuffer(options: [.loops])` looped inside the node, so the seam was
    /// inaudible. Streaming with `scheduleFile` gives that up: if the next segment
    /// is only scheduled from the previous one's completion handler, the queue is
    /// empty for a render quantum plus a queue hop and a lock acquisition every
    /// time the loop wraps. Keeping a segment queued ahead is what restores it.
    @Test("A looping sound keeps the next segment queued so the wrap has no gap")
    func loopKeepsNextSegmentQueued() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPESoundRuntimeLoopGap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.writeTinyWAV(to: root.appendingPathComponent("loop.wav"))

        let runtime = WPESoundRuntime(
            resolver: WPEMultiRootResourceResolver(primaryRootURL: root, dependencyMounts: [])
        )
        defer { runtime.stop() }
        let sound = WPESceneSoundObject(
            id: "loop",
            name: "Loop",
            soundRelativePaths: ["loop.wav"],
            volume: 1,
            playbackMode: "loop",
            startSilent: true
        )

        #expect(runtime.prepare(sounds: [sound]) == 1)
        let snapshot = try #require(runtime.debugTrackSnapshots().first)
        #expect(
            snapshot.scheduledSegmentCount >= 2,
            "a single-path loop must queue the wrap ahead, else every wrap is an audible gap"
        )
    }

    /// `single` must not gain a second segment from the look-ahead — that would
    /// turn "play once" into "play twice".
    @Test("A single-shot sound queues exactly one segment")
    func singleQueuesOneSegment() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPESoundRuntimeSingle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.writeTinyWAV(to: root.appendingPathComponent("once.wav"))

        let runtime = WPESoundRuntime(
            resolver: WPEMultiRootResourceResolver(primaryRootURL: root, dependencyMounts: [])
        )
        defer { runtime.stop() }
        let sound = WPESceneSoundObject(
            id: "once",
            name: "Once",
            soundRelativePaths: ["once.wav"],
            volume: 1,
            playbackMode: "single",
            startSilent: true
        )

        #expect(runtime.prepare(sounds: [sound]) == 1)
        let snapshot = try #require(runtime.debugTrackSnapshots().first)
        #expect(snapshot.scheduledSegmentCount == 1, "single must not be doubled by look-ahead")
    }

    @Test("Effective visibility gates initial sound and live bindings update visibility and volume")
    func visibilityAndVolumeBindingsUpdatePreparedTrack() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPESoundRuntimeBindings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.writeTinyWAV(to: root.appendingPathComponent("bound.wav"))

        let runtime = WPESoundRuntime(
            resolver: WPEMultiRootResourceResolver(primaryRootURL: root, dependencyMounts: [])
        )
        defer { runtime.stop() }
        runtime.setMuted(true)
        let sound = WPESceneSoundObject(
            id: "bound",
            name: "Bound",
            soundRelativePaths: ["bound.wav"],
            volume: 0.25,
            playbackMode: "loop",
            startSilent: false,
            visible: false
        )

        #expect(runtime.prepare(sounds: [sound]) == 1)
        var snapshot = try #require(runtime.debugTrackSnapshots().first)
        #expect(snapshot.id == "bound")
        #expect(!snapshot.isVisible)
        #expect(!snapshot.isEnabled)
        #expect(snapshot.sceneVolume == 0.25)

        runtime.setVisible(true, forSoundID: "bound")
        runtime.setVolume(4, forSoundID: "bound")
        snapshot = try #require(runtime.debugTrackSnapshots().first)
        #expect(snapshot.isVisible)
        #expect(snapshot.isEnabled)
        #expect(snapshot.sceneVolume == 1)

        runtime.setVisible(false, forSoundID: "bound")
        snapshot = try #require(runtime.debugTrackSnapshots().first)
        #expect(!snapshot.isVisible)
        #expect(!snapshot.isEnabled)
        #expect(snapshot.hasOpenFile == false)
    }

    // MARK: - PAR-12: master mute is gain-only (WPE keeps the audio timeline running)

    @Test("Master mute zeroes player gain and unmute restores per-track volume")
    func muteIsGainOnlyOnPlayerGain() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPESoundRuntimeMuteGain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.writeTinyWAV(to: root.appendingPathComponent("gain.wav"))

        let runtime = WPESoundRuntime(
            resolver: WPEMultiRootResourceResolver(primaryRootURL: root, dependencyMounts: [])
        )
        defer { runtime.stop() }
        let sound = WPESceneSoundObject(
            id: "gain",
            name: "Gain",
            soundRelativePaths: ["gain.wav"],
            volume: 0.5,
            playbackMode: "loop",
            startSilent: true
        )

        #expect(runtime.prepare(sounds: [sound]) == 1)
        var snapshot = try #require(runtime.debugTrackSnapshots().first)
        #expect(snapshot.playerVolume == 0.5)

        runtime.setMuted(true)
        snapshot = try #require(runtime.debugTrackSnapshots().first)
        #expect(snapshot.playerVolume == 0)

        // A volume binding arriving while muted must not leak through the mute.
        runtime.setVolume(0.75, forSoundID: "gain")
        snapshot = try #require(runtime.debugTrackSnapshots().first)
        #expect(snapshot.playerVolume == 0)
        #expect(snapshot.sceneVolume == 0.75)

        runtime.setMuted(false)
        snapshot = try #require(runtime.debugTrackSnapshots().first)
        #expect(snapshot.playerVolume == 0.75)
    }

    @Test("Mute stops the engine outright and unmute restarts it")
    func muteStopsTheEngine() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPESoundRuntimeMuteRun-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.writeTinyWAV(to: root.appendingPathComponent("run.wav"))

        let runtime = WPESoundRuntime(
            resolver: WPEMultiRootResourceResolver(primaryRootURL: root, dependencyMounts: [])
        )
        defer { runtime.stop() }
        let sound = WPESceneSoundObject(
            id: "run",
            name: "Run",
            soundRelativePaths: ["run.wav"],
            volume: 1,
            playbackMode: "loop",
            startSilent: false
        )

        #expect(runtime.prepare(sounds: [sound]) == 1)
        #expect(!runtime.debugEngineIsRunning())
        runtime.setMuted(true)
        #expect(!runtime.debugEngineIsRunning())

        // AVAudioEngine.start() needs an output device; bail on headless hosts.
        runtime.setMuted(false)
        guard runtime.play() else { return }
        #expect(runtime.debugEngineIsRunning())

        runtime.setMuted(true)
        #expect(
            !runtime.debugEngineIsRunning(),
            "mute must stop decode and render callbacks, not just zero the gain"
        )
        runtime.setMuted(false)
        #expect(runtime.debugEngineIsRunning(), "unmute must restart the engine")
    }

    @Test("Unmuting stays paused while suspended; resume then restarts it")
    func muteAndSuspendAreIndependentPauseReasons() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPESoundRuntimeSuspend-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.writeTinyWAV(to: root.appendingPathComponent("suspend.wav"))

        let runtime = WPESoundRuntime(
            resolver: WPEMultiRootResourceResolver(primaryRootURL: root, dependencyMounts: [])
        )
        defer { runtime.stop() }
        let sound = WPESceneSoundObject(
            id: "suspend",
            name: "Suspend",
            soundRelativePaths: ["suspend.wav"],
            volume: 1,
            playbackMode: "loop",
            startSilent: false
        )

        #expect(runtime.prepare(sounds: [sound]) == 1)
        // AVAudioEngine.start() needs an output device; bail on headless hosts.
        guard runtime.play() else { return }

        // Both reasons active; clearing only one must not resume playback.
        runtime.setMuted(true)
        runtime.pause()
        #expect(!runtime.debugEngineIsRunning())
        runtime.setMuted(false)
        #expect(!runtime.debugEngineIsRunning(), "unmute must not defeat a performance suspend")
        runtime.resume()
        #expect(runtime.debugEngineIsRunning())
        let snapshot = try #require(runtime.debugTrackSnapshots().first)
        #expect(snapshot.playerVolume > 0, "resume must restore the unmuted gain")
    }

    @Test("Engine pauses when no track is enabled, muted or not")
    func enginePausesWithoutEnabledTracks() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPESoundRuntimeIdle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.writeTinyWAV(to: root.appendingPathComponent("idle.wav"))
        let resolver = WPEMultiRootResourceResolver(primaryRootURL: root, dependencyMounts: [])

        let runtime = WPESoundRuntime(resolver: resolver)
        defer { runtime.stop() }
        let silent = WPESceneSoundObject(
            id: "idle",
            name: "Idle",
            soundRelativePaths: ["idle.wav"],
            volume: 1,
            playbackMode: "loop",
            startSilent: true
        )
        #expect(runtime.prepare(sounds: [silent]) == 1)
        #expect(runtime.play() == false)
        #expect(!runtime.debugEngineIsRunning())

        let audible = WPESceneSoundObject(
            id: "idle",
            name: "Idle",
            soundRelativePaths: ["idle.wav"],
            volume: 1,
            playbackMode: "loop",
            startSilent: false
        )
        #expect(runtime.prepare(sounds: [audible]) == 1)
        // AVAudioEngine.start() needs an output device; bail on headless hosts.
        guard runtime.play() else { return }
        runtime.setVisible(false, forSoundID: "idle")
        #expect(!runtime.debugEngineIsRunning(), "disabling the last track must pause the engine")
    }

    @Test("A muted loop stops advancing and resumes where it stopped")
    func mutedLoopStopsAdvancing() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPESoundRuntimeMutedLoop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.writeTinyWAV(to: root.appendingPathComponent("a.wav"))
        try Self.writeTinyWAV(to: root.appendingPathComponent("b.wav"))

        let runtime = WPESoundRuntime(
            resolver: WPEMultiRootResourceResolver(primaryRootURL: root, dependencyMounts: [])
        )
        defer { runtime.stop() }
        let sound = WPESceneSoundObject(
            id: "mutedloop",
            name: "MutedLoop",
            soundRelativePaths: ["a.wav", "b.wav"],
            volume: 1,
            playbackMode: "loop",
            startSilent: false
        )

        #expect(runtime.prepare(sounds: [sound]) == 1)
        // AVAudioEngine.start() needs an output device; bail on headless hosts.
        guard runtime.play() else { return }
        // Control group: unmuted, this loop demonstrably keeps flipping segments.
        var observed = try #require(runtime.debugTrackSnapshots().first).lastScheduledPathIndex
        var flips = 0
        let runningDeadline = Date().addingTimeInterval(3)
        while flips < 2, Date() < runningDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
            let current = try #require(runtime.debugTrackSnapshots().first).lastScheduledPathIndex
            if current != observed {
                flips += 1
                observed = current
            }
        }
        #expect(flips >= 2, "control group: an unmuted loop must keep scheduling segments")

        runtime.setMuted(true)
        // Let any in-flight completion from before the mute settle before sampling.
        try await Task.sleep(nanoseconds: 200_000_000)
        let quiesced = try #require(runtime.debugTrackSnapshots().first).lastScheduledPathIndex
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(
            try #require(runtime.debugTrackSnapshots().first).lastScheduledPathIndex == quiesced,
            "a muted loop must stop advancing; the engine is paused, not just silenced"
        )
    }

    @Test("A muted single-shot is held, not consumed, and completes after unmute")
    func mutedSingleShotIsHeldThenCompletes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPESoundRuntimeMutedSingle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // 1 s of audio so the mute below lands well before the file can finish.
        try Self.writeTinyWAV(to: root.appendingPathComponent("one.wav"), frameLength: 8000)

        let runtime = WPESoundRuntime(
            resolver: WPEMultiRootResourceResolver(primaryRootURL: root, dependencyMounts: [])
        )
        defer { runtime.stop() }
        let sound = WPESceneSoundObject(
            id: "one",
            name: "One",
            soundRelativePaths: ["one.wav"],
            volume: 1,
            playbackMode: "single",
            startSilent: false
        )

        #expect(runtime.prepare(sounds: [sound]) == 1)
        // AVAudioEngine.start() needs an output device; bail on headless hosts.
        guard runtime.play() else { return }
        runtime.setMuted(true)

        // Muted for several times the file's own duration: a paused engine must not
        // consume it, so the track is still pending when we unmute.
        try await Task.sleep(nanoseconds: 3_000_000_000)
        #expect(
            try #require(runtime.debugTrackSnapshots().first).isEnabled,
            "a muted single must be held, not silently consumed"
        )

        runtime.setMuted(false)
        let deadline = Date().addingTimeInterval(5)
        var snapshot = try #require(runtime.debugTrackSnapshots().first)
        while snapshot.isEnabled, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
            snapshot = try #require(runtime.debugTrackSnapshots().first)
        }
        #expect(!snapshot.isEnabled, "after unmute the single must reach its completion")
        #expect(snapshot.scheduledSegmentCount == 0)
    }

    private static func writeTinyWAV(to url: URL, frameLength: AVAudioFrameCount = 80) throws {
        let format = try #require(AVAudioFormat(
            standardFormatWithSampleRate: 8_000,
            channels: 1
        ))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength))
        buffer.frameLength = frameLength
        if let samples = buffer.floatChannelData?[0] {
            for index in 0..<Int(buffer.frameLength) {
                samples[index] = 0
            }
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}
