#if !LITE_BUILD
import Foundation
/// Nonblocking ownership pool for CPU-mutable logical-frame resources.
final class WPEMetalFrameSubmissionPool: @unchecked Sendable {
    private let semaphore: DispatchSemaphore
    private let lock = NSLock()
    private var freeSlots: [Int]

    init(slotCount: Int) {
        precondition(slotCount > 0)
        semaphore = DispatchSemaphore(value: slotCount)
        freeSlots = Array(0..<slotCount)
    }

    func tryAcquire() -> WPEMetalFrameSubmissionLease? {
        guard semaphore.wait(timeout: .now()) == .success else { return nil }
        lock.lock()
        let slot = freeSlots.removeFirst()
        lock.unlock()
        return WPEMetalFrameSubmissionLease(slot: slot, pool: self)
    }

    fileprivate func release(slot: Int) {
        lock.lock()
        let wasAlreadyFree = freeSlots.contains(slot)
        if !wasAlreadyFree {
            freeSlots.append(slot)
            freeSlots.sort()
        }
        lock.unlock()
        if !wasAlreadyFree {
            semaphore.signal()
        }
    }
}

/// Holds one resource slot until a logical frame seals and all buffers finish.
final class WPEMetalFrameSubmissionLease: @unchecked Sendable {
    let slot: Int

    private let pool: WPEMetalFrameSubmissionPool
    private let lock = NSLock()
    private var pendingSubmissionCount = 0
    private var isSealed = false
    private var didRelease = false

    fileprivate init(slot: Int, pool: WPEMetalFrameSubmissionPool) {
        self.slot = slot
        self.pool = pool
    }

    func registerSubmission() -> WPEMetalFrameSubmissionCompletion {
        lock.lock()
        precondition(!isSealed, "Cannot register a Metal submission after sealing its logical frame")
        pendingSubmissionCount += 1
        lock.unlock()
        return WPEMetalFrameSubmissionCompletion(lease: self)
    }

    func seal() {
        lock.lock()
        isSealed = true
        let shouldRelease = markReleasedIfReady()
        lock.unlock()
        if shouldRelease { pool.release(slot: slot) }
    }

    fileprivate func completeSubmission() {
        lock.lock()
        if pendingSubmissionCount > 0 {
            pendingSubmissionCount -= 1
        }
        let shouldRelease = markReleasedIfReady()
        lock.unlock()
        if shouldRelease { pool.release(slot: slot) }
    }

    private func markReleasedIfReady() -> Bool {
        guard isSealed, pendingSubmissionCount == 0, !didRelease else { return false }
        didRelease = true
        return true
    }

    deinit {
        seal()
    }
}

/// Exactly-once command-buffer token; deinit is its fail-safe.
final class WPEMetalFrameSubmissionCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var lease: WPEMetalFrameSubmissionLease?

    fileprivate init(lease: WPEMetalFrameSubmissionLease) {
        self.lease = lease
    }

    func complete() {
        lock.lock()
        let lease = self.lease
        self.lease = nil
        lock.unlock()
        lease?.completeSubmission()
    }

    deinit {
        complete()
    }
}

/// Aggregates the producer chain for the final texture actually presented.
/// The resource lease separately covers speculative and stable fail-close work.
final class WPEMetalFrameProductionCompletion: @unchecked Sendable {
    typealias Observer = @Sendable (Bool) -> Void

    private let lock = NSLock()
    private var pendingSubmissionCount = 0
    private var isSealed = false
    private var didFail = false
    private var result: Bool?
    private var observers: [Observer] = []

    func registerSubmission() -> WPEMetalFrameProductionSubmission {
        lock.lock()
        precondition(!isSealed, "Cannot register a Metal producer after sealing its frame")
        pendingSubmissionCount += 1
        lock.unlock()
        return WPEMetalFrameProductionSubmission(production: self)
    }

    func seal() {
        let resolution: (Bool, [Observer])?
        lock.lock()
        isSealed = true
        resolution = resolveIfReady()
        lock.unlock()
        notify(resolution)
    }

    func observe(_ observer: @escaping Observer) {
        let resolved: Bool?
        lock.lock()
        if let result {
            resolved = result
        } else {
            observers.append(observer)
            resolved = nil
        }
        lock.unlock()
        if let resolved { observer(resolved) }
    }

    fileprivate func completeSubmission(succeeded: Bool) {
        let resolution: (Bool, [Observer])?
        lock.lock()
        if pendingSubmissionCount > 0 {
            pendingSubmissionCount -= 1
            didFail = didFail || !succeeded
        }
        resolution = resolveIfReady()
        lock.unlock()
        notify(resolution)
    }

    private func resolveIfReady() -> (Bool, [Observer])? {
        guard isSealed, pendingSubmissionCount == 0, result == nil else { return nil }
        let succeeded = !didFail
        result = succeeded
        let observers = self.observers
        self.observers.removeAll(keepingCapacity: false)
        return (succeeded, observers)
    }

    private func notify(_ resolution: (Bool, [Observer])?) {
        guard let (succeeded, observers) = resolution else { return }
        for observer in observers { observer(succeeded) }
    }

    deinit {
        seal()
    }
}

/// Exactly-once producer token; an abandoned token fails closed.
final class WPEMetalFrameProductionSubmission: @unchecked Sendable {
    private let lock = NSLock()
    private var production: WPEMetalFrameProductionCompletion?

    fileprivate init(production: WPEMetalFrameProductionCompletion) {
        self.production = production
    }

    func complete(succeeded: Bool) {
        lock.lock()
        let production = self.production
        self.production = nil
        lock.unlock()
        production?.completeSubmission(succeeded: succeeded)
    }

    deinit {
        complete(succeeded: false)
    }
}
#endif
