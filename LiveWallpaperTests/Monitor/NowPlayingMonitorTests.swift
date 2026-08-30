import AppKit
import Foundation
import LiveWallpaperCore
import os
import Testing
@testable import LiveWallpaper

// MARK: - Fixtures (verbatim from .notes/probes/fixtures-nowplaying-2026-08-20.md)

private enum Fixture {
    static let spotifyName = "com.spotify.client.PlaybackStateChanged"
    static let musicName = "com.apple.Music.playerInfo"
    static let itunesAlias = "com.apple.iTunes.playerInfo"

    static var spotifyPlaying: [AnyHashable: Any] { [
        "Album": "機動戦士ガンダム 閃光のハサウェイ オリジナル・サウンドトラック",
        "Album Artist": "Sawano Hiroyuki",
        "Artist": "Sawano Hiroyuki",
        "Disc Number": 1,
        "Duration": 311093,
        "Has Artwork": true,
        "Name": "CC···12yl",
        "Play Count": 0,
        "Playback Position": 66.038,
        "Player State": "Playing",
        "Popularity": 29,
        "Track ID": "spotify:track:22ALg0cH8ADNGb9eK3RFCo",
        "Track Number": 4,
    ] }

    /// Paused frame re-sends all 13 keys; only state + position move.
    static var spotifyPaused: [AnyHashable: Any] {
        var frame = spotifyPlaying
        frame["Player State"] = "Paused"
        frame["Playback Position"] = 68.145
        return frame
    }

    static var musicPlaying: [AnyHashable: Any] { [
        "Album": "ENDROLL",
        "Artist": "Yoohei Kawakami",
        "Genre": "Music",
        "Library PersistentID": 375053631865832198,
        "Name": "ENDROLL",
        "PersistentID": -7452835085963532966,
        "Player State": "Playing",
        "Total Time": 182000,
    ] }

    /// Observed single-key frames: bare `Player State`, no metadata.
    static var musicPausedSingleKey: [AnyHashable: Any] { ["Player State": "Paused"] }
    static var musicStoppedSingleKey: [AnyHashable: Any] { ["Player State": "Stopped"] }
}

// MARK: - Recording plumbing

private final class NowPlayingStateBox: Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: [MonitorNowPlayingState]())

    func append(_ state: MonitorNowPlayingState?) {
        guard let state else { return }
        lock.withLock { $0.append(state) }
    }

    var states: [MonitorNowPlayingState] { lock.withLock { $0 } }
    var titles: [String] { states.map(\.title) }
    var count: Int { states.count }
}

private actor RecordingNowPlayingSink: MonitorSnapshotSink {
    let box = NowPlayingStateBox()
    func updateSystem(_ snapshot: MonitorSystemSnapshot) async {}
    func updateAgents(sourceID: String, sessions: [MonitorAgentSessionState]) async {}
    func updateHealth(_ health: MonitorSourceHealth) async {}
    func updateNowPlaying(_ state: MonitorNowPlayingState?) async { box.append(state) }
}

private actor Gate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

/// Records like the plain sink, but parks one named frame inside the sink call
/// so a later frame can overtake it — the interleaving `push` has to survive.
private actor GatedNowPlayingSink: MonitorSnapshotSink {
    let box = NowPlayingStateBox()
    private let gate: Gate
    private let blockingTitle: String

    init(gate: Gate, blockingTitle: String) {
        self.gate = gate
        self.blockingTitle = blockingTitle
    }

    func updateSystem(_ snapshot: MonitorSystemSnapshot) async {}
    func updateAgents(sourceID: String, sessions: [MonitorAgentSessionState]) async {}
    func updateHealth(_ health: MonitorSourceHealth) async {}
    func updateNowPlaying(_ state: MonitorNowPlayingState?) async {
        box.append(state)
        if state?.title == blockingTitle { await gate.wait() }
    }
}

private final class ClockBox: Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_000_000))
    var now: Date { lock.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { lock.withLock { $0 = $0.addingTimeInterval(seconds) } }
}

private final class RequestCounter: Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: [URLRequest]())
    func record(_ request: URLRequest) { lock.withLock { $0.append(request) } }
    var count: Int { lock.withLock { $0.count } }
}

@MainActor
private func makeMonitor(running: Set<String> = []) -> NowPlayingMonitor {
    NowPlayingMonitor(registersObservers: false, runningBundleIDs: { running })
}

/// Fixtures carry real track IDs; an offline fetcher keeps these tests off
/// the network (and off the shared fetcher's caches).
private func offlineFetcher() -> NowPlayingArtworkFetcher {
    NowPlayingArtworkFetcher(transport: { _ in throw URLError(.notConnectedToInternet) })
}

/// Polls until the condition holds. Suspending the main actor lets the host
/// app's main run loop spin, which is what delivers DNC notifications.
@MainActor
private func waitUntil(
    timeout: TimeInterval = 5,
    _ condition: () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { return false }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return true
}

