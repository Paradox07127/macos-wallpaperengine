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

/// One swipe's step: `previous` is the display to the left, or home from the leftmost.
enum DetailSwipeStep: Equatable {
    case previous
    case next
}

/// Trackpad navigation is scoped to the canvas, never the inspector or horizontal add strip.
struct DetailSwipeNavigator: NSViewRepresentable {
    let enabled: Bool
    let navigate: (DetailSwipeStep) -> Void

    func makeNSView(context _: Context) -> SwipeView {
        SwipeView()
    }

    func updateNSView(_ nsView: SwipeView, context _: Context) {
        nsView.enabled = enabled
        nsView.navigate = navigate
    }

    static func dismantleNSView(_ nsView: SwipeView, coordinator _: ()) {
        nsView.stop()
    }

    final class SwipeView: NSView {
        var enabled = false
        var navigate: (DetailSwipeStep) -> Void = { _ in }
        private var monitor: Any?
        private var tracker = DetailSwipeTracker()
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
                    let step = self.tracker.handle(
                        began: event.phase.contains(.began) || event.phase.contains(.mayBegin),
                        ended: event.phase.contains(.ended) || event.phase.contains(.cancelled),
                        timestamp: event.timestamp,
                        startsInside: self.bounds.contains(self.convert(event.locationInWindow, from: nil)),
                        dx: event.scrollingDeltaX * (event.isDirectionInvertedFromDevice ? 1 : -1),
                        dy: event.scrollingDeltaY
                    )
                    guard let step else { return false }
                    self.navigate(step)
                    return true
                }
                return consumed ? nil : event
            }
        }

        func stop() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
            tracker = DetailSwipeTracker()
        }
    }
}

/// One step per gesture: once a step fires, the rest of that gesture is ignored until the next one begins.
struct DetailSwipeTracker {
    private var gesture = DetailSwipeGesture()
    private var tracking = false
    private var lastEventTime: TimeInterval = 0

    /// `began` / `ended`: the event's phase opens (`.began`, `.mayBegin`) or closes (`.ended`, `.cancelled`) a gesture.
    mutating func handle(
        began: Bool, ended: Bool, timestamp: TimeInterval, startsInside: Bool, dx: CGFloat, dy: CGFloat
    ) -> DetailSwipeStep? {
        // Precise events without a phase open a new gesture after 0.25s of silence.
        let begins = began || (!tracking && timestamp - lastEventTime > 0.25)
        lastEventTime = timestamp
        if begins {
            tracking = startsInside
            gesture = DetailSwipeGesture()
        }
        guard tracking else { return nil }
        let step = gesture.update(dx: dx, dy: dy)
        if ended || step != nil {
            tracking = false
        }
        return step
    }
}

/// Physical finger travel, positive x being the fingers moving right; vertical scrolling and short diagonal jitter never step.
struct DetailSwipeGesture {
    private var x: CGFloat = 0
    private var y: CGFloat = 0
    private var rejected = false
    mutating func update(dx: CGFloat, dy: CGFloat) -> DetailSwipeStep? {
        guard !rejected else { return nil }
        x += dx
        y += dy
        if abs(y) > 16, abs(y) > abs(x) {
            rejected = true
        }
        guard !rejected, abs(x) > 96, abs(x) > abs(y) * 1.6 else { return nil }
        return x > 0 ? .previous : .next
    }
}
