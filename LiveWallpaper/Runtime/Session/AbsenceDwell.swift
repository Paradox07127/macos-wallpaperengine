import Foundation
import os

/// One uninterrupted-absence countdown, owned by whichever runtime is deciding
/// to tear itself down (video player, HTML view, scene session).
///
/// Video, HTML and the scene session each grew their own copy of this loop and
/// the copies drifted. Two of them treated a transient blocker — a rebuild still
/// in flight, so the thing to release does not exist *yet* — as "no longer
/// applicable" and dropped the countdown. Eligibility is pushed by
/// `ScreenManager` on policy changes rather than polled, so a dropped countdown
/// skips the rest of the absence and the runtime stays fully resident. Keeping
/// the retry in one place is the point of this type.
///
/// Not actor-isolated: `deinit` is nonisolated and has to be able to cancel.
/// The single slot is held under an unfair lock, so the class is `Sendable`
/// without an unchecked escape hatch.
final class AbsenceDwell: Sendable {
    /// Held for the whole attempt, not just the countdown, so a teardown can
    /// drain an in-flight hibernate rather than racing it.
    ///
    /// The token is an identity, not bookkeeping: an attempt that finishes may be
    /// racing a `cancel()` + `arm()` pair, and clearing the slot unconditionally
    /// would drop the *replacement*'s handle — leaving it running while
    /// `isArmed` reads false and neither `cancel()` nor `drain()` can reach it.
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