// MARK: - userInfo → state mapping

@Suite("Now Playing userInfo mapping")
struct NowPlayingMappingTests {
    @MainActor
    @Test("Spotify 13-key frame maps units and identity")
    func spotifyFullFrame() {
        let monitor = makeMonitor()
        monitor.ingest(name: Fixture.spotifyName, userInfo: Fixture.spotifyPlaying)

        let state = monitor.currentState
        #expect(state.phase == .playing)
        #expect(state.title == "CC···12yl")
        #expect(state.artist == "Sawano Hiroyuki")
        #expect(state.album == "機動戦士ガンダム 閃光のハサウェイ オリジナル・サウンドトラック")
        // Duration is integer milliseconds, position float seconds.
        #expect(state.duration == 311.093)
        #expect(state.position == 66.038)
        let sampledAt = state.positionSampledAt
        #expect(sampledAt != nil)
        if let sampledAt {
            #expect(abs(sampledAt - Date().timeIntervalSince1970) < 30)
        }
        #expect(state.trackID == "spotify:track:22ALg0cH8ADNGb9eK3RFCo")
        #expect(state.playerBundleID == "com.spotify.client")
        #expect(state.artwork == nil)
    }

    @MainActor
    @Test("Apple Music 8-key frame has no position and no track ID")
    func musicFullFrame() {
        let monitor = makeMonitor()
        monitor.ingest(name: Fixture.musicName, userInfo: Fixture.musicPlaying)

        let state = monitor.currentState
        #expect(state.phase == .playing)
        #expect(state.title == "ENDROLL")
        #expect(state.artist == "Yoohei Kawakami")
        #expect(state.album == "ENDROLL")
        #expect(state.duration == 182.0)
        #expect(state.position == nil)
        #expect(state.positionSampledAt == nil)
        #expect(state.trackID == nil)
        #expect(state.playerBundleID == "com.apple.Music")
    }

    @MainActor
    @Test("Music single-key frame updates phase without clearing metadata")
    func singleKeyFrameKeepsMetadata() {
        let monitor = makeMonitor()
        monitor.ingest(name: Fixture.musicName, userInfo: Fixture.musicPlaying)
        monitor.ingest(name: Fixture.musicName, userInfo: Fixture.musicPausedSingleKey)

        let state = monitor.currentState
        #expect(state.phase == .paused)
        #expect(state.title == "ENDROLL")
        #expect(state.artist == "Yoohei Kawakami")
        #expect(state.duration == 182.0)
    }

    @MainActor
    @Test("Cold single-key frame publishes no track (no title, no media)")
    func coldSingleKeyFramePublishesNothing() {
        let monitor = makeMonitor(running: ["com.apple.Music"])
        monitor.ingest(name: Fixture.musicName, userInfo: Fixture.musicPausedSingleKey)

        #expect(monitor.currentState.phase == .awaitingFirstEvent)
        #expect(monitor.currentState.title.isEmpty)
    }

    @MainActor
    @Test("Missing keys are ignored, not fatal")
    func missingKeysIgnored() {
        let monitor = makeMonitor()
        monitor.ingest(
            name: Fixture.spotifyName,
            userInfo: ["Name": "Bare Frame", "Player State": "Playing"]
        )

        let state = monitor.currentState
        #expect(state.title == "Bare Frame")
        #expect(state.phase == .playing)
        #expect(state.artist == nil)
        #expect(state.album == nil)
        #expect(state.duration == nil)
        #expect(state.position == nil)
        #expect(state.trackID == nil)
    }

    @MainActor
    @Test("Wrongly-typed values degrade to absent fields")
    func typeAnomaliesDegradeGracefully() {
        let monitor = makeMonitor(running: [])
        // Numeric Name == no usable title == no publish.
        monitor.ingest(
            name: Fixture.spotifyName,
            userInfo: ["Name": 42, "Player State": "Playing"]
        )
        #expect(monitor.currentState.phase == .noPlayer)

        // String duration/position fail the number cast; the rest maps.
        monitor.ingest(
            name: Fixture.spotifyName,
            userInfo: [
                "Name": "Odd Types",
                "Player State": "Playing",
                "Duration": "311093",
                "Playback Position": "66.038",
            ]
        )
        let state = monitor.currentState
        #expect(state.title == "Odd Types")
        #expect(state.duration == nil)
        #expect(state.position == nil)
    }

    @MainActor
    @Test("Unknown notification names are ignored — including the iTunes alias")
    func unknownPlayerIgnored() {
        let monitor = makeMonitor(running: [])
        monitor.ingest(name: Fixture.itunesAlias, userInfo: Fixture.musicPlaying)
        monitor.ingest(name: "com.example.someplayer.state", userInfo: Fixture.spotifyPlaying)
        #expect(monitor.currentState.phase == .noPlayer)
    }

