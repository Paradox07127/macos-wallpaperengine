import Foundation
import os

/// Hub (single writer) → per-display renderers (many readers, own cadence).
final class SnapshotBroker: Sendable {
    private struct State {
        var latest: MonitorSnapshot?
        var generation: UInt64 = 0
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    func publish(_ snapshot: MonitorSnapshot) {
        lock.withLock { state in
            state.latest = snapshot
            state.generation &+= 1
        }
    }

    /// Strictly newer than `generation`, or nil if already current / nothing published.
    func latest(after generation: UInt64) -> (snapshot: MonitorSnapshot, generation: UInt64)? {
        lock.withLock { state in
            guard let snapshot = state.latest, state.generation > generation else {
                return nil
            }
            return (snapshot, state.generation)
        }
    }

    /// Generation only — seed a reader cursor without taking a snapshot.
    var currentGeneration: UInt64 {
        lock.withLock { $0.generation }
    }

    /// Drop data and bump generation so new renderers can't replay a stale snapshot.
    func clear() {
        lock.withLock { state in
            state.latest = nil
            state.generation &+= 1
        }
    }
}
