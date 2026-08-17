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
