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


    /// The master switch is "stop every wallpaper", and the overlays are drawn
    /// over the wallpaper — so they have to stop with it.
    ///
    /// Particles already did, because `releaseRuntimeSession` tears their layer
    /// down on the way past. The Monitor and Now Playing panels are owned by
    /// `OverlayController`, which the gate never touched, so they kept
    /// rendering over a desktop with no wallpaper left under them.
    @Test("The master switch stops the Monitor and Now Playing overlays too")
    func gateOffStopsMonitorOverlays() throws {
        guard let screen = NSScreen.screens.first.map(Screen.init(nsScreen:)) else {
            Issue.record("No NSScreen available")
            return
        }
        let originalConfigurations = SettingsManager.shared.loadConfigurations()
        let originalOverlays = SettingsManager.shared.loadMonitorOverlays()
        defer {
            SettingsManager.shared.replaceAllConfigurations(originalConfigurations)
            SettingsManager.shared.saveMonitorOverlays(originalOverlays)
            OverlayController.shared.teardownAll()
        }

        SettingsManager.shared.replaceAllConfigurations([
            ScreenConfiguration(screenID: screen.id, wallpaper: .html(source: .inline("<p>gate</p>"), config: .default))
        ])
        var overlay = MonitorOverlayConfiguration.default
        overlay.enabled = true
        SettingsManager.shared.saveMonitorOverlays([screen.displayFingerprint: overlay])

        Self.withGate(true) {
            let manager = Self.makeManager(screen: screen)
            defer { screen.resetRuntimeSession() }
            guard manager.screens.contains(where: { $0.id == screen.id }) else {
                Issue.record("Injected display registry did not produce a screen")
                return
            }

            manager.reconcileMonitorOverlays()
            #expect(
                OverlayController.shared.hasActiveOverlay,
                "the overlay never came up, so switching it off proves nothing"
            )

            manager.setWallpapersEnabled(false)
            #expect(
                !OverlayController.shared.hasActiveOverlay,
                "overlays are still rendering with every wallpaper stopped"
            )

            // And back: the switch is not a one-way door.
            manager.setWallpapersEnabled(true)
            #expect(
                OverlayController.shared.hasActiveOverlay,
                "overlays did not come back when wallpapers were re-enabled"
            )
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

