import AppKit
import SwiftUI

/// A native drag target only behind toolbar whitespace; SwiftUI controls above it keep their hits.
struct WindowDragRegion: NSViewRepresentable {
    func makeNSView(context _: Context) -> DragView {
        let view = DragView()
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_: DragView, context _: Context) {}

    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool {
            true
        }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                window?.performZoom(nil)
            } else {
                window?.performDrag(with: event)
            }
        }
    }
}

/// Trackpad navigation is scoped to the canvas, never the inspector or horizontal add strip.
struct DetailBackSwipe: NSViewRepresentable {
    let enabled: Bool
    let action: () -> Void

    func makeNSView(context _: Context) -> SwipeView {
        SwipeView()
    }

    func updateNSView(_ nsView: SwipeView, context _: Context) {
        nsView.enabled = enabled
        nsView.action = action
    }

    static func dismantleNSView(_ nsView: SwipeView, coordinator _: ()) {
        nsView.stop()
    }

    final class SwipeView: NSView {
        var enabled = false
        var action: () -> Void = {}
        private var monitor: Any?
        private var gesture = DetailBackSwipeGesture()
        private var tracking = false
        private var lastEventTime: TimeInterval = 0
        override func hitTest(_: NSPoint) -> NSView? {
            nil
        }

        override func viewDidMoveToWindow() {
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                let consumed = MainActor.assumeIsolated {
                    guard let self else { return false }
                    guard self.enabled, event.window === self.window, self.window?.attachedSheet == nil,
                          event.hasPreciseScrollingDeltas, event.momentumPhase.isEmpty else { return false }
                    let begins = event.phase.contains(.began) || event.phase.contains(.mayBegin)
                        || (!self.tracking && event.timestamp - self.lastEventTime > 0.25)
                    self.lastEventTime = event.timestamp
                    if begins {
                        self.tracking = self.bounds.contains(self.convert(event.locationInWindow, from: nil))
                        self.gesture = DetailBackSwipeGesture()
                    }
                    guard self.tracking else { return false }
                    let dx = event.scrollingDeltaX * (event.isDirectionInvertedFromDevice ? 1 : -1)
                    let fired = self.gesture.update(dx: dx, dy: event.scrollingDeltaY)
                    if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                        self.tracking = false
                    }
                    if fired {
                        self.tracking = false; self.action(); return true
                    }
                    return false
                }
                return consumed ? nil : event
            }
        }

        func stop() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
            tracking = false
        }
    }
}

/// Physical leftward displacement; vertical scrolling and short diagonal jitter never navigate.
struct DetailBackSwipeGesture {
    private var x: CGFloat = 0
    private var y: CGFloat = 0
    private var rejected = false
    mutating func update(dx: CGFloat, dy: CGFloat) -> Bool {
        guard !rejected else { return false }
        x += dx
        y += dy
        if abs(y) > 16, abs(y) > abs(x) {
            rejected = true
        }
        return !rejected && x < -96 && abs(x) > abs(y) * 1.6
    }
}
