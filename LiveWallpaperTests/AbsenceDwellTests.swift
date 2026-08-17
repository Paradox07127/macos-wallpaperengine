import Foundation
import Testing
@testable import LiveWallpaper

/// The retry contract three runtimes now share. Its absence is what let a
/// re-absence during a wake rebuild skip the rest of an absence: two of the old
/// copies treated "the thing to release does not exist yet" as terminal.
@Suite("Absence dwell retry contract", .serialized)
struct AbsenceDwellTests {
    /// Counts attempts and reports a transient blocker for the first `blockFor`.
    @MainActor
    private final class Attempts {
        private(set) var count = 0
        let blockFor: Int
        init(blockFor: Int) { self.blockFor = blockFor }

        func run() -> Bool {
            count += 1
            return count > blockFor
        }
    }

    private static let tick: Duration = .milliseconds(40)

    private static func waitUntil(
        _ label: String,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if await MainActor.run(body: condition) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("timed out waiting for \(label)")
    }

    @Test("A transient blocker re-dwells instead of dropping the countdown")
    @MainActor
    func transientBlockerRetries() async throws {
        let dwell = AbsenceDwell()
        let attempts = Attempts(blockFor: 2)

        dwell.arm(initial: Self.tick, retry: Self.tick) { attempts.run() }

        try await Self.waitUntil("three attempts") { attempts.count == 3 }
        // Succeeded on the third, so the slot released itself.
        try await Self.waitUntil("slot clears after success") { !dwell.isArmed }
    }

    @Test("Arming again while already armed does not stack a second countdown")
    @MainActor
    func armIsIdempotentWhileRunning() async throws {
        let dwell = AbsenceDwell()
        let attempts = Attempts(blockFor: 0)

        dwell.arm(initial: .milliseconds(200), retry: .milliseconds(200)) { attempts.run() }
        dwell.arm(initial: .milliseconds(200), retry: .milliseconds(200)) { attempts.run() }

        try await Self.waitUntil("the single countdown fires") { attempts.count >= 1 }
        try await Task.sleep(for: .milliseconds(120))
        #expect(attempts.count == 1, "a second arm must not add another countdown")
        dwell.cancel()
    }

    @Test("Cancelling before the countdown fires runs nothing")
    @MainActor
    func cancelPreventsTheAttempt() async throws {
        let dwell = AbsenceDwell()
        let attempts = Attempts(blockFor: 0)

        dwell.arm(initial: .milliseconds(150), retry: .milliseconds(150)) { attempts.run() }
        dwell.cancel()
        #expect(!dwell.isArmed)

        try await Task.sleep(for: .milliseconds(250))
        #expect(attempts.count == 0)
    }

    /// An attempt that finishes may be racing a `cancel()` + `arm()` pair.
    /// Clearing the slot unconditionally dropped the replacement's handle: it kept
    /// running while `isArmed` read false, so neither `cancel()` nor `drain()`
    /// could reach it and a scene teardown could tear the renderer down under a
    /// live hibernate.
    /// Holds the first attempt right before it would clear the slot, so the
    /// cancel→re-arm can land inside that window. Without the gate the attempt
    /// clears the slot before a test can replace it and the race never happens.
    @MainActor
    private final class Gate {
        var entered = false
        var mayProceed = false

        /// Cancellation-agnostic: `Task.sleep` throws instantly once the task is
        /// cancelled, which is exactly the state under test.
        func waitForProceed() async {
            var spins = 0
            while !mayProceed, spins < 200_000 {
                await Task.yield()
                spins += 1
            }
        }
    }

    @Test("A finishing attempt cannot clear a replacement's slot")
    @MainActor
    func finishingAttemptDoesNotClearReplacement() async throws {
        let dwell = AbsenceDwell()
        let gate = Gate()
        let second = Attempts(blockFor: 99)

        dwell.arm(initial: .milliseconds(20), retry: .milliseconds(20)) {
            gate.entered = true
            await gate.waitForProceed()
            return true
        }
        try await Self.waitUntil("first attempt is parked") { gate.entered }

        // Replace it while it is parked mid-attempt.
        dwell.cancel()
        dwell.arm(initial: .seconds(5), retry: .seconds(5)) { second.run() }
        #expect(dwell.isArmed)

        // Now let the old attempt run to completion. It must not clear the slot
        // the replacement now owns.
        gate.mayProceed = true
        try await Task.sleep(for: .milliseconds(80))

        #expect(dwell.isArmed, "the replacement's handle must survive the old attempt finishing")
        await dwell.drain()
        #expect(!dwell.isArmed)
        #expect(second.count == 0, "drain cancelled it before its countdown elapsed")
    }

    /// `cleanup()` must not return while an attempt is still running against the
    /// object being torn down.
    @Test("Draining waits for an in-flight attempt and clears the slot")
    @MainActor
    func drainAwaitsTheAttempt() async throws {
        let dwell = AbsenceDwell()
        let attempts = Attempts(blockFor: 0)

        dwell.arm(initial: .milliseconds(10), retry: .milliseconds(10)) { attempts.run() }
        await dwell.drain()
        #expect(!dwell.isArmed)
    }
}
