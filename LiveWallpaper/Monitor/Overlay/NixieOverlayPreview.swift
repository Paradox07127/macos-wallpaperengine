#if DEBUG
import AppKit
import LiveWallpaperCore

/// Opt-in, transient desktop preview. Never writes ScreenManager's saved board.
@MainActor
enum NixieOverlayPreview {
    static func present() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first,
              let screenID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else { return }
        let placement = MonitorWidgetPlacement(
            kind: .nixieClock, size: .medium,
            x: max(0, 0.5 - MonitorBoardMetrics.cellPitch / screen.frame.width), y: 0.66
        )
        let board = MonitorBoardConfiguration(widgets: [placement], mouseInteractionEnabled: false)
        OverlayController.shared.apply(
            overlay: MonitorOverlayConfiguration(enabled: true, level: .desktop, board: board),
            screenID: screenID, screenFrame: screen.frame
        )
    }
}
#endif