    @MainActor
    @Test("A frame without a title never reaches subscribers")
    func titleLessFrameNotPublished() {
        let monitor = makeMonitor()
        let box = NowPlayingStateBox()
        monitor.subscribe(id: UUID()) { _, state in box.append(state) }
        #expect(box.count == 1) // the synchronous replay

        monitor.ingest(name: Fixture.spotifyName, userInfo: ["Player State": "Playing"])
        #expect(box.count == 1)
    }

    // Invariant 10: the registration list is derived from the mapping table, so
    // asserting the table pins what gets subscribed.
    @Test("Subscribed notification names exclude the duplicate iTunes alias")
    func subscribedNamesExcludeITunesAlias() {
        let names = NowPlayingMonitor.mappings.map(\.notificationName)
        #expect(names.contains(Fixture.spotifyName))
        #expect(names.contains(Fixture.musicName))
        #expect(!names.contains(Fixture.itunesAlias))
    }
}

// MARK: - Multi-player arbitration (invariant 3)

@Suite("Now Playing arbitration")
struct NowPlayingArbitrationTests {
    @MainActor
    @Test("A late Paused from another player does not displace the playing one")
    func latePausedDoesNotDisplacePlaying() {
        let monitor = makeMonitor()
        monitor.ingest(name: Fixture.spotifyName, userInfo: Fixture.spotifyPlaying)
        monitor.ingest(name: Fixture.musicName, userInfo: pausedMusic())

        #expect(monitor.currentState.playerBundleID == "com.spotify.client")
        #expect(monitor.currentState.phase == .playing)
    }

    @MainActor
    @Test("The most recent Playing reporter wins")
    func mostRecentPlayingWins() {
        let monitor = makeMonitor()
        monitor.ingest(name: Fixture.spotifyName, userInfo: Fixture.spotifyPlaying)
        monitor.ingest(name: Fixture.musicName, userInfo: Fixture.musicPlaying)

        #expect(monitor.currentState.playerBundleID == "com.apple.Music")
    }

    @MainActor
    @Test("Current pausing hands over to the still-playing player")
    func pauseHandsOverToPlayingPlayer() {
        let monitor = makeMonitor()
        monitor.ingest(name: Fixture.musicName, userInfo: Fixture.musicPlaying)
        monitor.ingest(name: Fixture.spotifyName, userInfo: Fixture.spotifyPlaying)
        #expect(monitor.currentState.playerBundleID == "com.spotify.client")

        monitor.ingest(name: Fixture.spotifyName, userInfo: Fixture.spotifyPaused)
        #expect(monitor.currentState.playerBundleID == "com.apple.Music")
        #expect(monitor.currentState.phase == .playing)
    }

    @MainActor
    @Test("With nothing playing, the most recent event shows as paused")
    func allPausedShowsMostRecentEvent() {
        let monitor = makeMonitor()
        monitor.ingest(name: Fixture.spotifyName, userInfo: Fixture.spotifyPlaying)
        monitor.ingest(name: Fixture.musicName, userInfo: Fixture.musicPlaying)
        monitor.ingest(name: Fixture.spotifyName, userInfo: Fixture.spotifyPaused)
        monitor.ingest(name: Fixture.musicName, userInfo: Fixture.musicPausedSingleKey)

        #expect(monitor.currentState.playerBundleID == "com.apple.Music")
        #expect(monitor.currentState.phase == .paused)
    }

    @MainActor
    @Test("Stopped clears that player and arbitration falls through")
    func stoppedClearsPlayer() {
        let monitor = makeMonitor(running: [])
        monitor.ingest(name: Fixture.spotifyName, userInfo: Fixture.spotifyPlaying)
        monitor.ingest(name: Fixture.musicName, userInfo: Fixture.musicPlaying)

        monitor.ingest(name: Fixture.musicName, userInfo: Fixture.musicStoppedSingleKey)
        #expect(monitor.currentState.playerBundleID == "com.spotify.client")

        var spotifyStopped = Fixture.spotifyPlaying
        spotifyStopped["Player State"] = "Stopped"
        monitor.ingest(name: Fixture.spotifyName, userInfo: spotifyStopped)
        #expect(monitor.currentState.phase == .noPlayer)
    }

    @MainActor
    @Test("A force-killed player is cleared like a Stopped frame")
    func terminationClearsPlayer() {
        let monitor = makeMonitor(running: [])
        monitor.ingest(name: Fixture.spotifyName, userInfo: Fixture.spotifyPlaying)
        monitor.ingest(name: Fixture.musicName, userInfo: Fixture.musicPlaying)

        monitor.playerDidTerminate(bundleID: "com.spotify.client")
        #expect(monitor.currentState.playerBundleID == "com.apple.Music")

        monitor.playerDidTerminate(bundleID: "com.apple.Music")
        #expect(monitor.currentState.phase == .noPlayer)

        // Unknown bundle IDs are ignored without touching state.
        monitor.playerDidTerminate(bundleID: "com.example.other")
        #expect(monitor.currentState.phase == .noPlayer)
    }

