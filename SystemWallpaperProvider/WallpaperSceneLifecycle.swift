import Foundation
import os

final class WallpaperSceneAdmission: Sendable {
    static let shared = WallpaperSceneAdmission()

    private struct State {
        var active = 0
        var leaked = 0
        var failures: [String: [Date]] = [:]
        var blocked: Set<String> = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var activeCount: Int {
        state.withLock { $0.active }
    }

    var leakedRenderThreadCount: Int {
        state.withLock { $0.leaked }
    }

    func acquire(capsule: String? = nil) throws -> Bool {
        try state.withLock { value in
            guard value.leaked == 0 else { throw Unavailable() }
            if let capsule, value.blocked.contains(capsule) {
                throw CircuitOpen()
            }
            guard value.active < 4 else { return false }
            value.active += 1
            return true
        }
    }

    func release() {
        state.withLock { $0.active -= 1 }
    }

    func recordLeakedThread() {
        state.withLock { $0.leaked += 1 }
    }

    func isBlocked(_ capsule: String) -> Bool {
        state.withLock { $0.blocked.contains(capsule) }
    }

    @discardableResult
    func recordFailure(_ capsule: String, now: Date = Date()) -> Bool {
        state.withLock { value in
            var failures = value.failures[capsule, default: []].filter { now.timeIntervalSince($0) <= 600 }
            failures.append(now)
            value.failures[capsule] = Array(failures.suffix(2))
            if failures.count >= 2 {
                value.blocked.insert(capsule)
            }
            return value.blocked.contains(capsule)
        }
    }

    struct Unavailable: Error {}
    struct CircuitOpen: Error {}
}

/// Owns cancellation and admission independently of the render actor's executor.
final class WallpaperSceneLifecycle: Sendable {
    private struct State {
        var active = true
        var ownsSlot = false
        var task: Task<Void, Never>?
        var shutdown: (@Sendable () async -> Bool)?
        var capsule: String?
        var presented = false
        var running: Bool
        var lastUpdate: ContinuousClock.Instant
        var runningWithoutFrame: Duration = .zero
        /// True between a refused admission and the next grant; that time is not the scene's own frame time.
        var waitingForSlot = false
        /// nil until the first slot is acquired; hashing and waiting for admission are not the scene's load time.
        var loadStarted: ContinuousClock.Instant?
    }

    private let state: OSAllocatedUnfairLock<State>
    private let admission: WallpaperSceneAdmission
    private let onFailure: @Sendable (String) -> Void
    private let onHealthChange: @Sendable () -> Void
    private let timer: DispatchSourceTimer

    init(running: Bool, admission: WallpaperSceneAdmission = .shared,
         now: ContinuousClock.Instant = .now,
         onHealthChange: @escaping @Sendable () -> Void = {},
         onFailure: @escaping @Sendable (String) -> Void) {
        self.admission = admission
        self.onFailure = onFailure
        self.onHealthChange = onHealthChange
        state = OSAllocatedUnfairLock(initialState: State(running: running, lastUpdate: now))
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.loomscreen.wallpaper.watchdog"))
        timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.checkDeadline() }
        timer.resume()
    }

    deinit { timer.cancel() }

    var isActive: Bool {
        state.withLock { $0.active }
    }

    func install(task: Task<Void, Never>) {
        let active = state.withLock { value in
            guard value.active else { return false }
            value.task = task
            return true
        }
        if !active {
            task.cancel()
        }
    }

    func installShutdown(_ shutdown: @escaping @Sendable () async -> Bool) {
        let active = state.withLock { value in
            guard value.active else { return false }
            value.shutdown = shutdown
            return true
        }
        if !active {
            retire(shutdown)
        }
    }

    func setCapsule(_ capsule: String) -> Bool {
        state.withLock { $0.capsule = capsule }
        if admission.isBlocked(capsule) {
            finish(failure: "scene.circuit.open")
            return false
        }
        return isActive
    }

    func acquireSlot(now: ContinuousClock.Instant = .now, timeout: Duration = .seconds(30)) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while true {
            try Task.checkCancellation()
            let acquired = try state.withLock { value in
                guard value.active else { throw CancellationError() }
                guard !value.ownsSlot else { return true }
                Self.advance(&value, now: .now)
                value.ownsSlot = try admission.acquire(capsule: value.capsule)
                value.waitingForSlot = !value.ownsSlot
                if value.ownsSlot, value.loadStarted == nil {
                    value.loadStarted = now
                }
                return value.ownsSlot
            }
            if acquired {
                return
            }
            guard ContinuousClock.now < deadline else {
                finish(failure: "scene.busy")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    func releaseSlot() {
        state.withLock { value in
            if value.ownsSlot {
                admission.release()
                value.ownsSlot = false
            }
        }
    }

    func setRunning(_ running: Bool, now: ContinuousClock.Instant = .now) {
        state.withLock { value in
            Self.advance(&value, now: now)
            value.running = running
        }
    }

    func framePresented(now: ContinuousClock.Instant = .now) {
        state.withLock { value in
            value.presented = true
            value.runningWithoutFrame = .zero
            value.lastUpdate = now
        }
    }

    private static func advance(_ value: inout State, now: ContinuousClock.Instant) {
        guard now >= value.lastUpdate else { return }
        if value.running, !value.waitingForSlot {
            value.runningWithoutFrame += value.lastUpdate.duration(to: now)
        }
        value.lastUpdate = now
    }

    func checkDeadline(now: ContinuousClock.Instant = .now) {
        finish(failure: "scene.stalled", stalledAt: now)
    }

    func finish(failure: String? = nil, stalledAt now: ContinuousClock.Instant? = nil) {
        let retired = state.withLock { value -> (Task<Void, Never>?, (@Sendable () async -> Bool)?, String?)? in
            guard value.active else { return nil }
            if let now {
                Self.advance(&value, now: now)
                let stalled = value.presented
                    ? value.running && value.runningWithoutFrame >= .seconds(10)
                    : value.loadStarted.map { $0.duration(to: now) >= .seconds(30) } ?? false
                guard stalled else { return nil }
            }
            value.active = false
            let result = (value.task, value.shutdown, value.capsule)
            value.task = nil
            value.shutdown = nil
            if value.ownsSlot {
                admission.release()
            }
            value.ownsSlot = false
            return result
        }
        guard let (task, shutdown, capsule) = retired else { return }
        timer.cancel()
        task?.cancel()
        if let failure {
            let counts = failure == "scene.stalled" || failure == "scene.load.failed"
            let blocked = counts && capsule.map { admission.recordFailure($0) } == true
            onFailure(blocked ? "scene.circuit.open" : failure)
        }
        if let shutdown {
            retire(shutdown)
        }
    }

    private func retire(_ shutdown: @escaping @Sendable () async -> Bool) {
        Task.detached { [admission, onHealthChange] in
            if await !shutdown() {
                wpxLog.fault("live scene render thread did not exit; refusing new live scenes")
                admission.recordLeakedThread()
                onHealthChange()
            }
        }
    }
}
