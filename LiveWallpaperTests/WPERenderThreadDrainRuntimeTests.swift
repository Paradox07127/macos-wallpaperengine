import Foundation
import Testing
@testable import LiveWallpaper

// C4 runtime lock: autoreleased objects created by render-thread ticks must be
// released at tick cadence, never accumulate until thread exit (~0.5 MB/frame
// of fabricated growth when this regressed). Scope, established by probes on
// Darwin 27 (2026-08): CoreFoundation wraps every run-loop callout in its own
// autorelease pool, so tick workloads drain even with the explicit
// per-iteration `autoreleasepool` removed — this suite verifies the end-to-end
// cadence property on the real loop but CANNOT distinguish our pool from the
// OS's on current macOS; `runLoopUsesIterationAutoreleasePool` (source
// characterization) remains the guard for the wrapper itself.

private final class TickCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

/// NSObject so `Unmanaged.autorelease()` parks a +1 in the render thread's
/// innermost pool; `deinit` fires only when that pool pops.
private final class PoolCanary: NSObject {
    private let onDeinit: @Sendable () -> Void
    init(onDeinit: @escaping @Sendable () -> Void) { self.onDeinit = onDeinit }
    deinit { onDeinit() }
}

private final class DrainProbe: @unchecked Sendable {
    let executed = TickCounter()
    let deallocated = TickCounter()
}

/// One "frame": runs on the render thread per signaled source0 tick. Source
/// handling is what makes `CFRunLoopRunInMode(..., true)` return, so a drained
/// loop must release the canary right after this returns — a display-link
/// frame stand-in without any Metal dependency.
private func drainProbeTick(_ info: UnsafeMutableRawPointer?) {
    guard let info else { return }
    let probe = Unmanaged<DrainProbe>.fromOpaque(info).takeUnretainedValue()
    let canary = PoolCanary { probe.deallocated.increment() }
    Unmanaged.passRetained(canary).autorelease()
    probe.executed.increment()
}

private final class SourceHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedSource: CFRunLoopSource?
    private var storedLoop: CFRunLoop?

    func store(source: CFRunLoopSource, loop: CFRunLoop) {
        lock.lock()
        storedSource = source
        storedLoop = loop
        lock.unlock()
    }

    var pair: (source: CFRunLoopSource, loop: CFRunLoop)? {
        lock.lock()
        defer { lock.unlock() }
        guard let storedSource, let storedLoop else { return nil }
        return (storedSource, storedLoop)
    }
}

struct WPERenderThreadDrainRuntimeTests {

    @Test("each handled tick's autoreleased objects are released before the next tick, not at thread exit")
    func autoreleasedTickObjectsDrainPerIteration() async {
        let thread = WPERenderThread(label: "test.drain.runtime")
        let probe = DrainProbe()
        let holder = SourceHolder()

        thread.perform {
            var context = CFRunLoopSourceContext()
            context.info = Unmanaged.passUnretained(probe).toOpaque()
            context.perform = drainProbeTick
            guard let source = CFRunLoopSourceCreate(nil, 0, &context) else { return }
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .defaultMode)
            holder.store(source: source, loop: CFRunLoopGetCurrent())
        }
        let installed = await eventually { holder.pair != nil }
        #expect(installed, "tick source never installed on the render loop")
        guard let (source, loop) = holder.pair else {
            thread.shutdown()
            return
        }

        let ticks = 5
        for tick in 1 ... ticks {
            CFRunLoopSourceSignal(source)
            CFRunLoopWakeUp(loop)
            let ran = await eventually { probe.executed.count == tick }
            #expect(ran, "tick \(tick) never ran (executed=\(probe.executed.count))")
            let drained = await eventually { probe.deallocated.count == tick }
            #expect(
                drained,
                """
                tick \(tick)'s autoreleased canary is still alive after the loop pass \
                (deallocated=\(probe.deallocated.count), executed=\(probe.executed.count)) — \
                no autorelease pool is draining tick temporaries at tick cadence
                """
            )
        }

        #expect(probe.executed.count == ticks)
        #expect(probe.deallocated.count == ticks)
        thread.shutdown()
    }
}

private func eventually(
    timeout: Duration = .seconds(5),
    _ condition: @escaping @Sendable () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return condition()
}
