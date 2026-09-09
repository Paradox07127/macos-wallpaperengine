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
        let clock = ClockOverlayConfiguration(enabled: true)
        OverlayController.shared.apply(
            overlay: MonitorOverlayConfiguration(clock: clock),
            screenID: screenID, screenFrame: screen.frame
        )
    }
}
#endif
