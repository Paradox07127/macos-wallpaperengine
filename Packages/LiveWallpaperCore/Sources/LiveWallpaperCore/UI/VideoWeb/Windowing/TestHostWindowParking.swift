import AppKit

@MainActor
public enum TestHostWindowParking {
    /// True in an XCTest host, where runtime windows must stay off the user's displays.
    public static var isEnabled = NSClassFromString("XCTestCase") != nil

    public static func park(_ window: NSWindow) {
        guard isEnabled else { return }
        // Beyond any display arrangement; only the origin moves, so the size stays what the caller built.
        window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
    }
}