    @MainActor
    @Test("Never-seen players resolve running vs absent (three-state)")
    func threeStateDistinction() {
        #expect(makeMonitor(running: []).currentState.phase == .noPlayer)
        #expect(
            makeMonitor(running: ["com.spotify.client"]).currentState.phase == .awaitingFirstEvent
        )
        #expect(makeMonitor(running: ["com.apple.Music"]).currentState.phase == .awaitingFirstEvent)
    }

    private func pausedMusic() -> [AnyHashable: Any] {
        var frame = Fixture.musicPlaying
        frame["Player State"] = "Paused"
        return frame
    }
}

// MARK: - Source lifecycle + observer residency

@Suite("Now Playing source")
struct NowPlayingSourceTests {

    /// Music's notification has never carried a playhead, so the layer drew no
    /// progress for it at all — while `sdef /System/Applications/Music.app`
    /// has always listed `player position`. The source polls for exactly the
    /// players whose mapping lacks a position key.
    @MainActor
    @Test("a player whose notification omits the position gets it polled in")
    func polledPositionReachesTheSink() async {
        let monitor = makeMonitor()
        monitor.ingest(name: Fixture.musicName, userInfo: Fixture.musicPlaying)

        let sink = RecordingNowPlayingSink()
        let source = NowPlayingSource(
            monitor: monitor,
            artworkFetcher: offlineFetcher(),
            positionProvider: { bundleID in bundleID == "com.apple.Music" ? 42 : nil },
            positionPollInterval: .milliseconds(20)
        )
        await source.start(sink: sink)

        #expect(await waitUntil { sink.box.states.contains { $0.position == 42 } })
        #expect(sink.box.states.contains { $0.positionSampledAt != nil })
        await source.stop()
    }

    /// Spotify already puts the playhead in every frame; asking again would
    /// spend an Apple Event to be told what we were just told.
    @MainActor
    @Test("a player that already reports its position is never polled")
    func selfReportingPlayerIsNotPolled() async {
        let monitor = makeMonitor()
        monitor.ingest(name: Fixture.spotifyName, userInfo: Fixture.spotifyPlaying)

        let asked = NowPlayingStateBox()
        let sink = RecordingNowPlayingSink()
        let source = NowPlayingSource(
            monitor: monitor,
            artworkFetcher: offlineFetcher(),
            positionProvider: { _ in
                asked.append(MonitorNowPlayingState(phase: .playing, title: "asked"))
                return 999
            },
            positionPollInterval: .milliseconds(20)
        )
        await source.start(sink: sink)
        #expect(await waitUntil { sink.box.count >= 1 })
        // Long enough for several poll intervals to have elapsed.
        try? await Task.sleep(for: .milliseconds(120))
        #expect(asked.count == 0)
        #expect(sink.box.states.allSatisfy { $0.position != 999 })
        await source.stop()
    }

    /// Music re-sends full metadata on a bare pause, which rebuilt the state
    /// from the notification and blanked the polled playhead every time.
    @MainActor
    @Test("a polled playhead survives the next notification for the same track")
    func polledPositionSurvivesRepublish() async {
        let monitor = makeMonitor()
        monitor.ingest(name: Fixture.musicName, userInfo: Fixture.musicPlaying)

        let sink = RecordingNowPlayingSink()
        let source = NowPlayingSource(
            monitor: monitor,
            artworkFetcher: offlineFetcher(),
            positionProvider: { _ in 42 },
            positionPollInterval: .seconds(30)   // one leading tick, then quiet
        )
        await source.start(sink: sink)
        #expect(await waitUntil { sink.box.states.contains { $0.position == 42 } })

        monitor.ingest(name: Fixture.musicName, userInfo: Fixture.musicPlaying)
        #expect(await waitUntil { sink.box.count >= 3 })
        #expect(sink.box.states.last?.position == 42)
        await source.stop()
    }

    /// Skipping to the next song inside one player keeps the same bundle ID, so
    /// a loop keyed on the player alone never restarted: no leading tick, and a
    /// reply already in flight for the previous song landed on the new one.
    @MainActor
    @Test("changing track restarts the poll and re-anchors immediately")
    func trackChangeRestartsPolling() async {
        let monitor = makeMonitor()
        monitor.ingest(name: Fixture.musicName, userInfo: Fixture.musicPlaying)

        let sink = RecordingNowPlayingSink()
        let asked = NowPlayingStateBox()
        let source = NowPlayingSource(
            monitor: monitor,
            artworkFetcher: offlineFetcher(),
            positionProvider: { _ in
                asked.append(MonitorNowPlayingState(phase: .playing, title: "asked"))
                return 42
            },
            // Long enough that a second reading can only come from a restart.
            positionPollInterval: .seconds(30)
        )
        await source.start(sink: sink)
        #expect(await waitUntil { asked.count >= 1 })
        let afterFirstTrack = asked.count

        var second = Fixture.musicPlaying
        second["Name"] = "A different song"
        monitor.ingest(name: Fixture.musicName, userInfo: second)

        #expect(await waitUntil { asked.count > afterFirstTrack })
        await source.stop()
    }

