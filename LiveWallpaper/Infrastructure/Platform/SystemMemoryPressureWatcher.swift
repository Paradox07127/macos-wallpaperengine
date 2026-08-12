import Dispatch
import os

/// Typed process-wide memory-pressure state. The raw value intentionally matches
/// `MonitorSystemSnapshot.memPressure`'s existing wire vocabulary.
enum SystemMemoryPressureLevel: String, CaseIterable, Sendable {
    case normal
    case warning = "warn"
    case critical
}

typealias SystemMemoryPressureChangeHandler = @Sendable (SystemMemoryPressureLevel) -> Void

/// Read-only seam for consumers such as Monitor v2. Reading the app-wide
/// pressure state must not create or retain another kernel dispatch source.
protocol MemoryPressureReading: Sendable {
    func currentLevel() -> SystemMemoryPressureLevel
}

/// Kernel memory-pressure observation seam. `stop()` is not a callback barrier.
protocol MemoryPressureWatching: MemoryPressureReading {
    func start(onChange: SystemMemoryPressureChangeHandler?)
    func stop()
}

/// No-op pressure watcher for previews/tests (must not cancel process-wide source).
struct InactiveMemoryPressureWatcher: MemoryPressureWatching {
    static let shared = InactiveMemoryPressureWatcher()

    func start(onChange _: SystemMemoryPressureChangeHandler?) {}
    func stop() {}
    func currentLevel() -> SystemMemoryPressureLevel { .normal }
}

/// DispatchSourceMemoryPressure lifecycle adapter (test-injectable).
protocol MemoryPressureSourceLifecycle: AnyObject, Sendable {
    var data: DispatchSource.MemoryPressureEvent { get }

    func setEventHandler(_ handler: @escaping @Sendable () -> Void)
    func activate()
    func cancel()
}

private final class DispatchMemoryPressureSourceLifecycle: MemoryPressureSourceLifecycle, @unchecked Sendable {
    private let source: DispatchSourceMemoryPressure

    init() {
        source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical],
            queue: DispatchQueue(
                label: "com.livewallpaper.system-memory-pressure",
                qos: .utility
            )
        )
    }

    var data: DispatchSource.MemoryPressureEvent {
        source.data
    }

    func setEventHandler(_ handler: @escaping @Sendable () -> Void) {
        source.setEventHandler(handler: handler)
    }

    func activate() {
        source.activate()
    }

    func cancel() {
        source.cancel()
    }
}

/// Process-wide one-shot memory-pressure source (`shared`; stop cannot restart).
final class SystemMemoryPressureWatcher: MemoryPressureWatching {
    static let shared = SystemMemoryPressureWatcher {
        DispatchMemoryPressureSourceLifecycle()
    }

    private enum Lifecycle {
        case ready
        case active
        case cancelled
    }

    private struct State {
        var lifecycle = Lifecycle.ready
        var generation: UInt64 = 0
        var level = SystemMemoryPressureLevel.normal
        var onChange: SystemMemoryPressureChangeHandler?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let source: any MemoryPressureSourceLifecycle

    init(sourceFactory: @escaping @Sendable () -> any MemoryPressureSourceLifecycle) {
        let source = sourceFactory()
        self.source = source

        let state = state
        source.setEventHandler { [weak source] in
            guard let event = source?.data else { return }
            let nextLevel = Self.level(for: event)
            let delivery: (SystemMemoryPressureChangeHandler?, UInt64)? = state.withLock { state in
                guard state.lifecycle == .active,
                      state.level != nextLevel else { return nil }
                state.level = nextLevel
                return (state.onChange, state.generation)
            }
            guard let (callback, generation) = delivery else { return }
            // Revalidate before delivery; stop is still not a callback barrier.
            guard state.withLock({ state in
                state.lifecycle == .active && state.generation == generation
            }) else { return }
            callback?(nextLevel)
        }
    }

    deinit {
        stop()
    }

    func start(onChange: SystemMemoryPressureChangeHandler?) {
        state.withLock { state in
            guard state.lifecycle == .ready else { return }
            state.lifecycle = .active
            state.generation &+= 1
            state.onChange = onChange
            source.activate()
        }
    }

    func stop() {
        state.withLock { state in
            switch state.lifecycle {
            case .ready:
                // Activate before cancelling so a never-started dispatch source
                // is not left permanently suspended during destruction.
                state.lifecycle = .cancelled
                state.generation &+= 1
                state.onChange = nil
                source.activate()
                source.cancel()
            case .active:
                state.lifecycle = .cancelled
                state.generation &+= 1
                state.onChange = nil
                source.cancel()
            case .cancelled:
                break
            }
        }
    }

    func currentLevel() -> SystemMemoryPressureLevel {
        state.withLock { $0.level }
    }

    /// Pure precedence rule for a coalesced dispatch event. Dispatch may set more
    /// than one bit; the most severe state must always win.
    static func level(
        for event: DispatchSource.MemoryPressureEvent
    ) -> SystemMemoryPressureLevel {
        if event.contains(.critical) {
            .critical
        } else if event.contains(.warning) {
            .warning
        } else {
            .normal
        }
    }
}
