import Foundation

/// Bounds how many preview downloads + decodes are in flight at once. Every tile that scrolls into view starts its own fetch and detached decode; the cooperative pool caps how many *execute* in parallel, but nothing capped how many were started, so sweeping through several Workshop pages left dozens of downloads competing for the same connection and dozens of decoded posters alive at once.
/// Callers must check `Task.isCancelled` as their first act inside `run` — abandoned work then drains its queue slot in nanoseconds instead of making the tiles the reader is actually looking at wait behind it.
/// Cancelling a *queued* waiter withdraws it from the queue: it used to stay in line (a `CheckedContinuation` isn't withdrawn when its task is cancelled), so a fling through several pages left a wall of abandoned waiters that newly visible tiles had to queue behind, each waking only to find it cancelled — turning "too much work at once" into the worse "the tile you're looking at waits for work nobody wants".
/// Not reentrant: work submitted here must never submit to the same gate, or a full gate deadlocks against itself.
actor PreviewWorkGate {
    /// Wide enough to keep several connections and cores busy, narrow enough
    /// that a fling through ten pages does not queue two hundred downloads.
    static let shared = PreviewWorkGate(limit: 4)

    private let limit: Int
    private var active = 0
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var queue: [UUID] = []
    /// Cancellation can arrive before the continuation is registered. The actor
    /// serialises both, so recording the id here closes that window.
    private var cancelledBeforeRegistration: Set<UUID> = []
    /// Ids currently inside `acquire`. Without it, a cancel arriving *after* the
    /// waiter was already admitted looks identical to one arriving before it
    /// registered, and the id would be filed under
    /// `cancelledBeforeRegistration` forever — a set that only ever grew.
    private var pending: Set<UUID> = []

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    /// Test seam: how many slots are occupied right now.
    var activeCount: Int { active }
    /// Test seam: how many callers are still queued.
    var queuedCount: Int { queue.count }
    /// Test seam: cancellation bookkeeping that has not been reclaimed.
    var retainedCancellationIDs: Int { cancelledBeforeRegistration.count + pending.count }

    func run<T: Sendable>(_ work: @Sendable () async -> T) async -> T {
        // Timed on its own so a trace can tell "waiting behind other tiles"
        // apart from "this one is slow" — the distinction the cap exists to
        // control. The work itself is timed by whoever submitted it.
        let queued = PreviewSignpost.begin("gate.queued")
        // A caller cancelled while queued is resumed without a slot, so it must
        // not release one on the way out.
        let holdsSlot = await acquire()
        PreviewSignpost.end("gate.queued", queued)
        let result = await work()
        if holdsSlot { release() }
        return result
    }

    private func acquire() async -> Bool {
        if active < limit {
            active += 1
            return true
        }
        let id = UUID()
        pending.insert(id)
        let admitted = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                if cancelledBeforeRegistration.remove(id) != nil {
                    continuation.resume(returning: false)
                    return
                }
                waiters[id] = continuation
                queue.append(id)
            }
        } onCancel: {
            Task { await self.withdraw(id) }
        }
        pending.remove(id)
        cancelledBeforeRegistration.remove(id)
        return admitted
    }

    private func withdraw(_ id: UUID) {
        // Already resumed — by `release` handing over a slot, or by an earlier
        // withdrawal. Nothing to do, and nothing to remember.
        guard pending.contains(id) else { return }
        guard let continuation = waiters.removeValue(forKey: id) else {
            // Cancelled before it got as far as registering.
            cancelledBeforeRegistration.insert(id)
            return
        }
        queue.removeAll { $0 == id }
        continuation.resume(returning: false)
    }

    private func release() {
        // Hand the slot straight to the next live waiter rather than decrementing
        // and re-incrementing, so `active` never dips and lets a third party in.
        while !queue.isEmpty {
            let next = queue.removeFirst()
            if let continuation = waiters.removeValue(forKey: next) {
                continuation.resume(returning: true)
                return
            }
        }
        active -= 1
    }
}