    /// The carried playhead is keyed on the track, not the title: two songs can
    /// share a name, and inheriting the old offset is worse than none.
    @MainActor
    @Test("a new track does not inherit the previous track's playhead")
    func newTrackDoesNotInheritPosition() async {
        let monitor = makeMonitor()
        monitor.ingest(name: Fixture.musicName, userInfo: Fixture.musicPlaying)

        let sink = RecordingNowPlayingSink()
        let source = NowPlayingSource(
            monitor: monitor,
            artworkFetcher: offlineFetcher(),
            positionProvider: { _ in 42 },
            positionPollInterval: .seconds(30)
        )
        await source.start(sink: sink)
        #expect(await waitUntil { sink.box.states.contains { $0.position == 42 } })

        var second = Fixture.musicPlaying
        second["Artist"] = "Someone else entirely"
        monitor.ingest(name: Fixture.musicName, userInfo: second)

        #expect(await waitUntil { sink.box.states.last?.artist == "Someone else entirely" })
        let carried = sink.box.states.last(where: { $0.artist == "Someone else entirely" })
        // Either still unset, or re-read for the new track — never the old
        // track's value copied across.
        #expect(carried?.position == nil || carried?.position == 42)
        await source.stop()
    }

    @MainActor
    @Test("stop cancels the poll loop")
    func stopCancelsPolling() async {
        let monitor = makeMonitor()
        monitor.ingest(name: Fixture.musicName, userInfo: Fixture.musicPlaying)

        let asked = NowPlayingStateBox()
        let sink = RecordingNowPlayingSink()
        let source = NowPlayingSource(
            monitor: monitor,
            artworkFetcher: offlineFetcher(),
            positionProvider: { _ in
                asked.append(MonitorNowPlayingState(phase: .playing, title: "asked"))
                return 42
            },
            positionPollInterval: .milliseconds(20)
        )
        await source.start(sink: sink)
        #expect(await waitUntil { asked.count >= 1 })
        await source.stop()
        let afterStop = asked.count
        try? await Task.sleep(for: .milliseconds(120))
        #expect(asked.count <= afterStop + 1)   // at most the one already in flight
    }
    @MainActor
    @Test("start publishes the last known state immediately")
    func startPublishesImmediately() async {
        let monitor = makeMonitor()
        monitor.ingest(name: Fixture.spotifyName, userInfo: Fixture.spotifyPlaying)

        let sink = RecordingNowPlayingSink()
        let source = NowPlayingSource(monitor: monitor, artworkFetcher: offlineFetcher())
        await source.start(sink: sink)

        #expect(await waitUntil { sink.box.count >= 1 })
        #expect(sink.box.states.first?.title == "CC···12yl")
        await source.stop()
    }

    @MainActor
    @Test("stop detaches the sink from further monitor events")
    func stopDetachesSink() async {
        let monitor = makeMonitor()
        monitor.ingest(name: Fixture.spotifyName, userInfo: Fixture.spotifyPlaying)

        let sink = RecordingNowPlayingSink()
        let source = NowPlayingSource(monitor: monitor, artworkFetcher: offlineFetcher())
        await source.start(sink: sink)
        #expect(await waitUntil { sink.box.count >= 1 })
        let countAtStop = sink.box.count
        await source.stop()

        monitor.ingest(name: Fixture.spotifyName, userInfo: Fixture.spotifyPaused)
        // Negative probe: settle, then assert nothing new arrived.
        _ = await waitUntil(timeout: 0.3) { false }
        #expect(sink.box.count == countAtStop)
    }

    /// Invariant 1, behavioral half: the monitor keeps accruing state with zero
    /// live sources, and the next source's start replays it with no resume gap.
    @MainActor
    @Test("state accrued while no source exists replays into the next source")
    func stateAccruesAcrossSourceLifetimes() async {
        let monitor = makeMonitor()
        let sink1 = RecordingNowPlayingSink()
        let source1 = NowPlayingSource(monitor: monitor, artworkFetcher: offlineFetcher())
        await source1.start(sink: sink1)

        monitor.ingest(
            name: Fixture.spotifyName,
            userInfo: ["Name": "Residency Song A", "Player State": "Playing"]
        )
        #expect(await waitUntil { sink1.box.titles.contains("Residency Song A") })

        await source1.stop()

        // Track change with zero live sources — the pause/occlusion window.
        monitor.ingest(
            name: Fixture.spotifyName,
            userInfo: ["Name": "Residency Song B", "Player State": "Playing"]
        )

        let sink2 = RecordingNowPlayingSink()
        let source2 = NowPlayingSource(monitor: monitor, artworkFetcher: offlineFetcher())
        await source2.start(sink: sink2)
        #expect(await waitUntil { sink2.box.count >= 1 })
        #expect(sink2.box.states.first?.title == "Residency Song B")
        await source2.stop()
    }

