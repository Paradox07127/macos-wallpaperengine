#if !LITE_BUILD
    import Foundation
    @testable import LiveWallpaper
    import Testing

    @Suite("WPE script fault policy")
    struct WPEScriptFaultPolicyTests {
        /// Drives the policy to the given number of consecutive failures of one
        /// entry point, attempting only when the policy allows it. Returns the
        /// last verdict and the advanced clock.
        private func fail(
            _ policy: inout WPEScriptFaultPolicy,
            entryPoint: String = "update",
            times: Int,
            startingAt now: Double = 0
        ) -> (verdict: WPEScriptFaultVerdict, now: Double) {
            var verdict = WPEScriptFaultVerdict.probing
            var clock = now
            var recorded = 0
            while recorded < times {
                if policy.shouldAttempt(entryPoint: entryPoint, at: clock) {
                    verdict = policy.recordFailure(entryPoint: entryPoint, at: clock)
                    recorded += 1
                }
                clock += WPEScriptFaultPolicy.probeInterval
            }
            return (verdict, clock)
        }

        // Mutating calls are hoisted into lets throughout: #expect's macro
        // captures the receiver immutably, so it cannot call them inline.

        @Test("Backoff sequence skips 1, then 8, then 64 frames")
        func backoffSequence() {
            var policy = WPEScriptFaultPolicy()
            let now = 0.0
            let firstAttempt = policy.shouldAttempt(entryPoint: "update", at: now)
            #expect(firstAttempt)
            let firstVerdict = policy.recordFailure(entryPoint: "update", at: now)
            #expect(firstVerdict == .backoff(skippedFrames: 1))
            let skippedOnce = policy.shouldAttempt(entryPoint: "update", at: now)
            #expect(!skippedOnce)
            let secondAttempt = policy.shouldAttempt(entryPoint: "update", at: now)
            #expect(secondAttempt)
            let secondVerdict = policy.recordFailure(entryPoint: "update", at: now)
            #expect(secondVerdict == .backoff(skippedFrames: 8))
            for _ in 0 ..< 8 {
                let skipped = policy.shouldAttempt(entryPoint: "update", at: now)
                #expect(!skipped)
            }
            let thirdAttempt = policy.shouldAttempt(entryPoint: "update", at: now)
            #expect(thirdAttempt)
            let thirdVerdict = policy.recordFailure(entryPoint: "update", at: now)
            #expect(thirdVerdict == .backoff(skippedFrames: 64))
            for _ in 0 ..< 64 {
                let skipped = policy.shouldAttempt(entryPoint: "update", at: now)
                #expect(!skipped)
            }
            let probeAttempt = policy.shouldAttempt(entryPoint: "update", at: now)
            #expect(probeAttempt)
        }

        @Test("After backoff is exhausted, probes are spaced one second apart")
        func probeCadence() {
            var policy = WPEScriptFaultPolicy()
            let (verdict, now) = fail(&policy, times: 4)
            #expect(verdict == .probing)
            let early = policy.shouldAttempt(entryPoint: "update", at: now - 0.5)
            #expect(!early)
            let due = policy.shouldAttempt(entryPoint: "update", at: now)
            #expect(due)
            let lateDue = policy.shouldAttempt(entryPoint: "update", at: now + 100)
            #expect(lateDue)
        }

        @Test("A success resets the escalation back to the first backoff step")
        func successResets() {
            var policy = WPEScriptFaultPolicy()
            let (_, now) = fail(&policy, times: 4)
            policy.recordSuccess(entryPoint: "update")
            let attempt = policy.shouldAttempt(entryPoint: "update", at: now)
            #expect(attempt)
            let verdict = policy.recordFailure(entryPoint: "update", at: now)
            #expect(verdict == .backoff(skippedFrames: 1))
        }

        @Test("Twelve failed probes hard-quarantine the entry point")
        func quarantineAfterFailedProbes() {
            var policy = WPEScriptFaultPolicy()
            // 3 backoff failures + 11 probing failures, then the 12th probe.
            let (beforeLast, now) = fail(&policy, times: 14)
            #expect(beforeLast == .probing)
            let (last, after) = fail(&policy, times: 1, startingAt: now)
            #expect(last == .quarantined)
            let attempt = policy.shouldAttempt(entryPoint: "update", at: after + 10_000)
            #expect(!attempt)
        }

        @Test("An entry point that ever succeeded is never quarantined")
        func everSucceededExemptsQuarantine() {
            var policy = WPEScriptFaultPolicy()
            policy.recordSuccess(entryPoint: "update")
            let (verdict, now) = fail(&policy, times: 40)
            #expect(verdict == .probing)
            let attempt = policy.shouldAttempt(
                entryPoint: "update", at: now + WPEScriptFaultPolicy.probeInterval
            )
            #expect(attempt)
        }

        @Test("Entry points back off independently (event-callback isolation)")
        func entryPointIsolation() {
            var policy = WPEScriptFaultPolicy()
            _ = fail(&policy, entryPoint: "cursorClick", times: 15)
            let quarantined = policy.shouldAttempt(entryPoint: "cursorClick", at: 10_000)
            #expect(!quarantined)
            let updateAttempt = policy.shouldAttempt(entryPoint: "update", at: 10_000)
            #expect(updateAttempt)
            let moveAttempt = policy.shouldAttempt(entryPoint: "cursorMove", at: 10_000)
            #expect(moveAttempt)
        }

        @Test("Escalation keeps advancing across failures, never restarting")
        func escalationNeverRestarts() {
            var policy = WPEScriptFaultPolicy()
            let (_, now) = fail(&policy, times: 4)
            let attempt = policy.shouldAttempt(entryPoint: "update", at: now)
            #expect(attempt)
            // Regression guard: keying escalation on the exception message let a
            // script throwing `Error("t=" + Date.now())` restart at step 1 every
            // tick and never reach quarantine.
            let verdict = policy.recordFailure(entryPoint: "update", at: now)
            #expect(verdict == .probing)
        }
    }
#endif
