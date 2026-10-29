#if !LITE_BUILD
import AppKit
import MetalKit
import os
import simd

@MainActor
final class WPEInteractiveMTKView: MTKView {
    /// Flipped by the renderer from the per-screen "Interaction" toggle. Only
    /// while true does this view consume mouse events.
    var clickCaptureEnabled = false

    private(set) var pointerIsInsideView = false

    /// Handlers assign this once with the whole frame: each `didSet` publishes, and the mailbox keeps the frame of the edge-changing write.
    private(set) var pointerFrame: WPEPointerFrame = .neutral {
        didSet { onPointerFrameChange?(pointerFrame) }
    }

    /// `didSet` fires this on each event-driven mutation (never on the `.neutral` initializer, which doesn't trigger `didSet`).
    var onPointerFrameChange: (@MainActor (WPEPointerFrame) -> Void)?

    override var acceptsFirstResponder: Bool { clickCaptureEnabled }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { clickCaptureEnabled }

    /// AppKit only delivers `mouseMoved(with:)` to a view with a `.mouseMoved` tracking area; without this, hovering never updates the pointer. `.activeAlways` because the wallpaper window is never key.
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    /// Screen location of each touch-drag sample. Touches never reach the pointer publisher's NSEvent monitors, so it listens here instead.
    var onTouchDragLocation: (@MainActor (CGPoint) -> Void)?

    override init(frame frameRect: CGRect, device: MTLDevice?) {
        super.init(frame: frameRect, device: device)
        if #available(macOS 27, *) {
            let pan = NSPanGestureRecognizer(target: self, action: #selector(handleTouchPan(_:)))
            pan.maximumNumberOfTouches = 1
            pan.delegate = self
            addGestureRecognizer(pan)
        }
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
    }

    /// Top-left-origin normalized UV of a window-coordinate point, matching the scene's UV
    /// convention (same flip as `WPEMetalPointerSampler.normalizedSceneUV`).
    private func uv(atWindowLocation location: CGPoint) -> SIMD2<Double> {
        guard bounds.width > 0, bounds.height > 0 else {
            pointerIsInsideView = false
            return SIMD2<Double>(0.5, 0.5)
        }
        let local = convert(location, from: nil)
        pointerIsInsideView = bounds.contains(local)
        let x = Double(local.x / bounds.width)
        let y = 1.0 - Double(local.y / bounds.height)
        return SIMD2<Double>(min(max(x, 0), 1), min(max(y, 0), 1))
    }

    private func uv(for event: NSEvent) -> SIMD2<Double> {
        uv(atWindowLocation: event.locationInWindow)
    }

    func pointerDown(atWindowLocation location: CGPoint) {
        let position = uv(atWindowLocation: location)
        var frame = pointerFrame
        frame.position = position
        frame.clickPosition = position
        frame.isDown = true
        frame.gesture = WPEPointerGesture.next()
        pointerFrame = frame
    }

    func pointerDragged(atWindowLocation location: CGPoint) {
        pointerFrame.position = uv(atWindowLocation: location)
    }

    func pointerUp(atWindowLocation location: CGPoint) {
        var frame = pointerFrame
        frame.position = uv(atWindowLocation: location)
        frame.isDown = false
        pointerFrame = frame
    }

    override func mouseDown(with event: NSEvent) {
        guard clickCaptureEnabled else { super.mouseDown(with: event); return }
        pointerDown(atWindowLocation: event.locationInWindow)
    }

    override func mouseDragged(with event: NSEvent) {
        guard clickCaptureEnabled else { super.mouseDragged(with: event); return }
        pointerDragged(atWindowLocation: event.locationInWindow)
    }

    override func mouseUp(with event: NSEvent) {
        guard clickCaptureEnabled else { super.mouseUp(with: event); return }
        pointerUp(atWindowLocation: event.locationInWindow)
    }

    @objc private func handleTouchPan(_ recognizer: NSPanGestureRecognizer) {
        touchPan(recognizer.state, atWindowLocation: recognizer.location(in: nil))
    }

    /// The touch counterpart of mouseDown/Dragged/Up; `location` is in window coordinates.
    func touchPan(_ state: NSGestureRecognizer.State, atWindowLocation location: CGPoint) {
        guard clickCaptureEnabled else { return }
        switch state {
        case .began:
            pointerDown(atWindowLocation: location)
        case .changed:
            pointerDragged(atWindowLocation: location)
        case .ended, .cancelled:
            pointerUp(atWindowLocation: location)
            return
        default:
            return
        }
        if let window {
            onTouchDragLocation?(window.convertPoint(toScreen: location))
        }
    }

    override func mouseMoved(with event: NSEvent) {
        guard clickCaptureEnabled else { super.mouseMoved(with: event); return }
        pointerFrame.position = uv(for: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard clickCaptureEnabled else { super.rightMouseDown(with: event); return }
        let position = uv(for: event)
        var frame = pointerFrame
        frame.position = position
        frame.clickPosition = position
        frame.isRightDown = true
        pointerFrame = frame
    }

    override func rightMouseUp(with event: NSEvent) {
        guard clickCaptureEnabled else { super.rightMouseUp(with: event); return }
        var frame = pointerFrame
        frame.position = uv(for: event)
        frame.isRightDown = false
        pointerFrame = frame
    }

    override func rightMouseDragged(with event: NSEvent) {
        guard clickCaptureEnabled else { super.rightMouseDragged(with: event); return }
        pointerFrame.position = uv(for: event)
    }
}

extension WPEInteractiveMTKView: NSGestureRecognizerDelegate {
    /// AppKit asks this only for mouse events, so returning false leaves the pan to touches.
    func gestureRecognizer(_: NSGestureRecognizer, shouldAttemptToRecognizeWith _: NSEvent) -> Bool {
        false
    }

    func gestureRecognizerShouldBegin(_: NSGestureRecognizer) -> Bool {
        clickCaptureEnabled
    }
}

/// Per-frame captured pointer/button state fed into the scene uniforms. Position
/// fields are top-left-origin UV in `[0,1]`. Neutral = centered, no buttons.
struct WPEPointerFrame: Equatable, Sendable {
    var position: SIMD2<Double>
    var clickPosition: SIMD2<Double>
    var isDown: Bool
    var isRightDown: Bool
    /// Left-press identity shared by its down/up/click; 0 = no physical press.
    var gesture: UInt64 = 0
    /// True once the pointer moved past the drag threshold since this press; its release synthesises no click.
    var dragged = false

    static let neutral = WPEPointerFrame(
        position: SIMD2<Double>(0.5, 0.5),
        clickPosition: SIMD2<Double>(0.5, 0.5),
        isDown: false,
        isRightDown: false
    )
}

enum WPEPointerGesture {
    private static let counter = OSAllocatedUnfairLock(initialState: UInt64(0))

    /// Process-unique, starting at 1.
    static func next() -> UInt64 {
        counter.withLock { value in
            value &+= 1
            return value
        }
    }
}
#endif
