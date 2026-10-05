import AppKit
import Foundation
import LiveWallpaperCore
import Testing

@testable import LiveWallpaper

/// Video is observed through the player's own drive flags; `loadImmediately: false`
/// keeps AVFoundation out of the loop.
@MainActor
@Suite("Policy propagation into real sessions")
struct PolicyPropagationTests {
    private func makeVideoRig() -> (session: VideoWallpaperSession, player: WallpaperVideoPlayer) {
        let player = WallpaperVideoPlayer(
            url: URL(fileURLWithPath: "/tmp/policy-propagation-\(UUID().uuidString).mov"),
            frame: CGRect(x: 0, y: 0, width: 100, height: 100),
            loadImmediately: false
        )
        return (VideoWallpaperSession(player: player), player)
    }

    @Test("A suspended video session stops its player and keeps intent")
    func videoSuspendActuallyStopsThePlayer() {
        let (session, player) = makeVideoRig()
        defer { session.cleanup() }

        session.applyPerformanceProfile(.quality)
        #expect(player.shouldAutoplayWhenReady)
        #expect(!player.isSuspended)

        session.applyPerformanceProfile(.suspended)

        #expect(!player.shouldAutoplayWhenReady, "The session must drive the player to pause, not just flag itself")
        #expect(player.isSuspended, "Resource depth must follow the suspend")
        #expect(!session.isPlaying)
        #expect(session.userIntendsToPlay, "Policy must never rewrite intent")
    }

    @Test("Quality restores a suspended video session")
    func videoQualityRestoresTheDrive() {
        let (session, player) = makeVideoRig()
        defer { session.cleanup() }

        session.applyPerformanceProfile(.suspended)
        session.applyPerformanceProfile(.quality)

        #expect(player.shouldAutoplayWhenReady, "Recovery must re-arm playback")
        #expect(!player.isSuspended)
        #expect(session.userIntendsToPlay)
    }

    @Test("Quality respects a video session's manual pause")
    func videoQualityRespectsIntent() {
        let (session, player) = makeVideoRig()
        defer { session.cleanup() }

        session.pause()
        session.applyPerformanceProfile(.suspended)
        session.applyPerformanceProfile(.quality)

        #expect(!session.userIntendsToPlay)
        #expect(!player.shouldAutoplayWhenReady, "A lifted gate must not overrule the user's pause")
    }

    @Test("An HTML session folds the suspend into its renderer and keeps intent")
    func htmlSuspendReachesTheRenderer() {
        let target = RecordingPerformanceTarget()
        let session = AmbientWallpaperSession(
            window: NSWindow(),
            wallpaperType: .html,
            performanceTarget: target
        )
        defer { session.cleanup() }

        session.applyPerformanceProfile(.suspended)
        #expect(target.applied.last == .suspended, "The renderer must actually stop")
        #expect(session.userIntendsToPlay, "Policy must never rewrite intent")
        #expect(!session.isPlaying)

        session.applyPerformanceProfile(.quality)
        #expect(target.applied.last == .quality)
        #expect(session.isPlaying)

        session.pause()
        session.applyPerformanceProfile(.quality)
        #expect(target.applied.last == .suspended, "Effective output folds intent, not just policy")
        #expect(!session.userIntendsToPlay)
    }

    @Test("Releasing a display's runtime session keeps its particle overlay under a standing policy suspend")
    func releasingTheSessionKeepsTheParticleOverlaySuspended() throws {
        let nsScreen = try #require(NSScreen.screens.first, "No NSScreen available")
        let originalSettings = SettingsManager.shared.loadGlobalSettings()
        let originalConfigurations = SettingsManager.shared.loadConfigurations()
        defer {
            SettingsManager.shared.saveGlobalSettings(originalSettings)
            SettingsManager.shared.replaceAllConfigurations(originalConfigurations)
        }
        var settings = originalSettings
        settings.globalPauseOnBattery = true
        SettingsManager.shared.saveGlobalSettings(settings)

        let manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false,
            startAutomation: false,
            powerMonitor: FakePowerMonitor(initialPowerSource: .battery(level: 0.5)),
            fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(),
            displayRegistry: FakeDisplayRegistry(screens: [Screen(nsScreen: nsScreen)]),
            featureCatalog: FeatureCatalog(capabilities: .pro)
        ))
        defer { manager.effectsCoordinator.shutdown() }
        let screen = try #require(manager.screens.first)

        var configuration = ScreenConfiguration(screenID: screen.id, videoBookmarkData: Data())
        configuration.particleEffect = .snow
        configuration.displayFingerprint = screen.displayFingerprint
        manager.configurationStore.save(configuration)
        manager.effectsCoordinator.reconcileEnvironmentOverlays()
        manager.refreshPerformancePolicyForAllScreens()

        let overlay = manager.effectsCoordinator.debugEnvironmentOverlay
        let before = try #require(overlay.debugSuspensionReasons(screenID: screen.id), "no particle overlay was built")
        try #require(before.contains(.runtime), "the battery pause never reached the particle overlay")

        manager.releaseRuntimeSession(screen)

        let after = try #require(
            overlay.debugSuspensionReasons(screenID: screen.id),
            "the particle overlay should outlive the wallpaper session"
        )
        #expect(after.contains(.runtime), "releasing the session resumed particles while the battery pause still stands")
    }
}

@MainActor
private final class RecordingPerformanceTarget: WallpaperPerformanceConfigurable {
    private(set) var applied: [WallpaperPerformanceProfile] = []

    func applyPerformanceProfile(_ profile: WallpaperPerformanceProfile) {
        applied.append(profile)
    }
}
