import Foundation
import os

/// One delay for all three wallpaper kinds; a per-kind copy is how they drift apart.
enum ManualPauseHibernation {
    static let delay: Duration = .seconds(300)
}

final class AbsenceDwell: Sendable {
    /// Token is identity, not bookkeeping: clearing the slot unconditionally would drop a replacement arm's handle.
    private struct Armed {
        let token: UInt64
        let task: Task<Void, Never>
    }

    private let slot = OSAllocatedUnfairLock<Armed?>(initialState: nil)
    private let nextToken = OSAllocatedUnfairLock<UInt64>(initialState: 0)

    var isArmed: Bool { slot.withLock { $0 != nil } }

    /// Arms the countdown if it is not already running. `attempt` returns true
    /// when it either hibernated or the request no longer applies, and false for
    /// a transient blocker — which re-dwells instead of giving up.
    func arm(
        initial: Duration,
        retry: Duration,
        attempt: @escaping @MainActor () async -> Bool
    ) {
        let token = nextToken.withLock { current -> UInt64 in
            current &+= 1
            return current
        }
        slot.withLock { current in
            guard current == nil else { return }
            current = Armed(token: token, task: Task { [weak self] in
                var delay = initial
                while true {
                    try? await Task.sleep(for: delay)
                    guard !Task.isCancelled else { return }
                    if await attempt() {
                        self?.releaseSlot(token: token)
                        return
                    }
                    if Task.isCancelled { return }
                    delay = retry
                }
            })
        }
    }

    /// Clears the slot only while it still holds this attempt.
    private func releaseSlot(token: UInt64) {
        slot.withLock { current in
            guard current?.token == token else { return }
            current = nil
        }
    }

    func cancel() {
        slot.withLock { current in
            current?.task.cancel()
            current = nil
        }
    }

    /// Cancels and waits, so a teardown cannot return while an attempt is still
    /// running against the object being torn down.
    func drain() async {
        let inFlight = slot.withLock { current -> Task<Void, Never>? in
            let task = current?.task
            current = nil
            return task
        }
        inFlight?.cancel()
        await inFlight?.value
    }
}
