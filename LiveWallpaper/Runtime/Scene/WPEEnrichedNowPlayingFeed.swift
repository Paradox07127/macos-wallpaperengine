#if !LITE_BUILD
import Foundation

@MainActor
final class WPEEnrichedNowPlayingFeed: WPENowPlayingEventSource {
    static let shared = WPEEnrichedNowPlayingFeed()

    private var subscribers: [UUID: @Sendable (UInt64, MonitorNowPlayingState) -> Void] = [:]
    private var source: NowPlayingSource?
    /// `source` is nil both before the first subscriber and while a test is running without a real source.
    private var sourceIsRunning = false
    private var ordinal: UInt64 = 0
    private var latest: MonitorNowPlayingState?

    #if DEBUG
    var startsRealSourceForTesting = true

    var isSourceRunningForTesting: Bool {
        sourceIsRunning
    }

    func deliverForTesting(_ state: MonitorNowPlayingState?) {
        fanOut(state)
    }
    #endif

    private actor Sink: MonitorSnapshotSink {
        private let deliver: @MainActor @Sendable (MonitorNowPlayingState?) -> Void
        init(deliver: @escaping @MainActor @Sendable (MonitorNowPlayingState?) -> Void) {
            self.deliver = deliver
        }

        func updateSystem(_: MonitorSystemSnapshot) async {}
        func updateAgents(sourceID _: String, sessions _: [MonitorAgentSessionState]) async {}
        func updateHealth(_: MonitorSourceHealth) async {}
        func updateNowPlaying(_ state: MonitorNowPlayingState?) async {
            let deliver = deliver
            await MainActor.run { deliver(state) }
        }
    }

    func subscribe(id: UUID, handler: @escaping @Sendable (UInt64, MonitorNowPlayingState) -> Void) {
        subscribers[id] = handler
        // Same replay contract as the monitor: a scene loaded mid-song starts
        // correct instead of waiting for the next track change.
        if let latest {
            handler(ordinal, latest)
        }
        startSourceIfNeeded()
    }

    func unsubscribe(id: UUID) {
        subscribers.removeValue(forKey: id)
        if subscribers.isEmpty {
            stopSource()
        }
    }

    private func startSourceIfNeeded() {
        guard !sourceIsRunning else { return }
        sourceIsRunning = true
        #if DEBUG
        guard startsRealSourceForTesting else { return }
        #endif
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
        guard sourceIsRunning else { return }
        sourceIsRunning = false
        // Cleared with the source: a subscriber arriving after a quiet period must not be replayed a track the feed stopped following.
        latest = nil
        guard let source else { return }
        self.source = nil
        Task { await source.stop() }
    }

    private func fanOut(_ state: MonitorNowPlayingState?) {
        guard sourceIsRunning else { return }
        // A nil push (source teardown) is not a track state; the dispatcher's own diff gate handles "no track" through the phase field.
        guard let state else { return }
        ordinal &+= 1
        latest = state
        for handler in subscribers.values {
            handler(ordinal, state)
        }
    }
}
#endif
