#if !LITE_BUILD
import AVFoundation
import Foundation
import LiveWallpaperCore
import LiveWallpaperProWPE
import os

/// Unknown authored values fall back to `loop` at the consumption boundary.
enum WPESoundPlaybackMode: String, Equatable, Sendable {
    case loop
    case random
    case single

    init(authoredValue: String) {
        self = Self(rawValue: authoredValue.lowercased()) ?? .loop
    }
}

struct WPESoundSeededRandomNumberGenerator: RandomNumberGenerator, Equatable, Sendable {
    private(set) var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        // SplitMix64: compact, deterministic and sufficient for path selection.
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    mutating func index(upperBound: Int) -> Int {
        precondition(upperBound > 0)
        return Int(next() % UInt64(upperBound))
    }

    /// Uniform in [0, 1).
    mutating func unitInterval() -> Double {
        Double(next() >> 11) * 0x1p-53
    }
}

/// `legacy` is the old renderer's behaviour; `wpe` is WPE 2.8.42's (random pick per play, random-mode delays,
/// volume² gain), used by parity scenes.
enum WPESoundPlaybackRules: Equatable, Sendable {
    case legacy
    case wpe
}

struct WPESoundPathScheduler: Equatable, Sendable {
    let mode: WPESoundPlaybackMode
    let rules: WPESoundPlaybackRules
    private let initialSeed: UInt64
    private var random: WPESoundSeededRandomNumberGenerator
    private var loopCursor = 0
    private var singleDidSchedule = false

    init(playbackMode: String, seed: UInt64, rules: WPESoundPlaybackRules = .legacy) {
        mode = WPESoundPlaybackMode(authoredValue: playbackMode)
        self.rules = rules
        initialSeed = seed
        random = WPESoundSeededRandomNumberGenerator(seed: seed)
    }

    mutating func candidates(pathCount: Int) -> [Int] {
        guard pathCount > 0 else { return [] }
        if mode == .single, singleDidSchedule {
            return []
        }

        let startIndex: Int = switch (rules, mode) {
        case (.wpe, _):
            min(Int(random.unitInterval() * Double(pathCount)), pathCount - 1)
        case (.legacy, .loop):
            loopCursor % pathCount
        case (.legacy, .random), (.legacy, .single):
            // random and single both pick a random start; a fixed seed keeps that choice deterministic.
            random.index(upperBound: pathCount)
        }
        return (0 ..< pathCount).map { (startIndex + $0) % pathCount }
    }

    /// WPE random mode's wait after a file ends: mintime + U × (maxtime − mintime).
    mutating func randomDelay(minTime: Double, maxTime: Double) -> Double {
        minTime + random.unitInterval() * (maxTime - minTime)
    }

    mutating func didSchedule(index: Int, pathCount: Int) {
        guard pathCount > 0 else { return }
        switch mode {
        case .loop:
            loopCursor = (index + 1) % pathCount
        case .random:
            break
        case .single:
            singleDidSchedule = true
        }
    }

    mutating func reset() {
        loopCursor = 0
        singleDidSchedule = false
        random = WPESoundSeededRandomNumberGenerator(seed: initialSeed)
    }
}

struct WPESoundRuntimeDebugTrackSnapshot: Equatable, Sendable {
    let id: String
    let availablePathCount: Int
    let lastScheduledPathIndex: Int?
    let hasOpenFile: Bool
    /// Queued segments on the player node; a loop needs more than one for gapless playback.
    let scheduledSegmentCount: Int
    let isEnabled: Bool
    let isVisible: Bool
    let sceneVolume: Float
    /// The gain actually applied on the player node (scene × master, 0 when muted).
    let playerVolume: Float
    /// Seconds left before a WPE random-mode track plays again; nil when it is not waiting.
    let pendingDelay: Double?
}

final class WPESoundRuntime: Sendable {
    typealias SchedulerFactory = @Sendable (_ playbackMode: String, _ seed: UInt64) -> WPESoundPathScheduler

