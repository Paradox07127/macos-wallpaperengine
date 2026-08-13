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

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.id == rhs.id
                && lhs.generation == rhs.generation
                && lhs.kind == rhs.kind
        }
    }

    /// Owns filesystem-sensitive Doctor work that extends beyond one subprocess.
    /// The process runner's gate prevents simultaneous children, while this owner
    /// keeps preflight cleanup and post-process asset publication in the same FIFO
    /// transaction as the command that produced them.
    actor SteamCMDDoctorOperationCoordinator {
        static let shared = SteamCMDDoctorOperationCoordinator()

        private let gate = AsyncSemaphore(value: 1)
        private var generation: UInt64 = 0
        private var activeLease: SteamCMDDoctorOperationLease?

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
                guard activeLease == inherited else { throw CancellationError() }
                return try await operation(inherited)
            }

            try await gate.acquire()
            do {
                try Task.checkCancellation()
            } catch {
                gate.release()
                throw error
            }
            generation &+= 1
            let lease = SteamCMDDoctorOperationLease(
                id: UUID(),
                generation: generation,
                kind: kind
            )
            activeLease = lease
            defer {
                if activeLease == lease {
                    activeLease = nil
                    gate.release()
                }
            }
            return try await operation(lease)
        }

        func isCurrent(_ lease: SteamCMDDoctorOperationLease) -> Bool {
            activeLease == lease
        }
    }

    /// Suspension-based counting semaphore. Lived in the retired
    /// `SteamCMDProcessRunner` until 2026-08-02; the operation gate below is
    /// now its only user, so it moved here rather than outliving its file.
    ///
    /// `@unchecked Sendable` is carried by `lock`: every access to `permits`
    /// and `waiters` happens between its lock/unlock, and each continuation is
    /// resumed exactly once outside the critical section.
    final class AsyncSemaphore: @unchecked Sendable {
        private let lock = NSLock()
        private var permits: Int
        private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

        init(value: Int) { self.permits = value }

        func acquire() async throws {
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    lock.lock()
                    if Task.isCancelled {
                        lock.unlock()
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    if permits > 0 {
                        permits -= 1
                        lock.unlock()
                        continuation.resume()
                        return
                    }
                    waiters.append((id, continuation))
                    lock.unlock()
                }
            } onCancel: {
                lock.lock()
                guard let index = waiters.firstIndex(where: { $0.id == id }) else { lock.unlock(); return }
                let waiter = waiters.remove(at: index)
                lock.unlock()
                waiter.continuation.resume(throwing: CancellationError())
            }
        }

        func release() {
            lock.lock()
            if waiters.isEmpty {
                permits += 1
                lock.unlock()
            } else {
                let waiter = waiters.removeFirst()
                lock.unlock()
                waiter.continuation.resume()
            }
        }
    }
#endif
