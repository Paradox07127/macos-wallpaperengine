import AppKit
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

/// The particle layer follows the system Reduce Motion switch live; the board
/// read it once at init and on `apply`, so the two disagreed until the next
/// reconcile rebuilt the board.
@Suite("Monitor board follows Reduce Motion")
struct BoardReduceMotionTests {
    @MainActor
    @Test("A board already on the desktop picks up the switch; a configured override still wins")
    func boardFollowsTheSwitch() {
        let host = HostView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600),
            configuration: MonitorBoardConfiguration(widgets: [])
        )
        host.reduceMotionWatcherOverride = false
        host.apply(configuration: MonitorBoardConfiguration(widgets: []))
        #expect(host.debugReduceMotion == false)

        host.reduceMotionWatcherOverride = true
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil
        )
        #expect(host.debugReduceMotion == true, "the board kept the value it read at init")

        host.apply(configuration: MonitorBoardConfiguration(widgets: [], reduceMotionOverride: false))
        #expect(host.debugReduceMotion == false)
    }
}