    private struct Track {
        let token: UInt64
        let id: String
        let player: AVAudioPlayerNode
        let relativePaths: [String]
        let urls: [URL]
        var scheduler: WPESoundPathScheduler
        /// In-flight segments: files must outlive the node's read; look-ahead depth is observable.
        var scheduledFiles: [AVAudioFile]
        var lastScheduledPathIndex: Int?
        var sceneVolume: Float
        let name: String
        var visible: Bool
        var enabled: Bool
        var needsReschedule: Bool
        /// Bumped only on teardown, not per-segment: look-ahead has several in-flight completions.
        var epoch: UInt64
        let randomDelay: (minTime: Double, maxTime: Double)
        /// Seconds left of a WPE random-mode wait; the next file is scheduled only once it runs out.
        var delayRemaining: Double?

        var waitsBetweenPlays: Bool {
            scheduler.rules == .wpe && scheduler.mode == .random
        }

        /// Two queued segments is the minimum for a seamless loop (no completion/queue/lock round trip).
        var scheduleDepth: Int {
            waitsBetweenPlays ? 1 : 2
        }
    }

    /// Unchecked because AVAudioEngine/AVAudioPlayerNode/AVAudioFile carry no Sendable
    /// conformance under the shipping 26.6 toolchain. The mechanism is the
    /// `OSAllocatedUnfairLock` below: every read and write happens inside `state.withLock`, so
    /// the AVFoundation objects are only ever touched by one thread at a time.
    private struct State: @unchecked Sendable {
        let engine = AVAudioEngine()
        var tracks: [Track] = []
        var masterVolume: Float = 1
        var isMuted = false
        var isSuspended = false
        var nextToken: UInt64 = 1
        var renderedCompletionCount = 0
    }

    private struct ResolvedSound {
        let id: String
        let name: String
        let relativePaths: [String]
        let urls: [URL]
        let volume: Float
        let playbackMode: String
        let startSilent: Bool
        let visible: Bool
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let resolver: WPEMultiRootResourceResolver
    private let randomSeed: UInt64
    let rules: WPESoundPlaybackRules
    private let schedulerFactory: SchedulerFactory
    private let completionQueue = DispatchQueue(label: "com.loomscreen.wpe-sound-completion")

    init(
        resolver: WPEMultiRootResourceResolver,
        randomSeed: UInt64 = 0x5750_4553_4F55_4E44,
        rules: WPESoundPlaybackRules = .legacy,
        schedulerFactory: SchedulerFactory? = nil
    ) {
        self.resolver = resolver
        self.randomSeed = randomSeed
        self.rules = rules
        self.schedulerFactory = schedulerFactory ?? { playbackMode, seed in
            WPESoundPathScheduler(playbackMode: playbackMode, seed: seed, rules: rules)
        }
    }

    /// `mintime`/`maxtime` per sound id, read from the authored objects because the parsed sound object omits them.
    static func authoredRandomDelays(in document: WPESceneDocument) -> [String: (minTime: Double, maxTime: Double)] {
        guard case let .array(objects) = document.sourceJSON["objects"] else { return [:] }
        let authored = objects.filter {
            if case .object = $0 {
                true
            } else {
                false
            }
        }
        func seconds(_ value: WPESceneJSONValue?) -> Double {
            switch value {
            case let .number(number): number
            case let .object(fields): seconds(fields["value"])
            default: 0
            }
        }
        var delays: [String: (minTime: Double, maxTime: Double)] = [:]
        for sound in document.soundObjects {
            guard let index = document.objectPaintOrder[sound.id], authored.indices.contains(index) else { continue }
            delays[sound.id] = (seconds(authored[index]["mintime"]), seconds(authored[index]["maxtime"]))
        }
        return delays
    }

