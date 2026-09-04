import AppKit
import Foundation
import LiveWallpaperCore
import Testing

@testable import LiveWallpaper

/// P0 wiring tests for the absence round trip, driven through `ScreenManager`
/// into a real `AmbientWallpaperSession`. The recording target below sees the
/// session's *effective* profile (intent folded with policy), which is the
/// output the whole pause framework exists to compute.
@MainActor
@Suite("Absence round trip through a real session")
struct AbsenceRoundTripTests {
    private func makeManager(probe: AbsencePresenceProbe) -> ScreenManager {
        ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false,
            startAutomation: false,
            fullScreenDetector: FakeFullScreenDetector(),
            userPresenceProbe: probe,
            featureCatalog: FeatureCatalog(capabilities: .pro)
        ))
    }

    private struct Rig {
        let manager: ScreenManager
        let probe: AbsencePresenceProbe
        let screen: Screen
        let session: AmbientWallpaperSession
        let target: RecordingPerformanceTarget
    }

    private func makeRig() -> Rig? {
        guard let nsScreen = NSScreen.screens.first else { return nil }
        let probe = AbsencePresenceProbe()
        let manager = makeManager(probe: probe)
        let target = RecordingPerformanceTarget()
        let session = AmbientWallpaperSession(
            window: NSWindow(),
            wallpaperType: .html,
            performanceTarget: target
        )
        let screen = Screen(nsScreen: nsScreen)
        screen.installRuntimeSession(session)
        manager.screens = [screen]
        // Production adoption, same as the coordinators' afterCommit hooks: the
        // session must share the manager's per-screen machine, or this rig
        // would pass with the session folding intent on a private machine.
        manager.resetPlaybackStateMachine(for: screen)
        return Rig(manager: manager, probe: probe, screen: screen, session: session, target: target)
    }

    /// Directly recorded, never via `absenceMarkedAt`: an unmarked reason is
    /// already settled, so revalidation stays live and the probe is the only
    /// thing keeping the absence alive.
    private func beginAbsence(_ rig: Rig) {
        rig.manager.userAbsenceReasons.insert(.displaySleep)
        rig.probe.allDisplaysAsleep = true
        rig.manager.refreshPerformancePolicyForAllScreens()
    }

    private func endAbsence(_ rig: Rig) {
        rig.probe.allDisplaysAsleep = false
        rig.manager.refreshPerformancePolicyForAllScreens()
    }

    @Test("Absence suspends the session without rewriting intent")
    func absenceSuspendsWithoutTouchingIntent() throws {
        guard let rig = makeRig() else {
            Issue.record("No NSScreen available for test")
            return
        }
        defer { rig.session.cleanup() }

        beginAbsence(rig)

        #expect(rig.target.applied.last == .suspended, "Absence must actually stop the renderer")
        #expect(rig.session.userIntendsToPlay, "Absence must never rewrite the user's intent")
        #expect(!rig.session.isPlaying)
        #expect(rig.session.summary.activity == .policySuspended)
        #expect(rig.manager.suspendReasonsByScreen[rig.screen.id] == [.userAbsent])
    }

    @Test("Clearing the absence restores playback")
    func clearingAbsenceRestoresPlayback() throws {
        guard let rig = makeRig() else {
            Issue.record("No NSScreen available for test")
            return
        }
        defer { rig.session.cleanup() }

        beginAbsence(rig)
        endAbsence(rig)

        #expect(!rig.manager.isUserAbsent)
        #expect(rig.target.applied.last == .quality, "Presence must reach the renderer, not just the flag")
        #expect(rig.session.isPlaying)
        #expect(rig.session.summary.activity == .active)
    }

    @Test("A manual pause during the absence survives its clearing")
    func manualPauseDuringAbsenceSurvives() throws {
        guard let rig = makeRig() else {
            Issue.record("No NSScreen available for test")
            return
        }
        defer { rig.session.cleanup() }

        beginAbsence(rig)
        rig.session.pause()
        endAbsence(rig)

        #expect(!rig.session.userIntendsToPlay, "The pause belongs to the user; recovery must not undo it")
        #expect(rig.target.applied.last == .suspended, "A paused session must stay stopped after the absence lifts")
        #expect(!rig.session.isPlaying)
        #expect(rig.session.summary.activity == .paused)
    }

    @Test("Play pressed during the absence sets intent but stays gated until it clears")
    func playDuringAbsenceIsGatedUntilPresenceReturns() throws {
        guard let rig = makeRig() else {
            Issue.record("No NSScreen available for test")
            return
        }
        defer { rig.session.cleanup() }

        // Paused before the absence, so the play press is a real intent flip.
        rig.session.pause()
        beginAbsence(rig)

        rig.manager.togglePlayback(for: rig.screen)

        #expect(rig.session.userIntendsToPlay, "The play press must land as intent immediately")
        #expect(rig.target.applied.last == .suspended, "Output stays gated while the absence holds")
        #expect(!rig.session.isPlaying)
        #expect(rig.session.summary.activity == .policySuspended)

        endAbsence(rig)

        #expect(rig.target.applied.last == .quality)
        #expect(rig.session.isPlaying, "The stored intent must play out once the gate lifts")
        #expect(rig.session.summary.activity == .active)
    }
}

private final class AbsencePresenceProbe: UserPresenceProbing, @unchecked Sendable {
    // Written only from the @MainActor test body between reads.
    var allDisplaysAsleep = false
    var mainDisplayActive = true
    var lockState = ScreenLockState.unlocked

    func areAllDisplaysAsleep() -> Bool { allDisplaysAsleep }
    func isMainDisplayActive() -> Bool { mainDisplayActive }
    func screenLockState() -> ScreenLockState { lockState }
}

@MainActor
private final class RecordingPerformanceTarget: WallpaperPerformanceConfigurable {
    private(set) var applied: [WallpaperPerformanceProfile] = []

    func applyPerformanceProfile(_ profile: WallpaperPerformanceProfile) {
        applied.append(profile)
    }
}
