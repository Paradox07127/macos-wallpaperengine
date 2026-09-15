import Foundation

/// Callers must check `Task.isCancelled` first inside `run`. Not reentrant — a full gate deadlocks against itself.
actor PreviewWorkGate {
    static let shared = PreviewWorkGate(limit: 4)
    static let video = PreviewWorkGate(limit: 2)
    static let html = PreviewWorkGate(limit: 2)

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

    var activeCount: Int {
        active
    }

    var queuedCount: Int {
        queue.count
    }

    var retainedCancellationIDs: Int {
        cancelledBeforeRegistration.count + pending.count
    }

    func run<T: Sendable>(_ work: @Sendable () async -> T) async -> T {
        let queued = PreviewSignpost.begin("gate.queued")
        // A caller cancelled while queued is resumed without a slot, so it must
        // not release one on the way out.
        let holdsSlot = await acquire()
        PreviewSignpost.end("gate.queued", queued)
        let result = await work()
        if holdsSlot {
            release()
        }
        return result
    }

    /// Admit synchronous filesystem work before starting its background task.
    func runDetached<Value: Sendable>(
        _ work: @escaping @Sendable () -> Value?
    ) async -> Value? {
        await run {
            guard !Task.isCancelled else { return nil }
            let worker = Task.detached(priority: .utility) {
                guard !Task.isCancelled else { return nil as Value? }
                return work()
            }
            return await withTaskCancellationHandler {
                let result = await worker.value
                return Task.isCancelled ? nil : result
            } onCancel: {
                worker.cancel()
            }
        }
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

/// A key owns one producer; cancelling one waiter must not cancel another card's result.
@MainActor
final class PreviewRequestPool<Value: Sendable> {
    private struct Request {
        let id: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<Value?, Never>]
    }

    private let gate: PreviewWorkGate
    private var requests: [String: Request] = [:]

    init(gate: PreviewWorkGate) {
        self.gate = gate
    }

    var requestCount: Int {
        requests.count
    }

    var waiterCount: Int {
        requests.values.reduce(0) { $0 + $1.waiters.count }
    }

    func value(
        for key: String,
        operation: @escaping @MainActor @Sendable () async -> Value?
    ) async -> Value? {
        let waiterID = UUID()
        let result: Value? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: nil); return }
                if requests[key] != nil {
                    requests[key]?.waiters[waiterID] = continuation
                    return
                }
                let id = UUID()
                let task = Task { @MainActor in
                    let value = await gate.run {
                        guard !Task.isCancelled else { return nil as Value? }
                        return await operation()
                    }
                    complete(key: key, id: id, value: Task.isCancelled ? nil : value)
                }
                requests[key] = Request(id: id, task: task, waiters: [waiterID: continuation])
            }
        } onCancel: {
            Task { @MainActor in self.cancel(key: key, waiterID: waiterID) }
        }
        return Task.isCancelled ? nil : result
    }

    func invalidate(_ key: String) {
        guard let request = requests.removeValue(forKey: key) else { return }
        request.task.cancel()
        for waiter in request.waiters.values {
            waiter.resume(returning: nil)
        }
    }

    func invalidateAll() {
        for key in Array(requests.keys) {
            invalidate(key)
        }
    }

    private func cancel(key: String, waiterID: UUID) {
        guard let waiter = requests[key]?.waiters.removeValue(forKey: waiterID) else { return }
        waiter.resume(returning: nil)
        if requests[key]?.waiters.isEmpty == true {
            invalidate(key)
        }
    }

    private func complete(key: String, id: UUID, value: Value?) {
        guard requests[key]?.id == id, let request = requests.removeValue(forKey: key) else { return }
        for waiter in request.waiters.values {
            waiter.resume(returning: value)
        }
    }
}