    /// `scheduleFile` streams long assets; it does not allocate a PCM buffer of the whole file.
    @discardableResult
    func prepare(sounds: [WPESceneSoundObject],
                 randomDelays: [String: (minTime: Double, maxTime: Double)] = [:]) -> Int {
        let resolvedSounds = sounds.compactMap { sound -> ResolvedSound? in
            var relativePaths: [String] = []
            var urls: [URL] = []
            for path in sound.soundRelativePaths {
                guard let url = try? resolver.resolveExistingFileURL(relativePath: path) else { continue }
                relativePaths.append(path)
                urls.append(url)
            }
            guard !urls.isEmpty else { return nil }
            return ResolvedSound(
                id: sound.id,
                name: sound.name,
                relativePaths: relativePaths,
                urls: urls,
                volume: Float(sound.volume),
                playbackMode: sound.playbackMode,
                startSilent: sound.startSilent,
                visible: sound.visible
            )
        }

        return state.withLock { state in
            Self.stopAndDetachAll(in: &state)
            let mainMixer = state.engine.mainMixerNode

            for (soundIndex, sound) in resolvedSounds.enumerated() {
                let player = AVAudioPlayerNode()
                state.engine.attach(player)
                // A nil format lets AVAudioEngine accept authored files with
                // differing sample rates/channel layouts on one player node.
                state.engine.connect(player, to: mainMixer, format: nil)

                let token = state.nextToken
                state.nextToken &+= 1
                let trackSeed = Self.derivedSeed(base: randomSeed, index: soundIndex)
                let sceneVolume = max(0, min(1, sound.volume))
                player.volume = effectiveVolume(
                    sceneVolume: sceneVolume,
                    appVolume: state.masterVolume,
                    isMuted: state.isMuted
                )
                state.tracks.append(Track(
                    token: token,
                    id: sound.id,
                    player: player,
                    relativePaths: sound.relativePaths,
                    urls: sound.urls,
                    scheduler: schedulerFactory(sound.playbackMode, trackSeed),
                    scheduledFiles: [],
                    lastScheduledPathIndex: nil,
                    sceneVolume: sceneVolume,
                    name: sound.name,
                    visible: sound.visible,
                    enabled: sound.visible && !sound.startSilent,
                    needsReschedule: true,
                    epoch: 0,
                    randomDelay: randomDelays[sound.id] ?? (minTime: 0, maxTime: 0),
                    delayRemaining: nil
                ))

                let index = state.tracks.count - 1
                guard fillSchedule(in: &state, trackIndex: index) else {
                    let failedTrack = state.tracks.removeLast()
                    failedTrack.player.stop()
                    state.engine.detach(failedTrack.player)
                    continue
                }
            }

            state.engine.prepare()
            return state.tracks.count
        }
    }

    @discardableResult
    func play() -> Bool {
        state.withLock { state in
            reconcileEngineRunState(state: &state)
            return state.engine.isRunning
        }
    }

    func stop() {
        state.withLock { state in
            Self.stopAndDetachAll(in: &state)
        }
    }

    func applyScriptCommand(_ command: WPELayerSoundCommand, layer: String) {
        state.withLock { state in
            guard let index = state.tracks.firstIndex(where: { $0.name == layer }) else { return }
            let player = state.tracks[index].player
            switch command {
            case .play:
                state.tracks[index].enabled = true
                reconcileEngineRunState(state: &state)
            case .stop:
                Self.stopTrack(at: index, state: &state)
                reconcileEngineRunState(state: &state)
            case .pause:
                state.tracks[index].enabled = false
                player.pause()
                reconcileEngineRunState(state: &state)
            case let .setVolume(volume):
                state.tracks[index].sceneVolume = Float(min(max(volume, 0), 1))
                applyAudioState(to: &state)
            }
        }
    }

    /// Visibility Play/Stops the sound; `startSilent` is initial state only and does not veto a later toggle.
    func setVisible(_ visible: Bool, forSoundID id: String) {
        state.withLock { state in
            guard let index = state.tracks.firstIndex(where: { $0.id == id }),
                  state.tracks[index].visible != visible else { return }
            state.tracks[index].visible = visible
            if visible {
                state.tracks[index].enabled = true
            } else {
                Self.stopTrack(at: index, state: &state)
            }
            reconcileEngineRunState(state: &state)
        }
    }

    /// Applies a project-property sound-volume binding. This is the authored
    /// per-sound control and remains multiplied by the app master volume/mute.
    func setVolume(_ volume: Double, forSoundID id: String) {
        state.withLock { state in
            guard let index = state.tracks.firstIndex(where: { $0.id == id }) else { return }
            state.tracks[index].sceneVolume = Float(min(max(volume, 0), 1))
            applyAudioState(to: &state)
        }
    }

    /// Performance suspend: pause engine, retain scheduled files for resume.
    func pause() {
        state.withLock { state in
            state.isSuspended = true
            reconcileEngineRunState(state: &state)
        }
    }

    func resume() {
        state.withLock { state in
            state.isSuspended = false
            reconcileEngineRunState(state: &state)
        }
    }

    func setMuted(_ muted: Bool) {
        state.withLock { state in
            guard state.isMuted != muted else { return }
            state.isMuted = muted
            applyAudioState(to: &state)
            reconcileEngineRunState(state: &state)
        }
    }

