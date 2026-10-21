#if !LITE_BUILD
import Foundation

enum SteamCMDDoctorOperationKind: String, Sendable {
    case appUpdate
    case assetsMutation
    case workshopDownload
}

enum SteamCMDDoctorOperationError: Error, Equatable, Sendable {
    case nestedConflict(
        active: SteamCMDDoctorOperationKind,
        requested: SteamCMDDoctorOperationKind
    )
}

struct SteamCMDDoctorOperationLease: Equatable, Sendable {
    let id: UUID
    let generation: UInt64
    let kind: SteamCMDDoctorOperationKind
}

actor SteamCMDDoctorOperationCoordinator {
    static let shared = SteamCMDDoctorOperationCoordinator()

    private let gate = AsyncSemaphore(value: SteamCMDDownloadLimits.maximumConcurrent)
    private var generation: UInt64 = 0
    private var activeLeases: [UUID: SteamCMDDoctorOperationLease] = [:]

    func withOperation<T: Sendable>(
        _ kind: SteamCMDDoctorOperationKind,
        inheriting inherited: SteamCMDDoctorOperationLease? = nil,
        _ operation: @Sendable (SteamCMDDoctorOperationLease) async throws -> T
    ) async throws -> T {
        if let inherited {
            guard inherited.kind == kind else {
                throw SteamCMDDoctorOperationError.nestedConflict(
                    active: inherited.kind,
                    requested: kind
                )
            }
            guard activeLeases[inherited.id] == inherited else { throw CancellationError() }
            return try await operation(inherited)
        }

        let permits = kind == .workshopDownload ? 1 : SteamCMDDownloadLimits.maximumConcurrent
        try await gate.acquire(permits: permits)
        do {
            try Task.checkCancellation()
        } catch {
            gate.release(permits: permits)
            throw error
        }
        generation &+= 1
        let lease = SteamCMDDoctorOperationLease(
            id: UUID(),
            generation: generation,
            kind: kind
        )
        activeLeases[lease.id] = lease
        defer {
            if activeLeases.removeValue(forKey: lease.id) != nil {
                gate.release(permits: permits)
            }
        }
        return try await operation(lease)
    }

    #if DEBUG
    /// Test-only introspection; no production reader.
    func isCurrent(_ lease: SteamCMDDoctorOperationLease) -> Bool {
        activeLeases[lease.id] == lease
    }
    #endif
}

/// `@unchecked Sendable` is carried by `lock`: every access to `permits`
/// and `waiters` happens between its lock/unlock, and each continuation is
/// resumed exactly once outside the critical section.
final class AsyncSemaphore: @unchecked Sendable {
    private let lock = NSLock()
    private var permits: Int
    private var waiters: [(id: UUID, permits: Int, continuation: CheckedContinuation<Void, Error>)] = []

    init(value: Int) {
        permits = value
    }

    func acquire(permits requested: Int = 1) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if waiters.isEmpty, permits >= requested {
                    permits -= requested
                    lock.unlock()
                    continuation.resume()
                    return
                }
                waiters.append((id, requested, continuation))
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            guard let index = waiters.firstIndex(where: { $0.id == id }) else { lock.unlock(); return }
            let waiter = waiters.remove(at: index)
            let ready = takeReadyWaiters()
            lock.unlock()
            waiter.continuation.resume(throwing: CancellationError())
            ready.forEach { $0.resume() }
        }
    }

    func release(permits released: Int = 1) {
        lock.lock()
        permits += released
        let ready = takeReadyWaiters()
        lock.unlock()
        ready.forEach { $0.resume() }
    }

    /// Called under lock; strict FIFO prevents an update being starved by downloads.
    private func takeReadyWaiters() -> [CheckedContinuation<Void, Error>] {
        var ready: [CheckedContinuation<Void, Error>] = []
        while let first = waiters.first, permits >= first.permits {
            permits -= first.permits
            ready.append(waiters.removeFirst().continuation)
        }
        return ready
    }
}
#endif