    /// Invariant 1, registration half. An in-process DNC post does not deliver
    /// under the sandboxed test host (probed 2026-08-20: delivered=0 even with
    /// `deliverImmediately`), so the wiring is pinned as a source contract:
    /// the observer is registered once in the monitor's init with
    /// `.deliverImmediately`, and nothing on the source's lifecycle path can
    /// unregister it.
    @Test("the DNC observer lives in monitor init and the source cannot remove it")
    func observerRegistrationSourceContract() throws {
        let monitor = try RepositoryRoot.source(
            "LiveWallpaper/Monitor/NowPlaying/NowPlayingMonitor.swift"
        )
        let initSlice = try slice(monitor, from: "init(", until: "deinit")
        #expect(initSlice.contains("addObserver("))
        #expect(initSlice.contains("suspensionBehavior: .deliverImmediately"))
        // The only unregistration is deinit hygiene for test instances; the
        // shared instance never deallocates. Every removeObserver in the file
        // must live inside the deinit slice — none on any runtime path.
        let deinitSlice = try slice(monitor, from: "deinit", until: "@objc private func handleNotification")
        let total = monitor.components(separatedBy: "removeObserver").count - 1
        let inDeinit = deinitSlice.components(separatedBy: "removeObserver").count - 1
        #expect(total >= 1)
        #expect(total == inDeinit)

        let source = try RepositoryRoot.source(
            "LiveWallpaper/Monitor/NowPlaying/NowPlayingSource.swift"
        )
        #expect(!source.contains("DistributedNotificationCenter"))
        #expect(!source.contains("removeObserver"))
    }

    /// A failed artwork fetch used to leave its per-track token set forever, so
    /// the source never asked again for that track — not even long after the
    /// fetcher's own negative cache had expired and a retry would have worked.
    @MainActor
    @Test("a failed artwork fetch is retried once the fetcher's negative cache expires")
    func failedArtworkIsRetriedAfterTTL() async {
        let clock = ClockBox()
        let requests = RequestCounter()
        let fetcher = NowPlayingArtworkFetcher(
            transport: { request in
                requests.record(request)
                throw URLError(.notConnectedToInternet)
            },
            now: { clock.now }
        )
        let monitor = makeMonitor()
        let sink = RecordingNowPlayingSink()
        let source = NowPlayingSource(monitor: monitor, artworkFetcher: fetcher)
        await source.start(sink: sink)

        monitor.ingest(name: Fixture.spotifyName, userInfo: Fixture.spotifyPlaying)
        #expect(await waitUntil { requests.count > 0 })
        // Let the retry inside `runFetch` finish before the count is read.
        _ = await waitUntil(timeout: 0.4) { false }
        let firstRound = requests.count

        // Same track, fresh frame, still inside the fetcher's negative TTL: the
        // fetcher answers from its own cache without a request.
        clock.advance(NowPlayingArtworkFetcher.negativeTTL - 1)
        monitor.ingest(name: Fixture.spotifyName, userInfo: Fixture.spotifyPaused)
        #expect(await waitUntil { sink.box.count >= 3 })
        #expect(requests.count == firstRound)

        clock.advance(2)
        monitor.ingest(name: Fixture.spotifyName, userInfo: Fixture.spotifyPlaying)
        #expect(
            await waitUntil { requests.count > firstRound },
            "the source never asked the fetcher again for this track"
        )

