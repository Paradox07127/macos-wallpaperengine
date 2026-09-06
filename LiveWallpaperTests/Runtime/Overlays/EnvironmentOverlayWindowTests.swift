import AppKit
import LiveWallpaperCore
import XCTest
@testable import LiveWallpaper

/// The particle layer belongs between the wallpaper and the desktop icons.
///
/// `NSPanel.isFloatingPanel` rewrites `level` to `.floating` (3), so setting it
/// after the level silently promoted the particles above every application
/// window and it rained over whatever the user was working in. Nothing about
/// that ordering is visible at the call site, hence the test.
final class EnvironmentOverlayWindowTests: XCTestCase {

    @MainActor
    func testParticleOverlayStaysBelowApplicationWindows() throws {
        let controller = EnvironmentOverlayController()
        let screenID = CGDirectDisplayID(1)
        defer { controller.teardownAll() }

        controller.apply(
            effect: .rain, density: 1, screenID: screenID,
            screenFrame: NSRect(x: 0, y: 0, width: 200, height: 200)
        )

        let level = try XCTUnwrap(controller.debugWindowLevel(screenID: screenID))
        XCTAssertLessThan(
            level, NSWindow.Level.normal.rawValue,
            "particles are at or above application windows (level \(level))"
        )
        // An HTML wallpaper with mouse interaction on sits at
        // `desktopIconWindow + 1`; below that and the particles are invisible
        // rather than merely well-behaved.
        XCTAssertGreaterThan(
            level, Int(CGWindowLevelForKey(.desktopIconWindow)) + 1,
            "particles would be drawn under an interactive wallpaper"
        )
    }

    /// A resolution change or arrangement drag moves the wallpaper window via
    /// `updateAllWindowFrames()`, but the particle overlay's frame was only ever
    /// written from `apply()` — so it stayed at the old size/position until the
    /// next unrelated config change rebuilt the emitter.
    @MainActor
    func testParticleOverlayFrameFollowsResolutionChange() throws {
        let controller = EnvironmentOverlayController()
        let screenID = CGDirectDisplayID(1)
        defer { controller.teardownAll() }

        controller.apply(
            effect: .rain, density: 1, screenID: screenID,
            screenFrame: NSRect(x: 0, y: 0, width: 200, height: 200)
        )
        let initialFrame = try XCTUnwrap(controller.debugWindowFrame(screenID: screenID))
        XCTAssertEqual(initialFrame.size, NSSize(width: 200, height: 200))

        let newFrame = NSRect(x: 100, y: 50, width: 400, height: 300)
        controller.updateFrame(screenID: screenID, frame: newFrame)

        let updatedFrame = try XCTUnwrap(controller.debugWindowFrame(screenID: screenID))
        XCTAssertEqual(updatedFrame, newFrame, "particle overlay frame did not follow the resolution/arrangement change")
    }

    /// "Show wallpaper in screen capture" reached the wallpaper windows and the
    /// Monitor board but not this panel: `makeHost` never set `sharingType`, so
    /// with the setting off the rain still went into a screen share.
    @MainActor
    func testParticleOverlayHonoursTheCapturePolicy() {
        let restore = WallpaperCapturePolicy.allowsScreenCapture
        defer { WallpaperCapturePolicy.allowsScreenCapture = restore }
        let controller = EnvironmentOverlayController()
        let screenID = CGDirectDisplayID(1)
        defer { controller.teardownAll() }

        WallpaperCapturePolicy.allowsScreenCapture = false
        controller.apply(
            effect: .rain, density: 1, screenID: screenID,
            screenFrame: NSRect(x: 0, y: 0, width: 200, height: 200)
        )
        XCTAssertEqual(
            controller.debugWindowSharingType(screenID: screenID), NSWindow.SharingType.none,
            "a new overlay ignored the capture setting"
        )

        WallpaperCapturePolicy.allowsScreenCapture = true
        controller.applyCapturePolicy(WallpaperCapturePolicy.windowSharingType)
        XCTAssertEqual(
            controller.debugWindowSharingType(screenID: screenID), .readOnly,
            "a policy change did not reach a live overlay"
        )
    }

    /// Unplugging a display releases its wallpaper session before `screens` is
    /// updated, so the reconcile inside that release still sees the display and
    /// keeps its particle panel; nothing swept it afterwards. AppKit moves a
    /// window whose display is gone onto one that remains, so the unplugged
    /// display's rain landed on top of the survivor's.
    @MainActor
    func testParticleOverlayLeavesWithItsDisplay() throws {
        let screen = try Screen(nsScreen: XCTUnwrap(NSScreen.main))
        var live: [Screen] = [screen]
        let store = WallpaperConfigurationStore(persistence: InMemoryConfigurationPersistence())
        var configuration = ScreenConfiguration(screenID: screen.id, videoBookmarkData: Data())
        configuration.particleEffect = .rain
        store.save(configuration)
        let coordinator = WallpaperEffectsCoordinator(
            configurationStore: store,
            screensProvider: { live },
            saveConfiguration: { _ in },
            applyFrameRateLimit: { _, _ in },
            screenRefreshRate: { _ in 60 }
        )
        defer { coordinator.shutdown() }

        coordinator.reconcileEnvironmentOverlays()
        XCTAssertNotNil(
            coordinator.debugEnvironmentOverlay.debugSuspensionReasons(screenID: screen.id),
            "no overlay was built to begin with"
        )

        live = []
        coordinator.screensDidChange(arrivedScreenIDs: [])
        XCTAssertNil(
            coordinator.debugEnvironmentOverlay.debugSuspensionReasons(screenID: screen.id),
            "the overlay outlived its display"
        )
    }
}

@MainActor
private final class InMemoryConfigurationPersistence: ScreenConfigurationPersisting {
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
