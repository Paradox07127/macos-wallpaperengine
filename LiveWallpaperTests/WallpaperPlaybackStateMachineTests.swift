import LiveWallpaperCore
import Testing

@MainActor
@Suite("WallpaperPlaybackStateMachine")
struct WallpaperPlaybackStateMachineTests {
    private static let qualityClean = WallpaperPolicyDecision(profile: .quality)
    private static let qualityThrottled = WallpaperPolicyDecision(
        profile: .quality,
        throttleReasons: [.thermal]
    )
    private static let suspendedDiscretionary = WallpaperPolicyDecision(
        profile: .suspended,
        suspendReasons: [.fullScreen]
    )
    private static let suspendedSafety = WallpaperPolicyDecision(
        profile: .suspended,
        suspendReasons: [.thermal, .memoryPressure]
    )
    /// The engine never emits this shape (it drops throttle at suspension);
    /// fed here to pin the machine's own mirror of that rule, which the
    /// differential suite cannot see for exactly that reason.
    private static let suspendedWithLeftoverThrottle = WallpaperPolicyDecision(
        profile: .suspended,
        suspendReasons: [.memoryPressure],
        throttleReasons: [.thermal]
    )

    @Test("Only user events change intent; policy events never do")
    func intentTransitions() {
        // (initial intent, event, expected intent). policyChanged uses a
        // safety suspend on purpose: even the hardest gate must not rewrite intent.
        let table: [(initial: Bool, event: (WallpaperPlaybackStateMachine) -> Void, expected: Bool, label: String)] = [
            (true, { $0.userPlay() }, true, "play while playing"),
            (true, { $0.userPause() }, false, "pause while playing"),
            (true, { $0.policyChanged(Self.suspendedSafety) }, true, "safety suspend while playing"),
            (false, { $0.userPlay() }, true, "play while paused"),
            (false, { $0.userPause() }, false, "pause while paused"),
            (false, { $0.policyChanged(Self.suspendedSafety) }, false, "safety suspend while paused"),
        ]
        for row in table {
            let machine = WallpaperPlaybackStateMachine(userIntendsToPlay: row.initial)
            row.event(machine)
            #expect(
                machine.userIntendsToPlay == row.expected,
                "\(row.label): expected intent \(row.expected)"
            )
        }
    }

    @Test("Output five-tuple across intent x decision")
    func outputsMatrix() {
        let table: [(intent: Bool, decision: WallpaperPolicyDecision, expected: WallpaperPlaybackStateMachine.Outputs, label: String)] = [
            (true, Self.qualityClean,
             .init(policyProfile: .quality, effectiveProfile: .quality,
                   userPaused: false, throttleActive: false, suspendReasons: []),
             "playing, clean quality"),
            (true, Self.qualityThrottled,
             .init(policyProfile: .quality, effectiveProfile: .quality,
                   userPaused: false, throttleActive: true, suspendReasons: []),
             "playing, throttled quality"),
            (true, Self.suspendedDiscretionary,
             .init(policyProfile: .suspended, effectiveProfile: .suspended,
                   userPaused: false, throttleActive: false, suspendReasons: [.fullScreen]),
             "playing, discretionary suspend"),
            (true, Self.suspendedSafety,
             .init(policyProfile: .suspended, effectiveProfile: .suspended,
                   userPaused: false, throttleActive: false,
                   suspendReasons: [.thermal, .memoryPressure]),
             "playing, safety suspend"),
            (false, Self.qualityClean,
             .init(policyProfile: .quality, effectiveProfile: .suspended,
                   userPaused: true, throttleActive: false, suspendReasons: []),
             "paused, clean quality"),
            (false, Self.qualityThrottled,
             // Throttle follows policy, not intent: policy-only consumers keep
             // seeing it while the user has playback paused.
             .init(policyProfile: .quality, effectiveProfile: .suspended,
                   userPaused: true, throttleActive: true, suspendReasons: []),
             "paused, throttled quality"),
            (false, Self.suspendedDiscretionary,
             .init(policyProfile: .suspended, effectiveProfile: .suspended,
                   userPaused: true, throttleActive: false, suspendReasons: [.fullScreen]),
             "paused, discretionary suspend"),
            (false, Self.suspendedSafety,
             .init(policyProfile: .suspended, effectiveProfile: .suspended,
                   userPaused: true, throttleActive: false,
                   suspendReasons: [.thermal, .memoryPressure]),
             "paused, safety suspend"),
        ]
        for row in table {
            let machine = WallpaperPlaybackStateMachine(userIntendsToPlay: row.intent)
            let outputs = machine.policyChanged(row.decision)
            #expect(outputs == row.expected, "\(row.label): got \(outputs)")
        }
    }

    @Test("userPause survives subsequent policy changes")
    func pauseSurvivesPolicyChanges() {
        let machine = WallpaperPlaybackStateMachine(userIntendsToPlay: true)
        machine.userPause()
        machine.policyChanged(Self.suspendedSafety)
        machine.policyChanged(Self.qualityClean)
        #expect(machine.userIntendsToPlay == false)
        #expect(machine.outputs.userPaused == true)
        // Gate reopened but the user still wants pause: stays suspended.
        #expect(machine.outputs.effectiveProfile == .suspended)
    }

    @Test("userPlay under a closed gate raises intent but stays suspended")
    func playUnderClosedGate() {
        let machine = WallpaperPlaybackStateMachine(userIntendsToPlay: false)
        machine.policyChanged(Self.suspendedDiscretionary)
        let outputs = machine.userPlay()
        #expect(machine.userIntendsToPlay == true)
        #expect(outputs.userPaused == false)
        #expect(outputs.effectiveProfile == .suspended)
        // The moment the gate lifts, the stored intent takes effect.
        #expect(machine.policyChanged(Self.qualityClean).effectiveProfile == .quality)
    }

    @Test("Suspension zeroes throttle even on a decision carrying leftover throttle")
    func suspendedDropsThrottle() {
        let machine = WallpaperPlaybackStateMachine(userIntendsToPlay: true)
        let outputs = machine.policyChanged(Self.suspendedWithLeftoverThrottle)
        #expect(outputs.throttleActive == false)
        #expect(outputs.suspendReasons == [.memoryPressure])
    }

    @Test("Suspend reasons pass through unchanged")
    func reasonsPassThrough() {
        let machine = WallpaperPlaybackStateMachine(userIntendsToPlay: true)
        for reason in WallpaperSuspendReason.allCases {
            let outputs = machine.policyChanged(
                WallpaperPolicyDecision(profile: .suspended, suspendReasons: [reason])
            )
            #expect(outputs.suspendReasons == [reason], "\(reason) should pass through")
        }
    }

    @Test("Same inputs produce equal outputs")
    func outputsIdempotent() {
        let machine = WallpaperPlaybackStateMachine(userIntendsToPlay: true)
        let first = machine.policyChanged(Self.qualityThrottled)
        let second = machine.policyChanged(Self.qualityThrottled)
        #expect(first == second)
        #expect(machine.outputs == first)
    }
}
