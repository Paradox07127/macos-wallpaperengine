import AppKit
import Foundation
import LiveWallpaperCore
import os
import Testing
@testable import LiveWallpaper

private actor SystemMediaFixture {
    enum Failure: Error { case unavailable }
    var state: MonitorNowPlayingState?
    var failing = false
    private(set) var reads = 0
    init(_ state: MonitorNowPlayingState?) {
        self.state = state
    }

    func set(_ state: MonitorNowPlayingState?, failing: Bool = false) {
        self.state = state
        self.failing = failing
    }

    func read() throws -> MonitorNowPlayingState? {
        reads += 1
        if failing {
            throw Failure.unavailable
        }
        return state
    }
}

@Suite("System media source and fallback", .timeLimit(.minutes(1)))
struct NowPlayingSystemSourceTests {
    @MainActor
    @Test("Stopping during subscription setup leaves no system polling behind")
    func stopDuringSubscriptionSetup() async throws {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let didEnter = OSAllocatedUnfairLock(initialState: false)
        let fixture = SystemMediaFixture(MonitorNowPlayingState(phase: .playing, title: "Fixture"))
        let monitor = NowPlayingMonitor(registersObservers: false, runningBundleIDs: {
            let first = didEnter.withLock { entered in
                let first = !entered
                entered = true
                return first
            }
            if first {
                entered.signal()
                _ = release.wait(timeout: .now() + 3)
            }
            return []
        }, systemProvider: { try await fixture.read() }, systemPollInterval: .milliseconds(10))
        let source = NowPlayingSource(monitor: monitor, artworkFetcher: offlineFetcher(), audioReactive: false, audioDemand: { _ in })
        let waitForSetup: @Sendable () -> Bool = { entered.wait(timeout: .now() + 3) == .success }
        let stopper = Task.detached {
            guard waitForSetup() else {
                release.signal()
                return false
            }
            await source.stop()
            release.signal()
            return true
        }
        await source.start(sink: RecordingNowPlayingSink())
        let stoppedDuringSetup = await stopper.value
        try #require(stoppedDuringSetup, "The subscription must reach the controlled setup boundary")
        let readsAfterStart = await fixture.reads
        try await Task.sleep(for: .milliseconds(80))
        let readsAfterSettling = await fixture.reads
        await source.stop()
        #expect(readsAfterSettling == readsAfterStart, "A source stopped during setup left its subscriber polling")
    }

    @MainActor
    @Test("System playback reaches the source sink, falls back on failure, and stops with its last subscriber")
    func systemPlaybackAndFallback() async throws {
        var external = MonitorNowPlayingState(phase: .playing, title: "Local test media")
        external.playerBundleID = "com.colliderli.iina"
        external.isSystemMedia = true
        let fixture = SystemMediaFixture(external)
        let monitor = NowPlayingMonitor(registersObservers: false, runningBundleIDs: { [] },
                                        systemProvider: { try await fixture.read() }, systemPollInterval: .milliseconds(10))
        let source = NowPlayingSource(monitor: monitor, artworkFetcher: offlineFetcher(), audioReactive: false, audioDemand: { _ in })
        let sink = RecordingNowPlayingSink()
        await source.start(sink: sink)
        let appeared = await waitUntil { sink.box.states.last?.title == external.title }
        try #require(appeared)
        #expect(sink.box.states.last?.isSystemMedia == true)
        monitor.ingest(name: Fixture.spotifyName, userInfo: Fixture.spotifyPlaying)
        #expect(monitor.currentState.playerBundleID == "com.colliderli.iina")

        await fixture.set(nil, failing: true)
        let fellBack = await waitUntil { sink.box.states.last?.playerBundleID == "com.spotify.client" }
        try #require(fellBack, "A failed system reader must release its stale track to the legacy source")
        external.phase = .paused
        await fixture.set(external)
        let recovered = await waitUntil { monitor.currentState.playerBundleID == "com.spotify.client" }
        #expect(recovered)
        monitor.ingest(name: Fixture.spotifyName, userInfo: Fixture.spotifyPaused)
        let paused = await waitUntil { sink.box.states.last?.playerBundleID == "com.colliderli.iina" }
        try #require(paused)
        await fixture.set(nil)
        let emptyFallback = await waitUntil { sink.box.states.last?.playerBundleID == "com.spotify.client" }
        try #require(emptyFallback)

        await source.stop()
        let reads = await fixture.reads
        try await Task.sleep(for: .milliseconds(80))
        #expect(await fixture.reads == reads, "Closing the last consumer must stop spawning system queries")
        external.phase = .playing
        external.title = "Restarted local media"
        await fixture.set(external)
        await source.start(sink: sink)
        let restarted = await waitUntil { sink.box.states.last?.title == external.title }
        #expect(restarted)
        await source.stop()
    }

