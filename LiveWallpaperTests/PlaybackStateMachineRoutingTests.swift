import AppKit
import Foundation
import LiveWallpaperCore
import Testing

@testable import LiveWallpaper

/// P2.0 routing invariants: every intent-changing entry point feeds the
/// per-screen `WallpaperPlaybackStateMachine`, policy refreshes feed it the
/// decision, and session install/replace/release resets it — while sessions
/// still run their own intent folding (the machine changes no behavior yet).
@MainActor
@Suite("Playback state machine routing")
struct PlaybackStateMachineRoutingTests {
    private func makeManager(
        probe: (any UserPresenceProbing)? = nil
    ) -> ScreenManager {
        ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false,
            startAutomation: false,
            powerMonitor: FakePowerMonitor(),
            fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(),
            displayRegistry: FakeDisplayRegistry(),
            userPresenceProbe: probe ?? RoutingPresenceProbe(),
            featureCatalog: FeatureCatalog(capabilities: .pro)
        ))
    }

    private struct Rig {
        let manager: ScreenManager
        let screen: Screen
        let playback: RoutingFakePlaybackController
    }

    private func makeRig(
        playback: RoutingFakePlaybackController,
        probe: (any UserPresenceProbing)? = nil
    ) -> Rig? {
        guard let nsScreen = NSScreen.screens.first else { return nil }
        let manager = makeManager(probe: probe)
        let screen = Screen(nsScreen: nsScreen)
        screen.installRuntimeSession(playback)
        manager.screens = [screen]
        // Same reset/adopt the commit paths run after installRuntimeSession.
        manager.resetPlaybackStateMachine(for: screen)
        return Rig(manager: manager, screen: screen, playback: playback)
    }

    @Test("Per-screen toggle keeps machine intent equal to session intent")
    func perScreenToggleKeepsIntentAligned() {
        guard let rig = makeRig(playback: RoutingFakePlaybackController(isPlaying: true)) else {
            Issue.record("No NSScreen available for test")
            return
        }

        rig.manager.togglePlayback(for: rig.screen)
        #expect(!rig.playback.userIntendsToPlay)
        #expect(
            rig.manager.playbackStateMachine(for: rig.screen.id).userIntendsToPlay
                == rig.playback.userIntendsToPlay
        )

        rig.manager.togglePlayback(for: rig.screen)
        #expect(rig.playback.userIntendsToPlay)
        #expect(
            rig.manager.playbackStateMachine(for: rig.screen.id).userIntendsToPlay
                == rig.playback.userIntendsToPlay
        )
    }

    @Test("Global toggle feeds the machine on both directions")
    func globalToggleFeedsMachine() {
        guard let rig = makeRig(playback: RoutingFakePlaybackController(isPlaying: true)) else {
            Issue.record("No NSScreen available for test")
            return
        }

        rig.manager.togglePlayback()
        #expect(!rig.playback.userIntendsToPlay)
        #expect(
            rig.manager.playbackStateMachine(for: rig.screen.id).userIntendsToPlay
                == rig.playback.userIntendsToPlay
        )

        rig.manager.togglePlayback()
        #expect(rig.playback.userIntendsToPlay)
        #expect(
            rig.manager.playbackStateMachine(for: rig.screen.id).userIntendsToPlay
                == rig.playback.userIntendsToPlay
        )
    }

    /// The global toggle's play direction on a policy-suspended screen is a
    /// no-op that preserves intent — the machine must land on the same value.
    @Test("Global play on a policy-suspended screen keeps both intents true")
    func globalPlayOnPolicySuspendedScreenStaysAligned() {
        let playback = RoutingFakePlaybackController(isPlaying: false, userIntendsToPlay: true)
        guard let rig = makeRig(playback: playback) else {
            Issue.record("No NSScreen available for test")
            return
        }

        rig.manager.togglePlayback()

        #expect(rig.playback.userIntendsToPlay)
        #expect(rig.playback.pauseCount == 0)
        #expect(rig.manager.playbackStateMachine(for: rig.screen.id).userIntendsToPlay)
    }

    @Test("Policy refresh writes the machine's suspend-reason passthrough")
    func policyRefreshKeepsReasonsEqualToMachineOutputs() {
        let probe = RoutingPresenceProbe()
        guard let rig = makeRig(
            playback: RoutingFakePlaybackController(isPlaying: true),
            probe: probe
        ) else {
            Issue.record("No NSScreen available for test")
            return
        }

        rig.manager.userAbsenceReasons.insert(.displaySleep)
        probe.displayAsleep = true
        rig.manager.refreshPerformancePolicyForAllScreens()

        let machine = rig.manager.playbackStateMachine(for: rig.screen.id)
        #expect(rig.manager.suspendReasonsByScreen[rig.screen.id] == [.userAbsent])
        #expect(
            rig.manager.suspendReasonsByScreen[rig.screen.id]
                == machine.outputs.suspendReasons
        )
        #expect(machine.userIntendsToPlay, "Policy must never rewrite machine intent")

        probe.displayAsleep = false
        rig.manager.refreshPerformancePolicyForAllScreens()

        #expect(rig.manager.suspendReasonsByScreen[rig.screen.id] == [])
        #expect(
            rig.manager.suspendReasonsByScreen[rig.screen.id]
                == machine.outputs.suspendReasons
        )
    }

    @Test("Replacing the session resets the machine to the new session's intent")
    func sessionReplacementResetsMachine() {
        guard let rig = makeRig(playback: RoutingFakePlaybackController(isPlaying: true)) else {
            Issue.record("No NSScreen available for test")
            return
        }

        rig.manager.togglePlayback(for: rig.screen)
        #expect(!rig.manager.playbackStateMachine(for: rig.screen.id).userIntendsToPlay)

        // Same manual clear the commit paths run after installRuntimeSession.
        let replacement = RoutingFakePlaybackController(isPlaying: true)
        rig.screen.installRuntimeSession(replacement)
        rig.manager.resetPlaybackStateMachine(for: rig.screen)

        #expect(replacement.userIntendsToPlay)
        #expect(
            rig.manager.playbackStateMachine(for: rig.screen.id).userIntendsToPlay
                == replacement.userIntendsToPlay
        )
    }

    @Test("Releasing the session drops the machine so a rebuild intends to play")
    func releaseResetsMachine() {
        guard let rig = makeRig(playback: RoutingFakePlaybackController(isPlaying: true)) else {
            Issue.record("No NSScreen available for test")
            return
        }

        rig.manager.togglePlayback(for: rig.screen)
        #expect(!rig.manager.playbackStateMachine(for: rig.screen.id).userIntendsToPlay)

        rig.manager.releaseRuntimeSession(rig.screen)

        #expect(
            rig.manager.playbackStateMachine(for: rig.screen.id).userIntendsToPlay,
            "A fresh session always intends to play; the machine must match"
        )
    }
}

