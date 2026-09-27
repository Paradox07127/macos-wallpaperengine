import AppKit

/// A titled window is pulled onto a display when it is ordered in; this one stays where it is put.
final class ParkedTestWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to _: NSScreen?) -> NSRect {
        frameRect
    }
}

extension NSWindow {
    /// Ordered in, as clicks, key presses and SwiftUI need, yet out of sight and without activating the app.
    func parkOffScreen() {
        let parked = NSPoint(x: -30000, y: -30000)
        setFrameOrigin(parked)
        orderBack(nil)
        // AppKit keeps a corner of a titled window on a display however far it is moved, unless its class
        // overrides `constrainFrameRect` like `ParkedTestWindow`; that corner is made transparent instead.
        if frame.origin != parked {
            setFrameOrigin(parked)
            alphaValue = 0
        }
    }
}