    @MainActor
    @Test("A matching legacy track fills missing system timeline fields without changing the source")
    func matchingLegacyTimelineFillsSystemGaps() async throws {
        var external = MonitorNowPlayingState(phase: .playing, title: "Same Track", artist: "Artist", album: "Album")
        external.playerBundleID = "com.spotify.client"
        external.isSystemMedia = true
        let fixture = SystemMediaFixture(external)
        let monitor = NowPlayingMonitor(registersObservers: false, runningBundleIDs: { [] },
                                        systemProvider: { try await fixture.read() }, systemPollInterval: .milliseconds(10))
        let source = NowPlayingSource(monitor: monitor, artworkFetcher: offlineFetcher(), audioReactive: false, audioDemand: { _ in })
        let sink = RecordingNowPlayingSink()
        await source.start(sink: sink)
        let appeared = await waitUntil { monitor.currentState.isSystemMedia == true }
        try #require(appeared)
        monitor.ingest(name: Fixture.spotifyName, userInfo: [
            "Name": "Same Track", "Artist": "Artist", "Album": "Album", "Player State": "Playing",
            "Duration": 300_000, "Playback Position": 42.0, "Track ID": "spotify:track:shared",
        ])
        let filled = await waitUntil { sink.box.states.last?.duration == 300 && sink.box.states.last?.position == 42 }
        #expect(filled)
        #expect(monitor.currentState.isSystemMedia == true)
        #expect(monitor.currentState.trackID == "spotify:track:shared")
        external.album = "Other Album"
        await fixture.set(external)
        let changed = await waitUntil { monitor.currentState.album == "Other Album" }
        try #require(changed)
        #expect(monitor.currentState.duration == nil, "A different album must not inherit a same-titled track's timeline")
        await source.stop()
    }

    @MainActor
    @Test("A player's Playing notification for the paused system track keeps the system identity and artwork")
    func playingNotificationForPausedSystemTrackKeepsSystemFrame() async throws {
        var external = MonitorNowPlayingState(phase: .paused, title: "ENDROLL", artist: "Yoohei Kawakami", album: "ENDROLL")
        external.playerBundleID = "com.apple.Music"
        external.isSystemMedia = true
        external.trackID = "system:com.apple.Music:1"
        external.artwork = Data([0x01, 0x02])
        let fixture = SystemMediaFixture(external)
        let monitor = NowPlayingMonitor(registersObservers: false, runningBundleIDs: { [] },
                                        systemProvider: { try await fixture.read() }, systemPollInterval: .seconds(30))
        let source = NowPlayingSource(monitor: monitor, artworkFetcher: offlineFetcher(), audioReactive: false, audioDemand: { _ in })
        let sink = RecordingNowPlayingSink()
        await source.start(sink: sink)
        let appeared = await waitUntil { monitor.currentState.isSystemMedia == true }
        try #require(appeared)

        monitor.ingest(name: Fixture.musicName, userInfo: Fixture.musicPlaying)
        let state = monitor.currentState
        #expect(state.phase == .playing)
        #expect(state.trackID == "system:com.apple.Music:1", "Swapping to the notification frame changes the track key")
        #expect(state.artwork == Data([0x01, 0x02]), "Swapping to the notification frame drops the artwork")
        await source.stop()
    }