        await source.stop()
    }

    /// The push path suspends on the artwork cache and on the sink. A frame that
    /// resumes after a newer one has already published must not write anything —
    /// re-driving audio demand from its stale phase was the observable damage.
    @MainActor
    @Test("a frame that resumes after a newer one published writes nothing")
    func staleFrameDoesNotOverwriteNewerState() async {
        let counter = NowPlayingAudioDemandTests.DemandCounter()
        let gate = Gate()
        let sink = GatedNowPlayingSink(gate: gate, blockingTitle: "Stale A")
        let monitor = makeMonitor()
        let source = NowPlayingSource(
            monitor: monitor,
            artworkFetcher: offlineFetcher(),
            audioDemand: { counter.apply($0) }
        )
        await source.start(sink: sink)

        // A is paused and gets stuck inside the sink.
        monitor.ingest(
            name: Fixture.spotifyName,
            userInfo: ["Name": "Stale A", "Player State": "Paused"]
        )
        #expect(await waitUntil { sink.box.titles.contains("Stale A") })

        // B is playing and publishes while A is still suspended.
        monitor.ingest(
            name: Fixture.spotifyName,
            userInfo: ["Name": "Fresh B", "Player State": "Playing"]
        )
        #expect(await waitUntil { counter.held == 1 })

        await gate.open()
        // Settle, then assert A's resume left B's demand alone.
        _ = await waitUntil(timeout: 0.5) { false }
        #expect(counter.held == 1, "a stale frame released the newer frame's capture retain")
        #expect(sink.box.titles.last == "Fresh B")

        await source.stop()
    }

    private func slice(_ source: String, from start: String, until end: String) throws -> String {
        let startRange = try #require(source.range(of: start))
        let endRange = try #require(
            source.range(of: end, range: startRange.upperBound ..< source.endIndex)
        )
        return String(source[startRange.lowerBound ..< endRange.lowerBound])
    }
}

// MARK: - Demand graph through the production path

@Suite("Now Playing demand graph")
struct NowPlayingDemandGraphTests {
    @MainActor
    @Test("An enabled music layer builds the source via the registered factory")
    func musicLayerBuildsSource() async {
        let runtime = makeRuntime()
        let controller = OverlayController(runtime: runtime)
        controller.apply(
            // The source follows the Music switch; the board is off entirely.
            overlay: MonitorOverlayConfiguration(
                enabled: false, level: .front,
                music: MusicOverlayConfiguration(enabled: true, level: .front)
            ),
            screenID: 91,
            screenFrame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        await controller.waitUntilRuntimeSettled()

        // agents stays false here, so this also proves the factory lives
        // outside the agents guard.
        #expect(await runtime.debugActiveSourceIDs == ["nowPlaying"])
        #expect(await runtime.debugActiveOptions?.system == false)
        #expect(await runtime.debugActiveOptions?.agents == false)

        controller.teardownAll()
        await controller.waitUntilRuntimeSettled()
        await runtime.shutdown()
    }

    @MainActor
    @Test("A board without a music layer builds no now-playing source")
    func boardWithoutMusicBuildsNoSource() async {
        let runtime = makeRuntime()
        let controller = OverlayController(runtime: runtime)
        controller.apply(
            overlay: MonitorOverlayConfiguration(
                enabled: true,
                level: .front,
                board: MonitorBoardConfiguration(widgets: [])
            ),
            screenID: 92,
            screenFrame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        await controller.waitUntilRuntimeSettled()

        #expect(await runtime.debugActiveSourceIDs == [])

        controller.teardownAll()
        await controller.waitUntilRuntimeSettled()
        await runtime.shutdown()
    }

    /// nil factory override → the runtime reads the real MainActor registry
    /// that `OverlayController.apply` populates via `registerDefaultFactories`.
    private func makeRuntime() -> Runtime {
        Runtime(
            grants: MonitorGrantAccess(
                resolveRoots: { (claude: nil, codex: nil) },
                release: {}
            ),
            sourceFactories: nil
        )
    }
}

// MARK: - Audio capture demand (consumer retain follows the playing phase)

@Suite("Now Playing audio demand", .serialized)
struct NowPlayingAudioDemandTests {
    @MainActor
    final class DemandCounter {
        private(set) var held = 0
        private(set) var transitions = 0
        func apply(_ wanted: Bool) {
            held += wanted ? 1 : -1
            transitions += 1
        }
    }

    @MainActor
    @Test("playing retains one capture consumer; pause and stop release it")
    func demandFollowsPhase() async {
        let counter = DemandCounter()
        let monitor = makeMonitor()
        let sink = RecordingNowPlayingSink()
        let source = NowPlayingSource(
            monitor: monitor,
            artworkFetcher: offlineFetcher(),
            audioDemand: { counter.apply($0) }
        )
        await source.start(sink: sink)

        monitor.ingest(name: Fixture.spotifyName, userInfo: Fixture.spotifyPlaying)
        #expect(await waitUntil { counter.held == 1 })

        // Repeated playing frames must not stack extra retains: wait for the
        // frame to land at the sink, then check no second transition happened.
        let published = sink.box.count
        monitor.ingest(name: Fixture.spotifyName, userInfo: Fixture.spotifyPlaying)
        #expect(await waitUntil { sink.box.count > published })
        #expect(counter.transitions == 1)
        #expect(counter.held == 1)

        monitor.ingest(name: Fixture.spotifyName, userInfo: Fixture.spotifyPaused)
        #expect(await waitUntil { counter.held == 0 })

        monitor.ingest(name: Fixture.spotifyName, userInfo: Fixture.spotifyPlaying)
        #expect(await waitUntil { counter.held == 1 })

        // stop() must balance the outstanding retain even mid-playback.
        await source.stop()
        #expect(await waitUntil { counter.held == 0 })
    }

    /// The layer can show the track without reacting to the audio, and in that
    /// mode the tap and its FFT are pure battery cost with no reader.
    @MainActor
    @Test("a layer with the reactive effects off never retains the capture tap")
    func noDemandWhenEffectsAreOff() async {
        let counter = DemandCounter()
        let monitor = makeMonitor()
        let sink = RecordingNowPlayingSink()
        let source = NowPlayingSource(
            monitor: monitor,
            artworkFetcher: offlineFetcher(),
            audioReactive: false,
            audioDemand: { counter.apply($0) }
        )
        await source.start(sink: sink)

        monitor.ingest(name: Fixture.spotifyName, userInfo: Fixture.spotifyPlaying)
        #expect(await waitUntil { sink.box.count > 0 }, "the track itself must still publish")
        #expect(counter.transitions == 0, "capture was retained for effects nobody draws")

        await source.stop()
        #expect(counter.held == 0)
    }
}

// MARK: - Cold-launch AppleScript seed

/// DNC only pushes on change, so a launch while a song is already playing left
/// the monitor blind until the next track — on a media wallpaper that read as
/// "the song only renders after the scene reloads". The seed is one
/// AppleScript read per running player, applied only where a notification has
/// not already answered.
@Suite("Now Playing launch seed")
struct NowPlayingLaunchSeedTests {
    @MainActor
    @Test("The snapshot text parses into phase, title, artist and album")
    func parseFullSnapshot() {
        let seed = NowPlayingMonitor.parseLaunchSnapshot("playing\nRedbone\nChildish Gambino\nAwaken, My Love!")
        #expect(seed == NowPlayingMonitor.LaunchSeed(
            phase: .playing, title: "Redbone",
            artist: "Childish Gambino", album: "Awaken, My Love!"
        ))
        let paused = NowPlayingMonitor.parseLaunchSnapshot("paused\nRedbone\n\n")
        #expect(paused == NowPlayingMonitor.LaunchSeed(phase: .paused, title: "Redbone"))
    }