    func setMasterVolume(_ volume: Double) {
        state.withLock { state in
            let clamped = Float(min(max(volume, 0), 1))
            guard abs(state.masterVolume - clamped) > 0.001 else { return }
            state.masterVolume = clamped
            applyAudioState(to: &state)
        }
    }

    /// Counts WPE random-mode waits down by `seconds` of frame time; a wait only runs while its track is audible.
    func advance(by seconds: Double) {
        state.withLock { state in
            guard !state.isSuspended else { return }
            var expired = false
            for index in state.tracks.indices where state.tracks[index].enabled {
                guard let remaining = state.tracks[index].delayRemaining,
                      effectiveVolume(sceneVolume: state.tracks[index].sceneVolume,
                                      appVolume: state.masterVolume, isMuted: state.isMuted) > 0 else { continue }
                if remaining > seconds {
                    state.tracks[index].delayRemaining = remaining - seconds
                } else {
                    state.tracks[index].delayRemaining = nil
                    expired = true
                }
            }
            if expired {
                reconcileEngineRunState(state: &state)
            }
        }
    }

    #if DEBUG
    func debugTrackSnapshots() -> [WPESoundRuntimeDebugTrackSnapshot] {
        state.withLock { state in
            state.tracks.map {
                WPESoundRuntimeDebugTrackSnapshot(
                    id: $0.id,
                    availablePathCount: $0.urls.count,
                    lastScheduledPathIndex: $0.lastScheduledPathIndex,
                    hasOpenFile: !$0.scheduledFiles.isEmpty,
                    scheduledSegmentCount: $0.scheduledFiles.count,
                    isEnabled: $0.enabled,
                    isVisible: $0.visible,
                    sceneVolume: $0.sceneVolume,
                    playerVolume: $0.player.volume,
                    pendingDelay: $0.delayRemaining
                )
            }
        }
    }

    /// Runs the completion path for the track's oldest queued segment, as if it had finished playing.
    func debugCompleteHeadSegment(forSoundID id: String) {
        let key = state.withLock { state in
            state.tracks.first { $0.id == id }.map { (token: $0.token, epoch: $0.epoch) }
        }
        guard let key else { return }
        handleScheduledFileCompletion(token: key.token, epoch: key.epoch)
    }

    func debugEngineIsRunning() -> Bool {
        state.withLock { $0.engine.isRunning }
    }

    func debugRenderedCompletionCount() -> Int {
        state.withLock { $0.renderedCompletionCount }
    }
    #endif

    private func reconcileEngineRunState(state: inout State) {
        guard !state.tracks.isEmpty else { return }

        for index in state.tracks.indices where state.tracks[index].enabled && state.tracks[index].needsReschedule
            && state.tracks[index].delayRemaining == nil {
            if !fillSchedule(in: &state, trackIndex: index) {
                state.tracks[index].enabled = false
            }
        }
        guard state.tracks.contains(where: \.enabled) else {
            if state.engine.isRunning {
                state.engine.pause()
            }
            return
        }
        // Mute stops decode/render (unlike WPE's gain-only mute); unmute resumes where it stopped.
        guard !state.isMuted, !state.isSuspended else {
            if state.engine.isRunning {
                state.engine.pause()
            }
            return
        }
        if !state.engine.isRunning {
            do {
                try state.engine.start()
            } catch {
                Logger.repeatedWarning("WPESoundRuntime reconcile: engine.start() failed: \(error.localizedDescription)", source: .soundEngineStart, category: .wpeRender)
                return
            }
        }
        for track in state.tracks where track.enabled && !track.player.isPlaying {
            track.player.play()
        }
    }

    /// Returns whether anything is queued: `single` stopping at one is success; empty queue is failure.
    @discardableResult
    private func fillSchedule(in state: inout State, trackIndex: Int) -> Bool {
        guard state.tracks.indices.contains(trackIndex) else { return false }
        while state.tracks[trackIndex].scheduledFiles.count < state.tracks[trackIndex].scheduleDepth {
            guard scheduleOneSegment(in: &state, trackIndex: trackIndex) else { break }
        }
        let queued = !state.tracks[trackIndex].scheduledFiles.isEmpty
        state.tracks[trackIndex].needsReschedule = !queued
        return queued
    }