    @MainActor
    @Test("Music queries its authorized playhead only while the selected system track has no position")
    func missingSystemPositionUsesMusicFallback() async throws {
        var external = MonitorNowPlayingState(phase: .playing, title: "Music Track", duration: 300)
        external.playerBundleID = "com.apple.Music"
        external.isSystemMedia = true
        let fixture = SystemMediaFixture(external)
        let monitor = NowPlayingMonitor(registersObservers: false, runningBundleIDs: { [] },
                                        systemProvider: { try await fixture.read() }, systemPollInterval: .milliseconds(10))
        let polls = OSAllocatedUnfairLock(initialState: 0)
        let source = NowPlayingSource(
            monitor: monitor, artworkFetcher: offlineFetcher(), audioReactive: false, audioDemand: { _ in },
            positionProvider: { _ in polls.withLock { $0 += 1 }; return 25 }, positionPollInterval: .milliseconds(10)
        )
        let sink = RecordingNowPlayingSink()
        await source.start(sink: sink)
        let filled = await waitUntil { sink.box.states.last?.position == 25 }
        #expect(filled)
        #expect(sink.box.states.last?.isSystemMedia == true)
        external.position = 45
        await fixture.set(external)
        let authoritative = await waitUntil { sink.box.states.last?.position == 45 }
        try #require(authoritative)
        let count = polls.withLock { $0 }
        try await Task.sleep(for: .milliseconds(80))
        #expect(polls.withLock { $0 } == count, "A usable system position must stop legacy position polling")
        await source.stop()
    }

    @MainActor
    @Test("A system request issued before player termination cannot restore the departed track")
    func playerTerminationRejectsInFlightSystemSnapshot() async throws {
        let gate = Gate()
        let reads = OSAllocatedUnfairLock(initialState: 0)
        var external = MonitorNowPlayingState(phase: .playing, title: "Departed Track")
        external.playerBundleID = "com.colliderli.iina"
        external.isSystemMedia = true
        let stale = external
        let monitor = NowPlayingMonitor(registersObservers: false, runningBundleIDs: { [] }, systemProvider: {
            let request = reads.withLock { $0 += 1; return $0 }
            if request == 1 {
                await gate.wait()
                return stale
            }
            return nil
        }, systemPollInterval: .milliseconds(10))
        let box = NowPlayingStateBox()
        let id = UUID()
        monitor.subscribe(id: id) { _, state in box.append(state) }
        defer { monitor.unsubscribe(id: id) }
        let requested = await waitUntil { reads.withLock { $0 } == 1 }
        try #require(requested)
        monitor.playerDidTerminate(bundleID: "com.colliderli.iina")
        await gate.open()
        let settled = await waitUntil { reads.withLock { $0 } >= 2 }
        try #require(settled)
        #expect(!box.states.contains { $0.title == "Departed Track" })
    }

