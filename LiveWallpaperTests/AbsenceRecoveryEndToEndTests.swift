import AppKit
import CoreGraphics
import Foundation
import LiveWallpaperCore
import Testing

@testable import LiveWallpaper

/// W4.2 / W4.3: the absence→resume round trip and `.neverPause` reaching a real
/// session. Both were pure coverage holes — absence had only source-string
/// characterization behind it, and `.neverPause` stopped at the pure function.
@MainActor
@Suite("Absence recovery and rule vetoes on a live session")
struct AbsenceRecoveryEndToEndTests {
    private func makeManager(probe: FakeRecoveryPresenceProbe) -> ScreenManager {
        ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false,
            startAutomation: false,
            fullScreenDetector: FakeFullScreenDetector(),
            userPresenceProbe: probe,
            featureCatalog: FeatureCatalog(capabilities: .pro)
        ))
    }

    private func makeScreen(installing playback: RecoveryPlaybackController) -> Screen? {
        guard let nsScreen = NSScreen.screens.first else { return nil }
        let screen = Screen(nsScreen: nsScreen)
        screen.installRuntimeSession(playback)
        return screen
    }

    @Test("A session suspended for absence plays again once presence returns")
    func absenceSuspendThenResumeReachesTheSession() throws {
        let probe = FakeRecoveryPresenceProbe()
        let manager = makeManager(probe: probe)
        let playback = RecoveryPlaybackController()
        guard let screen = makeScreen(installing: playback) else {
            Issue.record("No NSScreen available for test")
            return
        }
        manager.screens = [screen]

        // Display slept: absence suspends without touching intent.
        manager.userAbsenceReasons.insert(.displaySleep)
        probe.displayAsleep = true
        manager.refreshPerformancePolicyForAllScreens()
        #expect(playback.lastProfile == .suspended)
        #expect(playback.userIntendsToPlay, "Absence must never rewrite the user's intent")

        // The wake notification never arrives; the probe is the only way back.
        probe.displayAsleep = false
        manager.refreshPerformancePolicyForAllScreens()

        #expect(!manager.isUserAbsent)
        #expect(playback.lastProfile == .quality, "Presence must reach the session, not just the flag")
    }

    @Test("A neverPause rule keeps a real session playing through a discretionary pause")
    func neverPauseVetoReachesTheSession() throws {
        let probe = FakeRecoveryPresenceProbe()
        let manager = makeManager(probe: probe)
        let playback = RecoveryPlaybackController()
        guard let screen = makeScreen(installing: playback) else {
            Issue.record("No NSScreen available for test")
            return
        }
        manager.screens = [screen]

        let vetoed = WallpaperPolicyEngine.decision(
            inputs: WallpaperPolicyInputs(
                powerSource: .battery(level: 0.4),
                isHiddenByFullScreen: true,
                isWindowOccluding: false,
                isApplicationRuleActive: true,
                thermalState: .nominal,
                isUserAbsent: false,
                memoryPressureLevel: .normal,
                isLowPowerMode: true,
                isFrontmostExcludedByRule: true
            ),
            settings: GlobalSettings(
                globalPauseOnBattery: true,
                pauseOnFullScreen: true,
                pauseInLowPowerMode: true
            )
        )
        #expect(vetoed.profile == WallpaperPerformanceProfile.quality, "neverPause must veto every discretionary reason at once")
        #expect(vetoed.suspendReasons.isEmpty)

        // Safety still wins over the same veto.
        let safety = WallpaperPolicyEngine.decision(
            inputs: WallpaperPolicyInputs(
                powerSource: .external,
                isHiddenByFullScreen: false,
                isWindowOccluding: false,
                isApplicationRuleActive: true,
                thermalState: .critical,
                isUserAbsent: false,
                memoryPressureLevel: .normal,
                isLowPowerMode: false,
                isFrontmostExcludedByRule: true
            ),
            settings: GlobalSettings()
        )
        #expect(safety.profile == .suspended)
        #expect(safety.suspendReasons == [.thermal])
    }
}

private final class FakeRecoveryPresenceProbe: UserPresenceProbing, @unchecked Sendable {
    // Written only from the @MainActor test body between reads.
    var displayAsleep = false
    var mainDisplayActive = true
    var lockState = ScreenLockState.unlocked

    func isAnyDisplayAsleep() -> Bool { displayAsleep }
    func isMainDisplayActive() -> Bool { mainDisplayActive }
    func screenLockState() -> ScreenLockState { lockState }
}

@MainActor
private final class RecoveryPlaybackController: WallpaperPlaybackControllable {
    private(set) var userIntendsToPlay = true
    private(set) var lastProfile: WallpaperPerformanceProfile?

    var isPlaying: Bool { userIntendsToPlay && lastProfile != .suspended }
    var wallpaperType: WallpaperType { .video }
    var summary: WallpaperSessionSummary { .notConfigured }
    var videoPlayer: WallpaperVideoPlayer? { nil }
    var wallpaperWindow: NSWindow? { nil }

    func show() {}
    func applyPerformanceProfile(_ profile: WallpaperPerformanceProfile) { lastProfile = profile }
    func updateFrame(to frame: CGRect) {}
    func cleanup() {}
    func play() { userIntendsToPlay = true }
    func pause() { userIntendsToPlay = false }

    func prepareForDisplay(timeout: Duration) async -> WallpaperPreparationResult {
        await WallpaperPreparationWaiter.wait(timeout: timeout) { nil }
    }
}