    @MainActor
    @Test("A stopped player, an unknown state or a blank title yields no seed")
    func parseRejectsUnusableSnapshots() {
        #expect(NowPlayingMonitor.parseLaunchSnapshot("") == nil, "stopped players answer empty")
        #expect(NowPlayingMonitor.parseLaunchSnapshot("stopped\nRedbone") == nil)
        #expect(NowPlayingMonitor.parseLaunchSnapshot("wiedergabe\nRedbone") == nil, "unknown words never guess")
        #expect(NowPlayingMonitor.parseLaunchSnapshot("playing\n") == nil, "a title-less seed is not media")
    }

    @MainActor
    @Test("First subscriber triggers the seed and the state publishes")
    func subscribeSeedsFromRunningPlayer() async {
        let monitor = NowPlayingMonitor(
            registersObservers: false,
            runningBundleIDs: { ["com.spotify.client"] },
            launchSnapshotProvider: { bundleID in
                bundleID == "com.spotify.client" ? "playing\nRedbone\nChildish Gambino\n" : nil
            }
        )
        let box = NowPlayingStateBox()
        monitor.subscribe(id: UUID()) { _, state in box.append(state) }
        #expect(await waitUntil { box.states.last?.phase == .playing })
        let state = box.states.last
        #expect(state?.title == "Redbone")
        #expect(state?.artist == "Childish Gambino")
        #expect(state?.album == nil)
        #expect(state?.playerBundleID == "com.spotify.client")
    }

    @MainActor
    @Test("A notification that raced in beats the seed")
    func realNotificationWinsOverSeed() {
        let monitor = makeMonitor(running: ["com.spotify.client"])
        monitor.ingest(name: Fixture.spotifyName, userInfo: Fixture.spotifyPlaying)
        let before = monitor.currentState
        monitor.applyLaunchSeed(
            NowPlayingMonitor.LaunchSeed(phase: .paused, title: "Stale Seed"),
            bundleID: "com.spotify.client"
        )
        #expect(monitor.currentState.title == before.title, "the seed must never rewind a live record")
    }

    @MainActor
    @Test("A player that cannot be asked leaves the cold state untouched")
    func unansweredSeedKeepsAwaitingFirstEvent() async {
        let monitor = NowPlayingMonitor(
            registersObservers: false,
            runningBundleIDs: { ["com.spotify.client"] },
            launchSnapshotProvider: { _ in nil }
        )
        monitor.subscribe(id: UUID()) { _, _ in }
        // The provider answers immediately, so one spin of the task is enough.
        await Task.yield()
        #expect(monitor.currentState.phase == .awaitingFirstEvent)
    }
}
