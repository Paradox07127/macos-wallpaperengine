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
}
