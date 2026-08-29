import Foundation

/// Bridges the app-lifetime `NowPlayingMonitor` into one pipeline build. The
/// source owns only its subscription — the DNC observer stays with the monitor
/// across pipeline teardowns.
final actor NowPlayingSource: MonitorDataSource {
    nonisolated let sourceID = "nowPlaying"

    private let monitorOverride: NowPlayingMonitor?
    private let fetcher: NowPlayingArtworkFetcher
    private let subscriptionID = UUID()
    private var monitor: NowPlayingMonitor?
    private var sink: (any MonitorSnapshotSink)?
    private var lastForwardedOrdinal: UInt64?
    /// Generation token (invariant 6): artwork may only attach to the track
    /// key that is still current when the fetch lands.
    private var currentTrackKey: String?
    /// Key the running/finished artwork task was started for, so repeated
    /// frames of one track do not spawn repeated fetch tasks.
    private var artworkTaskKey: String?
    private var artworkTask: Task<Void, Never>?
    private var lastPublishedState: MonitorNowPlayingState?

    init(
        monitor: NowPlayingMonitor? = nil,
        artworkFetcher: NowPlayingArtworkFetcher? = nil,
        audioReactive: Bool = true,
        audioDemand: (@MainActor @Sendable (Bool) -> Void)? = nil,
        positionProvider: PositionProvider? = nil,
        positionPollInterval: Duration = NowPlayingSource.defaultPositionPollInterval
    ) {
        monitorOverride = monitor
        fetcher = artworkFetcher ?? .shared
        self.audioReactive = audioReactive
        self.audioDemand = audioDemand ?? Self.defaultAudioDemand
        self.positionProvider = positionProvider ?? Self.defaultPositionProvider
        self.positionPollInterval = positionPollInterval
    }

    // MARK: - Playhead polling (players whose notification omits the position)

    /// Reads a player's playhead in seconds, or nil if it cannot be read.
    typealias PositionProvider = @MainActor @Sendable (String) async -> Double?

    /// The widget interpolates between anchors on its own wall clock, so this
    /// only has to correct drift and catch scrubs made inside the player. Five
    /// seconds is one Apple Event per five seconds while a track is up — and
    /// only while an overlay is actually alive, because this lives on the
    /// pipeline-scoped source rather than the app-lifetime monitor.
    static let defaultPositionPollInterval: Duration = .seconds(5)

    private let positionProvider: PositionProvider
    private let positionPollInterval: Duration
    private var positionTask: Task<Void, Never>?
    /// The *track* the running poll loop is asking about, not just the player.
    /// Keying on the player alone meant skipping to the next song inside one
    /// app left the loop untouched — no leading tick, so the bar stayed blank
    /// until the next interval — and let a reply that was already in flight for
    /// the previous song be written onto the new one.
    private var positionPollKey: String?

    private static let defaultPositionProvider: PositionProvider = { bundleID in
        await NowPlayingController.shared.value(for: .playerPosition, from: bundleID)?.doubleValue
    }

    /// Only players whose mapping carries no position key need this — the rest
    /// already put the playhead in every notification, and asking twice would
    /// spend an Apple Event to learn what we were just told.
    private static func needsPositionPolling(_ state: MonitorNowPlayingState) -> Bool {
        guard state.phase.hasTrack, let bundleID = state.playerBundleID else { return false }
        guard let mapping = NowPlayingMonitor.mappings.first(where: { $0.bundleID == bundleID }) else {
            return false
        }
        return mapping.positionKey == nil
    }

    private func syncPositionPolling(for state: MonitorNowPlayingState) {
        guard Self.needsPositionPolling(state),
              let bundleID = state.playerBundleID,
              let key = NowPlayingArtworkFetcher.trackKey(for: state)
        else {
            stopPositionPolling()
            return
        }
        guard positionPollKey != key else { return }
        stopPositionPolling()
        positionPollKey = key
        let interval = positionPollInterval
        let provider = positionProvider
        positionTask = Task { [weak self] in
            // Leading tick: the bar should appear on the track change, not one
            // interval into the song.
            while !Task.isCancelled {
                // Stamped before the round trip, not after. An Apple Event is
                // synchronous IPC, and a reply that was already in flight when
                // the user scrubbed would otherwise land wearing a *newer*
                // timestamp than the scrub — which is exactly the test the
                // widget uses to decide the player has moved on, so the bar
                // snapped back to where it was before the drag.
                let issuedAt = Date().timeIntervalSince1970
                let seconds = await provider(bundleID)
                guard !Task.isCancelled else { return }
                await self?.applyPolledPosition(seconds, key: key, sampledAt: issuedAt)
                try? await Task.sleep(for: interval)
            }
        }
    }

    private func stopPositionPolling() {
        positionTask?.cancel()
        positionTask = nil
        positionPollKey = nil
    }

    /// Same token discipline as the artwork landing: a reply for a track that is
    /// no longer on screen must not be written into whatever replaced it.
    private func applyPolledPosition(_ seconds: Double?, key: String, sampledAt: Double) async {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return }
        guard let sink, positionPollKey == key else { return }
        guard var state = lastPublishedState,
              NowPlayingArtworkFetcher.trackKey(for: state) == key else { return }
        state.position = state.duration.map { min(seconds, $0) } ?? seconds
        state.positionSampledAt = sampledAt
        lastPublishedState = state
        await sink.updateNowPlaying(state)
    }

    /// Whether any placed layer still draws the reactive effects. Retaining the
    /// capture tap regardless would run the FFT for nobody.
    private let audioReactive: Bool

    /// The capture manager only runs the tap while a consumer retain is held;
    /// without this the widget's audio-reactive layer never sees `.capturing`
    /// unless an audio wallpaper happens to be running too.
    private static let defaultAudioDemand: @MainActor @Sendable (Bool) -> Void = { wanted in
        #if !LITE_BUILD
            if wanted {
                SystemAudioCaptureManager.shared.retain()
            } else {
                SystemAudioCaptureManager.shared.release()
            }
        #endif
    }

    func start(sink: any MonitorSnapshotSink) async {
        self.sink = sink
        let id = subscriptionID
        let forward: @Sendable (UInt64, MonitorNowPlayingState) -> Void = { [weak self] ordinal, state in
            guard let self else { return }
            Task { await self.push(state, ordinal: ordinal) }
        }
        let override = monitorOverride
        monitor = await MainActor.run { () -> NowPlayingMonitor in
            let monitor = override ?? NowPlayingMonitor.shared
            // Subscribing replays the current state, so resume shows the track
            // that changed while the pipeline was down.
            monitor.subscribe(id: id, handler: forward)
            return monitor
        }
    }

    func stop() async {
        generation &+= 1
        sink = nil
        stopPositionPolling()
        artworkTask?.cancel()
        await fetcher.cancelInFlight(except: nil)
        artworkTask = nil
        artworkTaskKey = nil
        currentTrackKey = nil
        lastPublishedState = nil
        // A reused instance must not let the old ordinal swallow the next
        // subscribe replay.
        lastForwardedOrdinal = nil
        await setAudioDemand(false)
        guard let monitor else { return }
        self.monitor = nil
        let id = subscriptionID
        await MainActor.run { monitor.unsubscribe(id: id) }
    }

    private func push(_ state: MonitorNowPlayingState, ordinal: UInt64) async {
        // The MainActor→actor hops are unordered Tasks; the ordinal keeps a
        // stale frame from overwriting a newer one. The generation is re-read
        // after every suspension: this actor yields at the cache lookup and at
        // the sink call, and a stop() interleaved there must win — otherwise a
        // stopped source publishes into a dead hub and re-retains the audio
        // tap with nobody left to release it (both review models hit this).
        let gen = generation
        guard let sink else { return }
        if let last = lastForwardedOrdinal, ordinal <= last { return }
        lastForwardedOrdinal = ordinal

        // Claiming the ordinal above is not enough: this actor suspends below,
        // and a newer frame that publishes during the suspension has already
        // moved the world on. Every resume re-checks that this frame is still
        // the newest, or it would overwrite the newer state — and, worse, drive
        // audio demand from a phase that is no longer current.
        func stillCurrent() -> Bool { generation == gen && lastForwardedOrdinal == ordinal }

        var state = state
        // nil for the no-track phases (empty title) — those never touch the
        // network and clear the token so any in-flight artwork is orphaned.
        let key = NowPlayingArtworkFetcher.trackKey(for: state)
        if key != currentTrackKey {
            currentTrackKey = key
            artworkTask?.cancel()
            artworkTask = nil
            artworkTaskKey = nil
            // Cancelling our own task only drops the result; the merged fetch
            // inside the actor keeps downloading until it is told to stop.
            await fetcher.cancelInFlight(except: key)
            guard stillCurrent() else { return }
        }
        if let key, state.artwork == nil {
            let cached = await fetcher.cachedArtwork(forKey: key)
            guard stillCurrent() else { return }
            if let cached {
                state.artwork = cached
            } else if artworkTaskKey != key {
                // Publish the text-only state below without waiting for the
                // image; the fetch re-publishes an enriched state on landing.
                artworkTaskKey = key
                let fetcher = fetcher
                // Copy: capturing the mutable `state` would hand the escaping
                // task the variable itself, which this scope keeps using below.
                let pending = state
                artworkTask = Task { [weak self] in
                    let data = await fetcher.artwork(for: pending)
                    await self?.finishArtworkFetch(data, key: key)
                }
            }
        }
        guard stillCurrent() else { return }
        // Carry the polled playhead across the notification that replaced it:
        // Music re-sends full metadata on a bare state change, and rebuilding
        // the state from it would blank the bar every time the user paused.
        if state.position == nil,
           let key = NowPlayingArtworkFetcher.trackKey(for: state),
           positionPollKey == key,
           let previous = lastPublishedState,
           NowPlayingArtworkFetcher.trackKey(for: previous) == key,
           let carried = previous.position {
            state.position = carried
            state.positionSampledAt = previous.positionSampledAt
        }
        lastPublishedState = state
        await sink.updateNowPlaying(state)
        guard stillCurrent() else { return }
        syncPositionPolling(for: state)
        await setAudioDemand(audioReactive && state.phase == .playing)
    }

    /// Bumped by stop(); an in-flight push must never publish or flip audio
    /// demand once its generation is stale.
    private var generation: UInt64 = 0

    /// At most one retain per source; balanced on phase change and stop().
    private let audioDemand: @MainActor @Sendable (Bool) -> Void
    private var audioDemandHeld = false

    private func setAudioDemand(_ wanted: Bool) async {
        guard wanted != audioDemandHeld else { return }
        audioDemandHeld = wanted
        await audioDemand(wanted)
    }

    /// Releases the per-track fetch token whatever the outcome. Leaving it set
    /// on failure made a miss permanent for the process's life; clearing it is
    /// safe only because `NowPlayingArtworkFetcher` keeps its own TTL'd negative
    /// cache — that, not this token, is what stops a failed key from hitting the
    /// network again on the very next frame.
    private func finishArtworkFetch(_ data: Data?, key: String) async {
        if artworkTaskKey == key { artworkTaskKey = nil }
        guard let data else { return }
        await applyFetchedArtwork(data, key: key)
    }

    private func applyFetchedArtwork(_ data: Data, key: String) async {
        // Token check: a slow response for a previous track, or one landing
        // after stop() (sink and track key are both cleared), must never
        // publish (invariant 6).
        guard let sink, key == currentTrackKey else { return }
        guard var state = lastPublishedState, state.artwork == nil else { return }
        state.artwork = data
        lastPublishedState = state
        await sink.updateNowPlaying(state)
    }
}
