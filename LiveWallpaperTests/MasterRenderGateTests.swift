import AppKit
import Foundation
import Testing
@testable import LiveWallpaper
import LiveWallpaperCore

/// Prevents the global render gate from collapsing configured screens to `notConfigured`, which would disable re-enabling.
@Suite("Master render gate")
@MainActor
struct MasterRenderGateTests {

    private static let gateDefaultsKey = "loomscreen.wallpapers.globallyEnabled.v1"

    private static func withGate(_ enabled: Bool, _ body: () throws -> Void) rethrows {
        let defaults = UserDefaults.appScoped()
        let original = defaults.object(forKey: gateDefaultsKey)
        defaults.set(enabled, forKey: gateDefaultsKey)
        defer {
            if let original {
                defaults.set(original, forKey: gateDefaultsKey)
            } else {
                defaults.removeObject(forKey: gateDefaultsKey)
            }
        }
        try body()
    }

    private static func makeManager(screen: Screen) -> ScreenManager {
        ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: true,
            startAutomation: false,
            powerMonitor: FakePowerMonitor(),
            fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(),
            displayRegistry: FakeDisplayRegistry(screens: [screen]),
            featureCatalog: FeatureCatalog(capabilities: .pro)
        ))
    }

    @Test("Gate off does not build a session yet reports the screen as configured-but-off")
    func gateOffSkipsBuildButReportsOff() throws {
        guard let screen = NSScreen.screens.first.map(Screen.init(nsScreen:)) else {
            Issue.record("No NSScreen available")
            return
        }
        let originalConfigurations = SettingsManager.shared.loadConfigurations()
        defer { SettingsManager.shared.replaceAllConfigurations(originalConfigurations) }

        SettingsManager.shared.replaceAllConfigurations([
            ScreenConfiguration(screenID: screen.id, wallpaper: .html(source: .inline("<p>gate</p>"), config: .default))
        ])

        Self.withGate(false) {
            let manager = Self.makeManager(screen: screen)
            defer { screen.resetRuntimeSession() }

            #expect(manager.wallpapersGloballyEnabled == false)

            guard let liveScreen = manager.screens.first(where: { $0.id == screen.id }) else {
                Issue.record("Injected display registry did not produce a screen")
                return
            }

            #expect(liveScreen.runtimeSession == nil, "Gate off must not build a live session")

            let summary = manager.wallpaperSummary(for: liveScreen)
            #expect(summary.activity == .off)
            #expect(summary.isConfigured)
            #expect(manager.wallpaperOverviewStatus == .off)
            #expect(manager.wallpaperOverviewStatus != .notConfigured)
        }
    }

    @Test("Gate off with no saved wallpaper still reports not-configured")
    func gateOffWithoutConfigReportsNotConfigured() throws {
        guard let screen = NSScreen.screens.first.map(Screen.init(nsScreen:)) else {
            Issue.record("No NSScreen available")
            return
        }
        let originalConfigurations = SettingsManager.shared.loadConfigurations()
        defer { SettingsManager.shared.replaceAllConfigurations(originalConfigurations) }

        SettingsManager.shared.replaceAllConfigurations([])

        Self.withGate(false) {
            let manager = Self.makeManager(screen: screen)
            defer { screen.resetRuntimeSession() }

            guard let liveScreen = manager.screens.first(where: { $0.id == screen.id }) else {
                Issue.record("Injected display registry did not produce a screen")
                return
            }

            #expect(liveScreen.runtimeSession == nil)
            #expect(manager.wallpaperSummary(for: liveScreen).activity == .inactive)
            #expect(manager.wallpaperOverviewStatus == .notConfigured)
        }
    }

    @Test("Assigning a wallpaper while the gate is off flips the overview to .off (no stale cache)")
    func assigningWallpaperWhileOffRefreshesOverview() throws {
        guard let screen = NSScreen.screens.first.map(Screen.init(nsScreen:)) else {
            Issue.record("No NSScreen available")
            return
        }
        let originalConfigurations = SettingsManager.shared.loadConfigurations()
        defer { SettingsManager.shared.replaceAllConfigurations(originalConfigurations) }

        SettingsManager.shared.replaceAllConfigurations([])

        Self.withGate(false) {
            let manager = Self.makeManager(screen: screen)
            defer { screen.resetRuntimeSession() }

            guard let liveScreen = manager.screens.first(where: { $0.id == screen.id }) else {
                Issue.record("Injected display registry did not produce a screen")
                return
            }

            #expect(manager.wallpaperOverviewStatus == .notConfigured)

            manager.setHTMLWallpaper(
                source: .inline("<p>gate</p>"),
                for: liveScreen
            )

            #expect(liveScreen.runtimeSession == nil, "Gate off must not build a session")
            #expect(manager.wallpaperSummary(for: liveScreen).activity == .off)
            #expect(manager.wallpaperOverviewStatus == .off)
        }
    }

    @Test("Disabling the gate releases the live session; re-enabling shows it instead of rebuilding")
    func gateReleasesAndReusesLiveSession() {
        guard let screen = NSScreen.screens.first.map(Screen.init(nsScreen:)) else {
            Issue.record("No NSScreen available")
            return
        }
        let originalConfigurations = SettingsManager.shared.loadConfigurations()
        defer { SettingsManager.shared.replaceAllConfigurations(originalConfigurations) }

        SettingsManager.shared.replaceAllConfigurations([
            ScreenConfiguration(screenID: screen.id, wallpaper: .html(source: .inline("<p>gate</p>"), config: .default))
        ])

        Self.withGate(true) {
            let manager = Self.makeManager(screen: screen)
            defer { screen.resetRuntimeSession() }
            guard let liveScreen = manager.screens.first(where: { $0.id == screen.id }) else {
                Issue.record("Injected display registry did not produce a screen")
                return
            }

            let session = GateTestRuntimeSession()
            liveScreen.installRuntimeSession(session)

            // Show-only branch: an already-live session must be reused, not rebuilt.
            manager.applyGlobalRenderGate()
            #expect(liveScreen.runtimeSession === session)
            #expect(session.cleanupCallCount == 0)
            #expect(session.showCallCount >= 1)
            #expect(manager.wallpaperOverviewStatus != .off)

            manager.setWallpapersEnabled(false)
            #expect(liveScreen.runtimeSession == nil, "Disabling must release the live session")
            #expect(session.cleanupCallCount == 1)
            #expect(manager.wallpaperOverviewStatus == .off)
        }
    }

}

/// Minimal live-session stand-in: the gate's show/release branches are the
/// subject here, and no shipping wallpaper type builds headlessly.
@MainActor
private final class GateTestRuntimeSession: WallpaperRuntimeSession {
    let wallpaperType: WallpaperType = .html
    let summary = WallpaperSessionSummary(
        wallpaperType: .html,
        activity: .active,
        supportsPlaybackControl: false,
        subtitle: "Inline web content"
    )
    let videoPlayer: WallpaperVideoPlayer? = nil
    let wallpaperWindow: NSWindow? = nil
    private(set) var cleanupCallCount = 0
    private(set) var showCallCount = 0

    func show() { showCallCount += 1 }
    func applyPerformanceProfile(_ profile: WallpaperPerformanceProfile) {}
    func updateFrame(to frame: CGRect) {}
    func cleanup() { cleanupCallCount += 1 }
    func prepareForDisplay(timeout: Duration) async -> WallpaperPreparationResult { .ready }
}
