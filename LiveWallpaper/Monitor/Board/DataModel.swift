import Combine
import Foundation

@MainActor
final class DataModel: ObservableObject {
    @Published private(set) var snapshot: MonitorSnapshot
    /// Fed on every push, `reset()` on pump restart. Shared across displays: a
    /// per-display store drifted — hidden display stalls, history gains a gap the
    /// visible one lacks, same widget draws two different charts. `ingest`
    /// dedupes seen timestamps, so N hosts writing one store record one sample.
    let historyStore: MonitorHistoryStore

    init(
        snapshot: MonitorSnapshot = MonitorSnapshot(),
        historyCapacity: Int = 120,
        historyStore: MonitorHistoryStore? = nil
    ) {
        self.snapshot = snapshot
        self.historyStore = historyStore ?? MonitorHistoryStore(capacity: historyCapacity)
    }

    /// Music consumes no system samples/history. Unrelated pump updates must not
    /// invalidate its animated view tree; the layer supplies its own clock.
    func updateNowPlaying(_ state: MonitorNowPlayingState?) {
        guard snapshot.nowPlaying != state else { return }
        var music = MonitorSnapshot()
        music.nowPlaying = state
        snapshot = music
    }

    func update(_ snapshot: MonitorSnapshot) {
        historyStore.ingest(snapshot)
        guard snapshot != self.snapshot else { return }
        self.snapshot = snapshot
    }
}