    #if !LITE_BUILD
    @Test("System payload validation preserves usable timelines and rejects stale loop anchors")
    func payloadTimeline() async throws {
        let raw = Data(#"{"bundleID":"com.colliderli.iina","title":"Track","playing":true,"duration":120,"position":42,"timestamp":1000,"rate":1}"#.utf8)
        var payload = try JSONDecoder().decode(NowPlayingSystemSnapshot.self, from: raw)
        let state = try #require(payload.state(now: 1002))
        #expect(state.position == 42)
        #expect(state.positionSampledAt == 1000)
        #expect(state.isSystemMedia == true)
        #expect(state.mediaKind == nil)
        #expect(state.mediaOrigin == nil)
        payload.controlID = "owned-player"
        payload.commands = [5, 4, 1, 0, 999]
        payload.mediaKind = "video"
        payload.origin = "web"
        let video = try #require(payload.state(now: 1002))
        #expect(video.mediaKind == .video)
        #expect(video.mediaOrigin == .web)
        #expect(video.systemCommands == [0, 1, 4, 5])
        payload.mediaKind = "unrecognized"
        payload.origin = "unrecognized"
        #expect(payload.state(now: 1002)?.mediaKind == nil)
        #expect(payload.state(now: 1002)?.mediaOrigin == nil)
        payload.rate = 2
        let fast = try #require(payload.state(now: 1002))
        #expect(fast.position == 46)
        #expect(fast.positionSampledAt == 1002)
        #expect(NowPlayingWidgetLayout.interpolatedPosition(state: fast, now: Date(timeIntervalSince1970: 1003)) == 48)
        #expect(WPESceneMediaTimeline.interpolated(from: fast, now: 1003)?.position == 48)
        payload.rate = 1
        #expect(payload.state(now: 1200)?.position == nil)
        payload.title = "  "
        #expect(payload.state(now: 1002) == nil)
        let bridge = NowPlayingSystemBridge(query: { requestsArtwork in
            if requestsArtwork {
                throw URLError(.timedOut)
            }
            return raw
        })
        let first = try await bridge.snapshot()
        let withoutCover = try await bridge.snapshot()
        #expect(first?.title == "Track")
        #expect(withoutCover?.title == "Track", "A failed cover query must not discard valid system metadata")
    }

    @Test("A new artwork identifier for the same track keeps the cover until the replacement lands")
    func artworkRevisionKeepsCover() async throws {
        actor Payload {
            var artworkID = "cover-1"
            var title = "Track"
            func set(artworkID: String? = nil, title: String? = nil) {
                if let artworkID {
                    self.artworkID = artworkID
                }
                if let title {
                    self.title = title
                }
            }

            func json(artwork: Bool) -> Data {
                let cover = artwork ? #","artwork":"AQI=""# : ""
                return Data(#"{"bundleID":"com.apple.Music","title":"\#(title)","playing":true,"trackID":"1","artworkID":"\#(artworkID)"\#(cover)}"#.utf8)
            }
        }
        let payload = Payload()
        let bridge = NowPlayingSystemBridge(query: { await payload.json(artwork: $0) })
        _ = try await bridge.snapshot()
        #expect(try await bridge.snapshot()?.artwork == Data([0x01, 0x02]))
        await payload.set(artworkID: "cover-2")
        #expect(try await bridge.snapshot()?.artwork == Data([0x01, 0x02]))
        await payload.set(title: "Other Track")
        #expect(try await bridge.snapshot()?.artwork == nil)
    }

    @Test("System Spotify identity retains its provider track URI across artwork revisions")
    func stableSystemTrackIdentity() throws {
        let raw = Data(#"{"bundleID":"com.spotify.client","title":"Track","playing":true,"trackID":"spotify:track:abc123","artworkID":"cover-1"}"#.utf8)
        var payload = try JSONDecoder().decode(NowPlayingSystemSnapshot.self, from: raw)
        let first = try #require(payload.state())
        #expect(first.trackID == "spotify:track:abc123")
        #expect(first.trackID.flatMap(NowPlayingArtworkFetcher.spotifyOEmbedURL(trackID:)) != nil)
        payload.artworkID = "cover-2"
        #expect(payload.state()?.trackID == first.trackID)
    }

    @Test("The system subprocess is bounded and terminates on cancellation")
    func subprocessLifetime() async throws {
        for _ in 0 ..< 3 {
            let data = try await NowPlayingSystemProcess().run(arguments: ["-l", "JavaScript", "-e", "'completed'"])
            #expect(String(bytes: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == "completed")
            await Task.yield()
        }
        let timed = NowPlayingSystemProcess()
        do {
            _ = try await timed.run(arguments: ["-l", "JavaScript", "-e", "delay(10)"], timeout: .milliseconds(100))
            Issue.record("A stalled script must time out")
        } catch NowPlayingSystemProcess.Failure.timedOut {}
        let cancelled = NowPlayingSystemProcess()
        let task = Task { try await cancelled.run(arguments: ["-l", "JavaScript", "-e", "delay(10)"]) }
        try await Task.sleep(for: .milliseconds(80))
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("A cancelled script must fail")
        } catch is CancellationError {}
        try await Task.sleep(for: .milliseconds(350))
        #expect(!timed.isRunning)
        #expect(!cancelled.isRunning)
        do {
            _ = try await NowPlayingSystemProcess().run(arguments: ["-l", "JavaScript", "-e", "'x'.repeat(4096)"], outputLimit: 128)
            Issue.record("Oversize output must be rejected")
        } catch NowPlayingSystemProcess.Failure.outputTooLarge {}
    }
    #endif
}

// MARK: - Playback notification fixtures

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

    /// Single-key frames: bare `Player State`, no metadata.
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

/// Suspending the main actor lets the host app's main run loop spin, which is
/// what delivers DNC notifications.
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

    /// The registration list is derived from the mapping table, so asserting the
    /// table pins what gets subscribed.
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
        let firstNewTrack = sink.box.states.first(where: { $0.artist == "Someone else entirely" })
        // The first publication precedes the new poll; a later reply may legitimately be 42 again.
        #expect(firstNewTrack?.position == nil)
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

        monitor.ingest(
            name: Fixture.spotifyName,
            userInfo: ["Name": "Stale A", "Player State": "Paused"]
        )
        #expect(await waitUntil { sink.box.titles.contains("Stale A") })

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
            overlay: MonitorOverlayConfiguration(
                enabled: false, level: .front,
                music: MusicOverlayConfiguration(enabled: true, level: .front)
            ),
            screenID: 91,
            screenFrame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        await controller.waitUntilRuntimeSettled()

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

    @MainActor
    @Test("Reduce Motion withholds audio capture and keeps the saved preference", .timeLimit(.minutes(1)))
    func reduceMotionWithholdsAudioCapture() async {
        let runtime = makeRuntime()
        let controller = OverlayController(runtime: runtime)
        controller.debugReduceMotionOverride = true
        let music = MusicOverlayConfiguration(enabled: true, level: .front)
        #expect(NowPlayingOptions(music.options).audioReactive, "precondition: the layer asks for reactive effects")
        controller.apply(
            overlay: MonitorOverlayConfiguration(enabled: false, level: .front, music: music),
            screenID: 93,
            screenFrame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        await controller.waitUntilRuntimeSettled()

        #expect(await runtime.debugActiveOptions?.music == true)
        #expect(await runtime.debugActiveOptions?.musicAudioReactive == false, "capture runs with no layer drawing it")
        #expect(controller.music(screenID: 93).map { NowPlayingOptions($0.options).audioReactive } == true)

        controller.debugReduceMotionOverride = false
        await controller.waitUntilRuntimeSettled()
        #expect(await runtime.debugActiveOptions?.musicAudioReactive == true, "turning Reduce Motion off must bring capture back")

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

        // Wait for the frame to land at the sink before checking that no second
        // transition happened.
        let published = sink.box.count
        monitor.ingest(name: Fixture.spotifyName, userInfo: Fixture.spotifyPlaying)
        #expect(await waitUntil { sink.box.count > published })
        #expect(counter.transitions == 1)
        #expect(counter.held == 1)

        monitor.ingest(name: Fixture.spotifyName, userInfo: Fixture.spotifyPaused)
        #expect(await waitUntil { counter.held == 0 })

        monitor.ingest(name: Fixture.spotifyName, userInfo: Fixture.spotifyPlaying)
        #expect(await waitUntil { counter.held == 1 })

        await source.stop()
        #expect(await waitUntil { counter.held == 0 })
    }

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
