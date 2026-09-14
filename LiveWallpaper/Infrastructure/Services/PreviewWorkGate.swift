import Foundation

/// Callers must check `Task.isCancelled` first inside `run`. Not reentrant — a full gate deadlocks against itself.
actor PreviewWorkGate {
    static let shared = PreviewWorkGate(limit: 4)

    private let limit: Int
    private var active = 0
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var queue: [UUID] = []
    /// Cancellation can arrive before the continuation is registered. The actor
    /// serialises both, so recording the id here closes that window.
    private var cancelledBeforeRegistration: Set<UUID> = []
    /// Ids currently inside `acquire`. Without it, a cancel after admission looks like one before registration and the id would stay in `cancelledBeforeRegistration` forever.
    private var pending: Set<UUID> = []

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    var activeCount: Int { active }
    var queuedCount: Int { queue.count }
    var retainedCancellationIDs: Int { cancelledBeforeRegistration.count + pending.count }

    func run<T: Sendable>(_ work: @Sendable () async -> T) async -> T {
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
        guard pending.contains(id) else { return }
        guard let continuation = waiters.removeValue(forKey: id) else {
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
