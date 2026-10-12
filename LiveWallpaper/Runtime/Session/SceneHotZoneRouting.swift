#if !LITE_BUILD
import CoreGraphics
import Foundation

/// Turns hot-zone panel events into pointer frames for one mailbox; keep one per mailbox so gesture state carries across events.
@MainActor
struct SceneHotZoneRouter {
    private var frame = WPEPointerFrame.neutral
    private var pressLocation: CGPoint?

    /// `zone` is drawable UV (top-left origin); `viewFrame` and the result are AppKit screen rects (bottom-left origin).
    nonisolated static func screenRect(forZone zone: CGRect, in viewFrame: CGRect) -> CGRect {
        CGRect(x: viewFrame.minX + zone.minX * viewFrame.width,
               y: viewFrame.maxY - zone.maxY * viewFrame.height,
               width: zone.width * viewFrame.width,
               height: zone.height * viewFrame.height)
    }

    /// View UV clamped to [0,1], as the native view reports a press that leaves its bounds.
    nonisolated static func clampedUV(_ location: CGPoint, in viewFrame: CGRect) -> SIMD2<Double> {
        guard viewFrame.width > 0, viewFrame.height > 0 else { return WPEPointerFrame.neutral.position }
        return SIMD2(Double((location.x - viewFrame.minX) / viewFrame.width),
                     1 - Double((location.y - viewFrame.minY) / viewFrame.height)).clamped(lowerBound: .zero, upperBound: .one)
    }

    /// True when a pointer frame was published; the caller must then wake the renderer, whose display link may be parked.
    mutating func route(_ event: SceneHotZoneEvent, to mailbox: WPEPointerMailbox, viewFrame: CGRect) -> Bool {
        switch event.kind {
        case .moved:
            mailbox.publishMouseLocation(event.screenLocation,
                                         timestampNanos: event.timestamp > 0 ? UInt64(event.timestamp * 1_000_000_000) : 0)
            mailbox.publishPointerPosition(screenLocation: event.screenLocation)
            return false
        case .entered, .exited:
            return false
        case .down, .dragged, .up, .rightDown, .rightUp:
            let sample = mailbox.sample(screenLocation: event.screenLocation)
            let uv = sample.isInsideView ? sample.position : Self.clampedUV(event.screenLocation, in: viewFrame)
            mailbox.publishPointerFrame(pointerFrame(for: event, uv: uv), isInsideView: true)
            return true
        }
    }

    /// `uv` is the event's view UV (top-left origin).
    mutating func pointerFrame(for event: SceneHotZoneEvent, uv: SIMD2<Double>) -> WPEPointerFrame {
        frame.position = uv
        switch event.kind {
        case .down:
            frame.clickPosition = uv
            frame.isDown = true
            frame.gesture = WPEPointerGesture.next()
            frame.dragged = false
            pressLocation = event.screenLocation
        case .dragged:
            if let pressLocation, hypot(event.screenLocation.x - pressLocation.x,
                                        event.screenLocation.y - pressLocation.y) > DesktopClickObserver.dragThreshold {
                frame.dragged = true
            }
        case .up:
            frame.isDown = false
            pressLocation = nil
        case .rightDown:
            frame.clickPosition = uv
            frame.isRightDown = true
        case .rightUp:
            frame.isRightDown = false
        case .moved, .entered, .exited:
            break
        }
        return frame
    }
}
#endif
