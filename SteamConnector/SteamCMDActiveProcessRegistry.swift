import Foundation
import os

/// One per accepted connection. The client's interest in its work is the
/// connection itself: the app cancels by invalidating (`SteamConnectorClient.call`),
/// and a dead app takes its connections with it. Either way queued bodies
/// must bail and the child this connection started must be signalled — the
/// `maxQueueWait` clock alone let an abandoned download run to completion.
final class SteamConnectorCallerLiveness: Sendable {
    private struct State {
        var abandoned = false
        var ownedOperationIDs: Set<String> = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let maxQueueWait: TimeInterval

    init(maxQueueWait: TimeInterval) {
        self.maxQueueWait = maxQueueWait
    }

    /// Record before enqueueing: the run may register its child only after this connection is already gone.
    func own(operationID: String) {
        state.withLock { _ = $0.ownedOperationIDs.insert(operationID) }
    }

    /// Checked at the top of every queued body and again right before a child is spawned. False once the
    /// connection is gone, the host is exiting, or the request waited past the budget (the client has certainly timed out).
    var canContinue: Bool {
        !SteamCMDActiveProcessRegistry.hostExiting && !state.withLock { $0.abandoned }
    }

    func isLive(enqueuedAt: Date, now: Date = Date()) -> Bool {
        guard canContinue else { return false }
        return now.timeIntervalSince(enqueuedAt) <= maxQueueWait
    }

    /// The reply is on its way: a later invalidation of this connection must not signal a successor
    /// that the app started under the same operation id (dependency chains reuse one attempt id).
    func disown(operationID: String) {
        state.withLock { _ = $0.ownedOperationIDs.remove(operationID) }
    }

    /// Idempotent. `terminate` receives each operation this connection started; the registry decides whether that operation's child is the active one.
    func markAbandoned(terminate: (String) -> Void) {
        let owned = state.withLock { s -> Set<String> in
            s.abandoned = true
            return s.ownedOperationIDs
        }
        for operationID in owned {
            terminate(operationID)
        }
    }
}

enum SteamCMDDownloadLimits {
    static let maximumConcurrent = 3
}

/// Tracks all owned children; a cancel reaches only its own operation.
/// Identified by the app's own operation id, not by kind of work: a
/// kind-scoped id could arrive over XPC after the *next* same-kind run
/// registered, and kill that innocent child — exactly what "cancel, then
/// retry" does.
final class SteamCMDActiveProcessRegistry: Sendable {
    private struct Active {
        let pid: pid_t
        let hasOwnGroup: Bool
        /// `nil` for a run the app never named — a probe or an install. Only host exit signals those.
        let operationID: String?
        var cancellationRequested = false
    }

    private let state = OSAllocatedUnfairLock<[pid_t: Active]>(initialState: [:])

    /// Set once by host exit and never cleared: the serial queue would otherwise start the next
    /// queued body's child after the one that was signalled, and launchd's SIGKILL of the service
    /// leaves that child running.
    private static let hostExitState = OSAllocatedUnfairLock(initialState: false)

    static var hostExiting: Bool {
        hostExitState.withLock { $0 }
    }

    #if DEBUG
    /// The latch is process-wide; tests that raise it must lower it again.
    static func resetHostExitForTesting() {
        hostExitState.withLock { $0 = false }
    }
    #endif

    /// A child registered after this is signalled immediately by `register`.
    func register(
        pid: pid_t, hasOwnGroup: Bool, operationID: String?,
        isCancelled: () -> Bool = { false },
        kill: (pid_t, Int32) -> Int32 = { Darwin.kill($0, $1) }
    ) {
        state.withLock { $0[pid] = Active(pid: pid, hasOwnGroup: hasOwnGroup, operationID: operationID) }
        if Self.hostExiting || isCancelled() {
            _ = kill(hasOwnGroup ? -pid : pid, SIGTERM)
        }
    }

    func clear() {
        state.withLock { $0.removeAll() }
    }