private final class RoutingPresenceProbe: UserPresenceProbing, @unchecked Sendable {
    // Written only from the @MainActor test body between reads.
    var displayAsleep = false

    func isAnyDisplayAsleep() -> Bool { displayAsleep }
    func isMainDisplayActive() -> Bool { true }
    func screenLockState() -> ScreenLockState { .unlocked }
}

/// Mirrors the real three-layer fold (see `WallpaperArchitectureTests`):
/// visible playback is `userIntendsToPlay && policy == .quality`. Like the
/// real sessions it self-holds an intent machine and adopts the screen's
/// shared one on install.
private final class RoutingFakePlaybackController: WallpaperPlaybackControllable, WallpaperIntentMachineAdopting {
    var isPlaying: Bool
    private var playbackMachine: WallpaperPlaybackStateMachine
    var userIntendsToPlay: Bool { playbackMachine.userIntendsToPlay }
    var playCount = 0
    var pauseCount = 0
    private var policyAllowsPlayback: Bool

    init(isPlaying: Bool, userIntendsToPlay: Bool? = nil) {
        self.isPlaying = isPlaying
        playbackMachine = WallpaperPlaybackStateMachine(
            userIntendsToPlay: userIntendsToPlay ?? isPlaying
        )
        // `isPlaying: false` alone means a user pause; intends-to-play while
        // not playing describes a policy suspend.
        policyAllowsPlayback = isPlaying || !(userIntendsToPlay ?? isPlaying)
    }

    func adoptPlaybackStateMachine(_ machine: WallpaperPlaybackStateMachine) {
        if machine.userIntendsToPlay != playbackMachine.userIntendsToPlay {
            if playbackMachine.userIntendsToPlay {
                machine.userPlay()
            } else {
                machine.userPause()
            }
        }
        playbackMachine = machine
    }

    var wallpaperType: WallpaperType { .video }
    var summary: WallpaperSessionSummary {
        WallpaperSessionSummary(
            wallpaperType: .video,
            activity: isPlaying ? .active : (userIntendsToPlay ? .policySuspended : .paused),
            supportsPlaybackControl: true,
            subtitle: "RoutingFake"
        )
    }

    var videoPlayer: WallpaperVideoPlayer? { nil }
    var wallpaperWindow: NSWindow? { nil }

    func show() {}
    func applyPerformanceProfile(_ profile: WallpaperPerformanceProfile) {
        policyAllowsPlayback = profile == .quality
        isPlaying = userIntendsToPlay && policyAllowsPlayback
    }

    func updateFrame(to frame: CGRect) {}
    func cleanup() {}

    func prepareForDisplay(timeout: Duration) async -> WallpaperPreparationResult {
        await WallpaperPreparationWaiter.wait(timeout: timeout) { nil }
    }

    func play() {
        playCount += 1
        playbackMachine.userPlay()
        isPlaying = policyAllowsPlayback
    }

    func pause() {
        pauseCount += 1
        playbackMachine.userPause()
        isPlaying = false
    }
}