/// Independent configuration/gate dependencies: these async tests never change
/// the singleton master switch or the other MasterRenderGateTests' settings.
@Suite("Video selection while globally disabled")
@MainActor
struct VideoSelectionGateTests {
    @Test("A validated selection saves while off without preparing a player", arguments: [false, true])
    func disabledSelectionSavesWithoutBuilding(hasPrevious: Bool) async throws {
        let screen = try #require(NSScreen.screens.first.map(Screen.init(nsScreen:)))
        let persistence = GateSelectionPersistence()
        let store = WallpaperConfigurationStore(persistence: persistence)
        if hasPrevious {
            var previous = ScreenConfiguration(screenID: screen.id, videoBookmarkData: Data([0x11]))
            previous.displayFingerprint = screen.displayFingerprint
            previous.playbackSpeed = 0.75
            previous.videoVolume = 0.37
            previous.muted = true
            store.save(previous)
        }
        let loader = FakePlayableVideoLoader()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gate-selection-\(UUID().uuidString).mov")
        try Data().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        var enabled = false
        var builtPlayers: [WallpaperVideoPlayer] = []
        var notifications = 0
        let coordinator = PlaybackCoordinator(
            configurationStore: store,
            playableVideoLoader: loader,
            bookmarkResolver: SecurityScopedBookmarkResolver(
                resolveData: { _ in (url, false) }, refreshData: { _ in Data() }
            ),
            makeVideoPlayer: { url, frame, fitMode, entryName in
                let player = WallpaperVideoPlayer(
                    url: url, frame: frame, fitMode: fitMode,
                    packageEntryName: entryName, startsHidden: true, loadImmediately: false
                )
                builtPlayers.append(player)
                return player
            },
            validateSavedVideoConfiguration: { _ in true },
            applyPolicy: { _ in }, applyVideoEffects: { _, _ in },
            refreshRateLookup: { _ in 60 }, screensProvider: { [screen] },
            markSessionStateChanged: {}, releaseRuntimeSession: { $0.resetRuntimeSession() },
            notifyWallpaperSessionChanged: { notifications += 1 },
            originReconciler: PreservingOriginReconciler(), isGloballyEnabled: { enabled },
            notifyConfigurationChanged: { _ in }
        )
        defer {
            coordinator.transition.bumpTransition(for: screen.id)
            screen.resetRuntimeSession()
            builtPlayers.forEach { $0.cleanup() }
        }
        let bookmark = Data([0x22])
        coordinator.setVideo(url: url, bookmarkData: bookmark, for: screen)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while builtPlayers.isEmpty, notifications == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await loader.completedValidationCount == 1)
        #expect(builtPlayers.isEmpty, "Global off must not construct a playback candidate")
        #expect(notifications == 1)
        let saved = store.get(for: screen.id)
        #expect(saved?.videoBookmarkData == bookmark)
        #expect(screen.runtimeSession == nil)
        if hasPrevious {
            #expect(saved?.playbackSpeed == 0.75)
            #expect(saved?.videoVolume == 0.37)
            #expect(saved?.muted == true)
        }
        enabled = true
        let restored = try #require(saved)
        coordinator.applyConfiguration(restored, to: screen)
        #expect(builtPlayers.count == 1)
        #expect(builtPlayers.first?.videoURL == url, "Re-enabling must prepare the newly saved selection")
    }

    @Test("Rejected or stale disabled selections keep the latest configuration", arguments: [
        "media-validation", "saved-validation", "revision", "termination",
    ], [false, true])
    func rejectedDisabledSelectionDoesNotCommit(kind: String, hasPrevious: Bool) async throws {
        let screen = try #require(NSScreen.screens.first.map(Screen.init(nsScreen:)))
        let persistence = GateSelectionPersistence()
        let store = WallpaperConfigurationStore(persistence: persistence)
        var expected: ScreenConfiguration?
        if hasPrevious {
            var previous = ScreenConfiguration(screenID: screen.id, videoBookmarkData: Data([0x11]))
            previous.displayFingerprint = screen.displayFingerprint
            store.save(previous)
            expected = previous
        }
        let loader = FakePlayableVideoLoader(
            validationError: kind == "media-validation" ? .validationFailed : nil,
            suspendsValidation: true
        )
        var active = true
        var lifecycleChecks = 0
        var savedValidationChecks = 0
        var notifications = 0
        var errors = 0
        var builtPlayers: [WallpaperVideoPlayer] = []
        let coordinator = PlaybackCoordinator(
            configurationStore: store, playableVideoLoader: loader,
            bookmarkResolver: SecurityScopedBookmarkResolver(
                resolveData: { _ in throw CocoaError(.fileNoSuchFile) }, refreshData: { _ in Data() }
            ),
            makeVideoPlayer: { url, frame, fitMode, entryName in
                let player = WallpaperVideoPlayer(
                    url: url, frame: frame, fitMode: fitMode,
                    packageEntryName: entryName, startsHidden: true, loadImmediately: false
                )
                builtPlayers.append(player)
                return player
            },
            validateSavedVideoConfiguration: { _ in
                savedValidationChecks += 1
                return kind != "saved-validation"
            },
            applyPolicy: { _ in }, applyVideoEffects: { _, _ in },
            refreshRateLookup: { _ in 60 }, screensProvider: { [screen] },
            markSessionStateChanged: {}, releaseRuntimeSession: { $0.resetRuntimeSession() },
            notifyWallpaperSessionChanged: { notifications += 1 },
            reportRuntimeError: { _, error in
                if error != nil {
                    errors += 1
                }
            },
            originReconciler: PreservingOriginReconciler(), isGloballyEnabled: { false },
            isRuntimeInstallationAllowed: {
                lifecycleChecks += 1
                return active
            },
            notifyConfigurationChanged: { _ in }
        )
        defer {
            coordinator.transition.bumpTransition(for: screen.id)
            screen.resetRuntimeSession()
            builtPlayers.forEach { $0.cleanup() }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rejected-selection-\(UUID().uuidString).mov")
        coordinator.setVideo(url: url, bookmarkData: Data([0x22]), for: screen)
        let pendingDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await loader.pendingValidationCount == 0, ContinuousClock.now < pendingDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await loader.pendingValidationCount == 1)
        if kind == "revision" {
            var newer = ScreenConfiguration(screenID: screen.id, videoBookmarkData: Data([0x33]))
            newer.displayFingerprint = screen.displayFingerprint
            store.save(newer)
            expected = newer
        } else if kind == "termination" {
            active = false
        }
        await loader.resumeAllValidations()
        let completionDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while lifecycleChecks < 2, ContinuousClock.now < completionDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(lifecycleChecks >= 2)
        #expect(builtPlayers.isEmpty)
        #expect(notifications == 0)
        #expect(screen.runtimeSession == nil)
        #expect(store.get(for: screen.id) == expected)
        #expect(savedValidationChecks == (kind == "saved-validation" ? 1 : 0))
        #expect(errors == (kind == "media-validation" ? 1 : 0))
    }
}

@MainActor
private final class GateSelectionPersistence: ScreenConfigurationPersisting {
    private var configurations: [CGDirectDisplayID: ScreenConfiguration] = [:]

    func getConfiguration(for screenID: CGDirectDisplayID) -> ScreenConfiguration? {
        configurations[screenID]
    }

    func saveConfiguration(_ configuration: ScreenConfiguration) {
        configurations[configuration.screenID] = configuration
    }

    func cleanSettingsForScreen(_ screenID: CGDirectDisplayID) {
        configurations[screenID] = nil
    }

    func loadConfigurations() -> [ScreenConfiguration] {
        Array(configurations.values)
    }

    func replaceAllConfigurations(_ configurations: [ScreenConfiguration]) {
        self.configurations = Dictionary(uniqueKeysWithValues: configurations.map { ($0.screenID, $0) })
    }
}
