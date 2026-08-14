import Combine
import Foundation

@MainActor
final class BoardDataModel: ObservableObject {
    @Published private(set) var snapshot: MonitorSnapshot
    /// Fed on every `push`; `reset()` on pump restart so series don't bleed across sessions.
    let historyStore: MonitorHistoryStore

    init(snapshot: MonitorSnapshot = MonitorSnapshot(), historyCapacity: Int = 120) {
        self.snapshot = snapshot
        self.historyStore = MonitorHistoryStore(capacity: historyCapacity)
    }

    func update(_ snapshot: MonitorSnapshot) {
        historyStore.ingest(snapshot)
        guard snapshot != self.snapshot else { return }
        self.snapshot = snapshot
    }

    /// Leaves the latest snapshot intact; only the accumulated series reset.
    func resetHistory() {
        historyStore.reset()
    }
}
