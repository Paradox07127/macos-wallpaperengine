import Foundation
import LiveWallpaperCore

/// Composited-video readiness seam. Looper item rebind is not stale prep; generations cancel.
struct VideoCompositedFrameReadinessCoordinator {
    enum Action: Equatable {
        case cancelled
        case waitForItem
        case bind(itemGeneration: UInt64)
        case poll(itemGeneration: UInt64)
    }

    let expectedLifecycleGeneration: UInt64
    let expectedCompositionGeneration: UInt64

    private(set) var itemGeneration: UInt64 = 0
    private var boundItemID: ObjectIdentifier?

    init(expectedLifecycleGeneration: UInt64, expectedCompositionGeneration: UInt64) {
        self.expectedLifecycleGeneration = expectedLifecycleGeneration
        self.expectedCompositionGeneration = expectedCompositionGeneration
    }

    mutating func nextAction(
        lifecycleGeneration: UInt64,
        compositionGeneration: UInt64,
        currentItemID: ObjectIdentifier?
    ) -> Action {
        guard lifecycleGeneration == expectedLifecycleGeneration,
              compositionGeneration == expectedCompositionGeneration else {
            return .cancelled
        }
        guard let currentItemID else {
            if boundItemID != nil {
                boundItemID = nil
                itemGeneration &+= 1
            }
            return .waitForItem
        }
        guard boundItemID == currentItemID else {
            boundItemID = currentItemID
            itemGeneration &+= 1
            return .bind(itemGeneration: itemGeneration)
        }
        return .poll(itemGeneration: itemGeneration)
    }
}

@MainActor
enum WallpaperPreparationWaiter {
    static func wait(
        timeout: Duration,
        pollInterval: Duration = .milliseconds(16),
        probe: @MainActor @escaping () async -> WallpaperPreparationResult?
    ) async -> WallpaperPreparationResult {
        return await withHardDeadline(timeout: timeout) {
            while !Task.isCancelled {
                if let result = await probe() {
                    return result
                }
                do {
                    try await Task.sleep(for: pollInterval)
                } catch {
                    return .cancelled
                }
            }
            return .cancelled
        }
    }

    /// Independent clock task so an unbounded probe cannot extend the session timeout.
    static func withHardDeadline(
        timeout: Duration,
        operation: @MainActor @escaping () async -> WallpaperPreparationResult
    ) async -> WallpaperPreparationResult {
        let race = WallpaperPreparationDeadlineRace()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                race.install(continuation)
                let operationTask = Task { @MainActor in
                    let result = await operation()
                    race.resolve(result)
                }
                let deadlineTask = Task { @MainActor in
                    do {
                        try await Task.sleep(for: timeout)
                        race.resolve(.timedOut)
                    } catch {
                        // The winner cancels this task.
                    }
                }
                race.installTasks(operation: operationTask, deadline: deadlineTask)
            }
        } onCancel: {
            Task { @MainActor in
                race.resolve(.cancelled)
            }
        }
    }
}

@MainActor
private final class WallpaperPreparationDeadlineRace {
    private var continuation: CheckedContinuation<WallpaperPreparationResult, Never>?
    private var operationTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var resolvedResult: WallpaperPreparationResult?

    func install(_ continuation: CheckedContinuation<WallpaperPreparationResult, Never>) {
        if let resolvedResult {
            continuation.resume(returning: resolvedResult)
        } else {
            self.continuation = continuation
        }
    }

    func installTasks(operation: Task<Void, Never>, deadline: Task<Void, Never>) {
        guard resolvedResult == nil else {
            operation.cancel()
            deadline.cancel()
            return
        }
        operationTask = operation
        deadlineTask = deadline
    }

    func resolve(_ result: WallpaperPreparationResult) {
        guard resolvedResult == nil else { return }
        resolvedResult = result
        let continuation = continuation
        self.continuation = nil
        operationTask?.cancel()
        deadlineTask?.cancel()
        operationTask = nil
        deadlineTask = nil
        continuation?.resume(returning: result)
    }
}

/// One-shot callback bridge for prep; late callbacks ignored so deadline winners unblock.
@MainActor
final class WallpaperPreparationContinuationGate<Value: Sendable> {
    private enum State {
        case pending
        case resolved(Value)
    }

    private var continuation: CheckedContinuation<Value, Never>?
    private var state: State = .pending

    func install(_ continuation: CheckedContinuation<Value, Never>) {
        switch state {
        case .pending:
            self.continuation = continuation
        case .resolved(let value):
            continuation.resume(returning: value)
        }
    }

    func resolve(_ value: Value) {
        guard case .pending = state else { return }
        state = .resolved(value)
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(returning: value)
    }
}

@MainActor
enum WallpaperSessionTransaction {
    static func prepareAndCommit(
        _ candidate: any WallpaperRuntimeSession,
        to screen: Screen,
        replacing expected: (any WallpaperRuntimeSession)?,
        timeout: Duration,
        isStillCurrent: @MainActor () -> Bool,
        prepare: (@MainActor (
            any WallpaperRuntimeSession,
            Duration
        ) async -> WallpaperPreparationResult)? = nil,
        beforeCommit: @MainActor () -> Bool = { true },
        afterCommit: @MainActor () -> Void = {}
    ) async -> WallpaperPreparationResult {
        // Candidate windows render behind the live session for first-frame readiness.
        if candidate.wallpaperType != .video {
            candidate.show()
        }
        let result = await WallpaperPreparationWaiter.withHardDeadline(timeout: timeout) {
            if let prepare {
                await prepare(candidate, timeout)
            } else {
                await candidate.prepareForDisplay(timeout: timeout)
            }
        }
        guard result == .ready else {
            candidate.cleanup()
            return result
        }
        guard !Task.isCancelled, isStillCurrent() else {
            candidate.cleanup()
            return .cancelled
        }
        candidate.show()
        var didAttemptCommit = false
        var commitAccepted = false
        guard screen.installRuntimeSession(
            candidate,
            replacing: expected,
            beforeInstall: {
                didAttemptCommit = true
                commitAccepted = beforeCommit()
                return commitAccepted
            }
        ) else {
            candidate.cleanup()
            return didAttemptCommit && !commitAccepted ? .failed : .cancelled
        }
        afterCommit()
        return .ready
    }
}

/// Candidate failure publish policy: cancellation is not user-visible; only current proposals publish.
enum WallpaperCandidateErrorPolicy {
    static func errorToPublish(
        _ result: WallpaperPreparationResult,
        isStillCurrent: Bool,
        candidateError: WallpaperRuntimeError?,
        fallbackWallpaperType: WallpaperType
    ) -> WallpaperRuntimeError? {
        guard shouldPublish(result, isStillCurrent: isStillCurrent) else {
            return nil
        }
        return candidateError ?? .wallpaperPreparationFailed(
            type: fallbackWallpaperType,
            timedOut: result == .timedOut
        )
    }

    static func shouldPublish(
        _ result: WallpaperPreparationResult,
        isStillCurrent: Bool
    ) -> Bool {
        switch result {
        case .failed, .timedOut:
            return isStillCurrent
        case .ready, .cancelled:
            return false
        }
    }
}