    func clear(pid: pid_t) {
        _ = state.withLock { $0.removeValue(forKey: pid) }
    }

    func cancellationRequested(for pid: pid_t) -> Bool {
        state.withLock { $0[pid]?.cancellationRequested ?? false }
    }

    var cancellationRequested: Bool {
        state.withLock { $0.values.contains { $0.cancellationRequested } }
    }

    /// SIGTERM to the active child — its whole process group when it has one,
    /// same form as `spawn`'s timeout kill. Returns whether anything was
    /// signalled; `spawn`'s own EOF/timeout handling reaps the child, so no
    /// SIGKILL escalation belongs here. `operationID` must match what the
    /// child was registered under: a cancel for one operation must never
    /// signal a different one's child (review finding, both models).
    func terminateActive(operationID: String, kill: (pid_t, Int32) -> Int32 = { Darwin.kill($0, $1) }) -> Bool {
        // Signal under the lock, before a child can be reaped and its PID reused.
        state.withLockUnchecked { current in
            let matches = current.values.filter { $0.operationID == operationID }
            for active in matches {
                current[active.pid]?.cancellationRequested = true
                _ = kill(active.hasOwnGroup ? -active.pid : active.pid, SIGTERM)
            }
            return !matches.isEmpty
        }
    }

    /// Host exit only: no operation id check, because after a quit there is no later run for a stale cancel to hit.
    /// Also latches `hostExiting`, so queued bodies bail and a child that slips through `register` is signalled there.
    func terminateActiveForHostExit(kill: (pid_t, Int32) -> Int32 = { Darwin.kill($0, $1) }) -> Bool {
        Self.hostExitState.withLock { $0 = true }
        return state.withLockUnchecked { current in
            for active in current.values {
                _ = kill(active.hasOwnGroup ? -active.pid : active.pid, SIGTERM)
            }
            return !current.isEmpty
        }
    }
}

/// Cancellation belongs to the job, including time spent waiting for a worker or publication.
final class SteamCMDDownloadJob: Sendable {
    let id = UUID()
    let operationID: String
    let accountName: String
    let itemID: String
    let libraryPath: String
    private let cancelled = OSAllocatedUnfairLock(initialState: false)

    init(operationID: String, accountName: String, itemID: String, libraryPath: String) {
        self.operationID = operationID
        self.accountName = accountName.lowercased()
        self.itemID = itemID
        self.libraryPath = libraryPath
    }

    var isCancelled: Bool {
        cancelled.withLock { $0 }
    }

    func cancel() {
        cancelled.withLock { $0 = true }
    }
}

final class SteamCMDDownloadJobs: Sendable {
    private struct State {
        var jobs: [UUID: SteamCMDDownloadJob] = [:]
        var cancelledOperations: [String: Date] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func insert(_ job: SteamCMDDownloadJob) {
        state.withLock {
            $0.cancelledOperations = $0.cancelledOperations.filter { $0.value.timeIntervalSinceNow > -900 }
            if $0.cancelledOperations[job.operationID] != nil {
                job.cancel()
            }
            $0.jobs[job.id] = job
        }
    }

    func remove(_ job: SteamCMDDownloadJob) {
        _ = state.withLock { $0.jobs.removeValue(forKey: job.id) }
    }

    /// The returned IDs are signalled outside this lock by the connector.
    func cancel(operationID: String? = nil, accountName: String? = nil, itemID: String? = nil, libraryPath: String? = nil) -> [String] {
        state.withLock { current in
            if let operationID {
                current.cancelledOperations[operationID] = Date()
            }
            return current.jobs.values.compactMap { job in
                guard operationID == nil || job.operationID == operationID,
                      accountName == nil || job.accountName == accountName?.lowercased(),
                      itemID == nil || job.itemID == itemID,
                      libraryPath == nil || job.libraryPath == libraryPath else { return nil }
                job.cancel()
                return job.operationID
            }
        }
    }
}