    private func scheduleOneSegment(in state: inout State, trackIndex: Int) -> Bool {
        guard state.tracks.indices.contains(trackIndex) else { return false }
        let pathCount = state.tracks[trackIndex].urls.count
        let candidates = state.tracks[trackIndex].scheduler.candidates(pathCount: pathCount)
        // `.dataConsumed` can fire while start-silent is only prepared, so use `.dataRendered`.
        let callbackType: AVAudioPlayerNodeCompletionCallbackType = .dataRendered

        for pathIndex in candidates {
            let url = state.tracks[trackIndex].urls[pathIndex]
            guard let file = try? AVAudioFile(forReading: url) else { continue }

            let epoch = state.tracks[trackIndex].epoch
            let token = state.tracks[trackIndex].token
            let player = state.tracks[trackIndex].player
            state.tracks[trackIndex].scheduler.didSchedule(index: pathIndex, pathCount: pathCount)
            state.tracks[trackIndex].scheduledFiles.append(file)
            state.tracks[trackIndex].lastScheduledPathIndex = pathIndex
            state.tracks[trackIndex].needsReschedule = false
            player.scheduleFile(
                file,
                at: nil,
                completionCallbackType: callbackType
            ) { [weak self] _ in
                guard let self else { return }
                completionQueue.async { [weak self] in
                    self?.handleScheduledFileCompletion(token: token, epoch: epoch)
                }
            }
            return true
        }
        return false
    }

    private func handleScheduledFileCompletion(token: UInt64, epoch: UInt64) {
        state.withLock { state in
            // Counted before token/epoch guards so tests can tell a deaf host stack from ignored deliveries.
            state.renderedCompletionCount += 1
            guard let index = state.tracks.firstIndex(where: { $0.token == token }),
                  state.tracks[index].epoch == epoch else { return }

            // Completions arrive in schedule order, so the finished segment is
            // the head of the queue.
            if !state.tracks[index].scheduledFiles.isEmpty {
                state.tracks[index].scheduledFiles.removeFirst()
            }
            guard state.tracks[index].enabled else { return }
            if state.tracks[index].waitsBetweenPlays {
                let delay = state.tracks[index].randomDelay
                state.tracks[index].delayRemaining = state.tracks[index].scheduler
                    .randomDelay(minTime: delay.minTime, maxTime: delay.maxTime)
                state.tracks[index].needsReschedule = true
                return
            }
            if fillSchedule(in: &state, trackIndex: index) {
                if state.engine.isRunning, !state.tracks[index].player.isPlaying {
                    state.tracks[index].player.play()
                }
            } else {
                // `single` reaches here after exactly one file. Resetting only
                // prepares a future explicit script play; it does not auto-loop.
                state.tracks[index].enabled = false
                state.tracks[index].scheduler.reset()
                state.tracks[index].needsReschedule = true
                reconcileEngineRunState(state: &state)
            }
        }
    }

    private func applyAudioState(to state: inout State) {
        for track in state.tracks {
            track.player.volume = effectiveVolume(
                sceneVolume: track.sceneVolume,
                appVolume: state.masterVolume,
                isMuted: state.isMuted
            )
        }
    }

    /// WPE applies volume² × the app volume; the old renderer's rules stay linear.
    private func effectiveVolume(sceneVolume: Float, appVolume: Float, isMuted: Bool) -> Float {
        guard !isMuted else { return 0 }
        let authored = rules == .wpe ? sceneVolume * sceneVolume : sceneVolume
        return max(0, min(1, authored * appVolume))
    }

    private static func stopAndDetachAll(in state: inout State) {
        for track in state.tracks {
            track.player.stop()
            state.engine.detach(track.player)
        }
        state.engine.stop()
        state.tracks.removeAll(keepingCapacity: false)
    }

    private static func stopTrack(at index: Int, state: inout State) {
        guard state.tracks.indices.contains(index) else { return }
        state.tracks[index].enabled = false
        state.tracks[index].epoch &+= 1
        state.tracks[index].player.stop()
        state.tracks[index].scheduledFiles.removeAll(keepingCapacity: false)
        state.tracks[index].scheduler.reset()
        state.tracks[index].needsReschedule = true
        state.tracks[index].delayRemaining = nil
    }

    private static func derivedSeed(base: UInt64, index: Int) -> UInt64 {
        base &+ UInt64(index) &* 0x9E37_79B9_7F4A_7C15
    }
}
#endif
