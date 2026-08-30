#if !LITE_BUILD
import Foundation

/// The enriched now-playing stream for Scene wallpapers.
///
/// `NowPlayingMonitor` carries only what the DNC notification held: no artwork
/// ever (that is fetched over the network), and no position for players whose
/// notification omits it (Apple Music). The overlay pipeline enriches through
/// its own `NowPlayingSource`, but that source is deliberately torn down with
/// the overlay — a scene wallpaper subscribed to the bare monitor therefore
/// never saw a thumbnail and never got a timeline for Apple Music.
///
/// This feed owns a second `NowPlayingSource` — the same invariant-heavy
/// enrichment (ordinal ordering, stop generations, per-track fetch tokens),
/// the same shared artwork fetcher and cache — and fans the enriched states
/// out to scene dispatchers. Demand-driven both ways: the source only runs
/// while at least one dispatcher is subscribed, and dispatchers only exist
/// for scenes that export a media handler.
@MainActor
final class WPEEnrichedNowPlayingFeed: WPENowPlayingEventSource {
    static let shared = WPEEnrichedNowPlayingFeed()

    private var subscribers: [UUID: @Sendable (UInt64, MonitorNowPlayingState) -> Void] = [:]
    private var source: NowPlayingSource?
    private var ordinal: UInt64 = 0
    private var latest: MonitorNowPlayingState?

    /// Receives the source's enriched pushes and hops them back to the main
    /// actor. The full sink protocol exists for the overlay hub; only the
    /// now-playing lane matters here.
    private actor Sink: MonitorSnapshotSink {
        private let deliver: @MainActor @Sendable (MonitorNowPlayingState?) -> Void
        init(deliver: @escaping @MainActor @Sendable (MonitorNowPlayingState?) -> Void) {
            self.deliver = deliver
        }
        func updateSystem(_ snapshot: MonitorSystemSnapshot) async {}
        func updateAgents(sourceID: String, sessions: [MonitorAgentSessionState]) async {}
        func updateHealth(_ health: MonitorSourceHealth) async {}
        func updateNowPlaying(_ state: MonitorNowPlayingState?) async {
            let deliver = deliver
            await MainActor.run { deliver(state) }
        }
    }

    func subscribe(id: UUID, handler: @escaping @Sendable (UInt64, MonitorNowPlayingState) -> Void) {
        subscribers[id] = handler
        // Same replay contract as the monitor: a scene loaded mid-song starts
        // correct instead of waiting for the next track change.
        if let latest { handler(ordinal, latest) }
        startSourceIfNeeded()
    }

    func unsubscribe(id: UUID) {
        subscribers.removeValue(forKey: id)
        if subscribers.isEmpty { stopSource() }
    }

    private func startSourceIfNeeded() {
        guard source == nil else { return }
        // `audioReactive: false` + no-op demand: the scene renderer manages its
        // own audio capture; this feed must never retain the tap.
        let source = NowPlayingSource(
            audioReactive: false,
            audioDemand: { _ in }
        )
        self.source = source
        let sink = Sink { [weak self] state in
            self?.fanOut(state)
        }
        Task { await source.start(sink: sink) }
    }

    private func stopSource() {
        guard let source else { return }
        self.source = nil
        latest = nil
        Task { await source.stop() }
    }

    private func fanOut(_ state: MonitorNowPlayingState?) {
        guard source != nil else { return }
        // A nil push (source teardown) is not a track state; the dispatcher's
        // own diff gate handles "no track" through the phase field.
        guard let state else { return }
        ordinal &+= 1
        latest = state
        for handler in subscribers.values { handler(ordinal, state) }
    }
}
#endif
