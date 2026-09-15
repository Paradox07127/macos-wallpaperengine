import AppKit
import SwiftUI

// Experimental input layer only; never linked into the product target.
struct NativeResizeEvents: NSViewRepresentable {
    let onDrag: (CGFloat, Bool) -> Void
    func makeNSView(context: Context) -> TrackingView { TrackingView() }
    func updateNSView(_ view: TrackingView, context: Context) { view.onDrag = onDrag }
    final class TrackingView: NSView {
        var onDrag: ((CGFloat, Bool) -> Void)?
        private var origin: CGFloat?
        private var dragging = false
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { origin = event.locationInWindow.x; dragging = false }
        override func mouseDragged(with event: NSEvent) {
            guard let origin else { return }
            let delta = event.locationInWindow.x - origin
            if abs(delta) >= 2 { dragging = true }
            if dragging { onDrag?(delta, false) }
        }
        override func mouseUp(with event: NSEvent) {
            if let origin, dragging { onDrag?(event.locationInWindow.x - origin, true) }
            origin = nil; dragging = false
        }
    }
}
