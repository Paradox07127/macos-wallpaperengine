#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import Testing

/// The feed is the only now-playing path a scene wallpaper has, and it was
/// covered only indirectly (through `WPESceneMediaEventDispatchTests`, which
/// exercises the dispatcher on the far side). Its own three contracts —
/// fan-out, replay, and demand ref-counting — had nothing pinning them.
///
/// Every test builds its own feed rather than touching `.shared`, and runs with
/// `startsRealSourceForTesting = false`: a real `NowPlayingSource` reads the
/// user's library, which a headless shard must never do.
@MainActor
@Suite("Scene now-playing feed: fan-out, replay, demand")
struct WPEEnrichedNowPlayingFeedTests {
    /// The feed's handler is `@Sendable`, so a test cannot append to a local
    /// `var` from inside it. Deliveries are in fact synchronous on the main
    /// actor, but the type system does not know that — the lock is what makes
    /// the `@unchecked Sendable` sound rather than an assumption about timing.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(ordinal: UInt64, title: String)] = []

        var ordinals: [UInt64] {
            lock.withLock { entries.map(\.ordinal) }
        }

        var titles: [String] {
            lock.withLock { entries.map(\.title) }
        }

        func record(_ ordinal: UInt64, _ state: MonitorNowPlayingState) {
            lock.withLock { entries.append((ordinal, state.title)) }
        }
    }

    private static func makeFeed() -> WPEEnrichedNowPlayingFeed {
        let feed = WPEEnrichedNowPlayingFeed()
        feed.startsRealSourceForTesting = false
        return feed
    }

    private static func track(_ title: String) -> MonitorNowPlayingState {
        MonitorNowPlayingState(phase: .playing, title: title)
    }

    @Test("Every subscriber sees the same state under one ordinal")
    func fansOutToEverySubscriber() {
        let feed = Self.makeFeed()
        let first = Recorder()
        let second = Recorder()
        feed.subscribe(id: UUID()) { first.record($0, $1) }
        feed.subscribe(id: UUID()) { second.record($0, $1) }

        feed.deliverForTesting(Self.track("A"))
        feed.deliverForTesting(Self.track("B"))

        #expect(first.titles == ["A", "B"])
        #expect(second.titles == ["A", "B"])
        #expect(
            first.ordinals == second.ordinals,
            "the same push reached the two subscribers under different ordinals"
        )
        #expect(first.ordinals == [1, 2], "ordinals must advance once per push, not once per subscriber")
    }

    @Test("A scene loaded mid-song is replayed the current track immediately")
    func replaysTheLatestStateOnSubscribe() {
        let feed = Self.makeFeed()
        feed.subscribe(id: UUID()) { _, _ in }
        feed.deliverForTesting(Self.track("A"))

        let replayed = Recorder()
        feed.subscribe(id: UUID()) { replayed.record($0, $1) }

        #expect(replayed.titles == ["A"], "a late subscriber waited for the next track change")
        #expect(replayed.ordinals == [1], "the replay invented an ordinal instead of reusing the live one")
    }

    @Test("A nil push is not a track state and does not advance the ordinal")
    func nilPushIsNotATrack() {
        let feed = Self.makeFeed()
        let received = Recorder()
        feed.subscribe(id: UUID()) { received.record($0, $1) }

        feed.deliverForTesting(nil)
        feed.deliverForTesting(Self.track("A"))

        #expect(received.ordinals == [1], "a nil teardown push was forwarded as a track")
    }

    @Test("The source runs exactly while at least one subscriber wants it")
    func demandIsReferenceCounted() {
        let feed = Self.makeFeed()
        let first = UUID()
        let second = UUID()
        #expect(!feed.isSourceRunningForTesting)

        feed.subscribe(id: first) { _, _ in }
        #expect(feed.isSourceRunningForTesting)
        feed.subscribe(id: second) { _, _ in }
        #expect(feed.isSourceRunningForTesting)

        feed.unsubscribe(id: first)
        #expect(feed.isSourceRunningForTesting, "the source stopped while a subscriber still wanted it")
        feed.unsubscribe(id: second)
        #expect(!feed.isSourceRunningForTesting, "the last unsubscribe left the source running")
    }

    @Test("A subscriber arriving after the source stopped is not replayed a stale track")
    func stoppingClearsTheReplayedState() {
        let feed = Self.makeFeed()
        let first = UUID()
        feed.subscribe(id: first) { _, _ in }
        feed.deliverForTesting(Self.track("A"))
        feed.unsubscribe(id: first)

        let replayed = Recorder()
        feed.subscribe(id: UUID()) { replayed.record($0, $1) }

        #expect(replayed.titles.isEmpty, "a track from before the quiet period was replayed as current")
    }

    @Test("Pushes that arrive with no demand are dropped")
    func pushesWithoutDemandAreDropped() {
        let feed = Self.makeFeed()
        let id = UUID()
        let received = Recorder()
        feed.subscribe(id: id) { received.record($0, $1) }
        feed.unsubscribe(id: id)

        feed.deliverForTesting(Self.track("late"))

        let replayed = Recorder()
        feed.subscribe(id: UUID()) { replayed.record($0, $1) }
        #expect(received.titles.isEmpty)
        #expect(replayed.titles.isEmpty, "a push that arrived after teardown became the replayed state")
    }
}
#endif
