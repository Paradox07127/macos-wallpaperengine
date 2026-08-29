import Combine
import Foundation

@MainActor
final class DataModel: ObservableObject {
    @Published private(set) var snapshot: MonitorSnapshot
    /// Fed on every `push`; `reset()` on pump restart so series don't bleed across sessions.
    ///
    /// Shared across displays when the caller passes one in. Every display is
    /// pushed the same snapshot from the same broker, so a store per display
    /// held N copies of one series — and worse, they drifted: a hidden display
    /// stops being pushed, so its history grew a hole the visible one didn't
    /// have, and the same widget on two screens drew two different charts.
    /// `ingest` already drops a timestamp it has seen, so N hosts feeding one
    /// store record one sample.
    let historyStore: MonitorHistoryStore

    init(
        snapshot: MonitorSnapshot = MonitorSnapshot(),
        historyCapacity: Int = 120,
        historyStore: MonitorHistoryStore? = nil
    ) {
        self.snapshot = snapshot
        self.historyStore = historyStore ?? MonitorHistoryStore(capacity: historyCapacity)
    }

    func update(_ snapshot: MonitorSnapshot) {
        historyStore.ingest(snapshot)
        guard snapshot != self.snapshot else { return }
        self.snapshot = snapshot
    }
}
