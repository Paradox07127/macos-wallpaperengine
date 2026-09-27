import AppKit

@MainActor
public enum TestHostWindowParking {
    /// True in an XCTest host, where runtime windows must stay off the user's displays.
    public static var isEnabled = NSClassFromString("XCTestCase") != nil

    /// The frame to hand AppKit: shifted off every display in a test host, unchanged otherwise.
    public static func parkedFrame(_ frame: NSRect) -> NSRect {
        guard isEnabled, !isParked(frame) else { return frame }
        return frame.offsetBy(dx: offset, dy: offset)
    }

    public static func park(_ window: NSWindow) {
        let parked = parkedFrame(window.frame)
        if parked != window.frame {
            window.setFrameOrigin(parked.origin)
        }
    }

    /// The frame the window would have outside a test host.
    public static func logicalFrame(_ window: NSWindow) -> NSRect {
        let frame = window.frame
        guard isEnabled, isParked(frame) else { return frame }
        return frame.offsetBy(dx: -offset, dy: -offset)
    }

    private static let offset: CGFloat = -30000

    /// No display arrangement reaches x < -15000, so a parked frame is recognisable.
    private static func isParked(_ frame: NSRect) -> Bool {
        frame.origin.x < -15000
    }
}
