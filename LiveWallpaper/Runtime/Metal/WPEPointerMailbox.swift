#if !LITE_BUILD
import CoreGraphics
import Foundation
import os
import simd

final class WPEPointerMailbox: Sendable {
    /// View frame in screen coordinates (bottom-left origin). A zero-size rect means no active surface and resolves samples to `.inactive`.
    struct Geometry: Equatable, Sendable {
        var viewFrameInScreen: CGRect
        var interactiveFrames: [CGRect]?
        static let none = Geometry(viewFrameInScreen: .zero)
    }

    /// A snapshot high-water mark: peeking never consumes input.
    struct ButtonCursor: Equatable, Sendable {
        let epoch: UInt64
        let sequence: UInt64
    }

    struct ButtonEdge: Equatable, Sendable {
        let cursor: ButtonCursor
        let frame: WPEPointerFrame
        let isInsideView: Bool
        /// Delivered by the desktop-click observer while the wallpaper stays click-through.
        let fromDesktop: Bool
    }

    struct ButtonBatch: Sendable {
        let edges: [ButtonEdge]
        let cancelled: Bool
        let snapshotCurrent: Bool
    }

    struct Reading: Equatable, Sendable {
        var pointerSample: WPEMetalPointerSample
        var pointerFrame: WPEPointerFrame
        var clickCaptureEnabled: Bool
        var mouseTimestampNanos: UInt64
        var buttonCursor: ButtonCursor
        var buttonsSuppressed: Bool
    }

    private struct State {
        var mouseScreenLocation: CGPoint
        var mouseTimestampNanos: UInt64
        var geometry: Geometry
        var pointerFrame: WPEPointerFrame
        /// Edge detection for desktop clicks only; `pointerFrame` stays the native path and shader-uniform source.
        var desktopFrame: WPEPointerFrame = .neutral
        var clickCaptureEnabled: Bool
        var epoch: UInt64 = 0
        var sequence: UInt64 = 0
        var edges: [ButtonEdge] = []
        var cancelled = false
        var suppressed = false
    }

    private let buttonCapacity = 256

    private let lock = OSAllocatedUnfairLock(
        initialState: State(
            // Off-screen sentinel: before the first geometry/mouse push, any read
            // maps to `.inactive` (geometry is `.none`, so the location is moot).
            mouseScreenLocation: CGPoint(x: -.greatestFiniteMagnitude,
                                         y: -.greatestFiniteMagnitude),
            mouseTimestampNanos: 0,
            geometry: .none,
            pointerFrame: .neutral,
            clickCaptureEnabled: false
        )
    )

    // MARK: - Writers (last-write-wins)

    func publishMouseLocation(_ screenLocation: CGPoint, timestampNanos: UInt64) {
        lock.withLock { state in
            state.mouseScreenLocation = screenLocation
            state.mouseTimestampNanos = timestampNanos
        }
    }

    func publishGeometry(_ geometry: Geometry) {
        lock.withLock { $0.geometry = geometry }
    }

    func publishPointerFrame(_ frame: WPEPointerFrame, isInsideView: Bool = true) {
        lock.withLock { state in
            let changed = frame.isDown != state.pointerFrame.isDown
                || frame.isRightDown != state.pointerFrame.isRightDown
            state.pointerFrame = frame
            guard state.clickCaptureEnabled else { return }
            if state.suppressed {
                if !frame.isDown, !frame.isRightDown {
                    state.suppressed = false
                    state.epoch &+= 1
                }
                return
            }
            guard changed else { return }
            guard state.edges.count < buttonCapacity else {
                Self.cancel(&state)
                return
            }
            state.sequence &+= 1
            var eligible = isInsideView
            if state.geometry.interactiveFrames != nil {
                let rect = state.geometry.viewFrameInScreen
                let screenLocation = CGPoint(x: rect.minX + frame.position.x * rect.width,
                                             y: rect.minY + (1 - frame.position.y) * rect.height)
                eligible = eligible && Self.pointerSample(forScreenLocation: screenLocation,
                                                          geometry: state.geometry).isInsideView
            }
            state.edges.append(ButtonEdge(cursor: .init(epoch: state.epoch, sequence: state.sequence),
                                          frame: frame, isInsideView: eligible, fromDesktop: false))
        }
    }

    /// Dropped while click capture is on: that screen's native path already delivers the same press.
    /// `gatedByClickCapture: false` = the caller judged capture per display (span: the flag is any member's Interaction).
    func publishDesktopButtonFrame(_ frame: WPEPointerFrame, isInsideView: Bool, gatedByClickCapture: Bool = true) {
        lock.withLock { state in
            guard !(gatedByClickCapture && state.clickCaptureEnabled) else { return }
            let changed = frame.isDown != state.desktopFrame.isDown
            state.desktopFrame = frame
            if state.suppressed {
                if !frame.isDown {
                    state.suppressed = false
                    state.epoch &+= 1
                }
                return
            }
            guard changed else { return }
            guard state.edges.count < buttonCapacity else {
                Self.cancel(&state)
                return
            }
            state.sequence &+= 1
            state.edges.append(ButtonEdge(cursor: .init(epoch: state.epoch, sequence: state.sequence),
                                          frame: frame, isInsideView: isInsideView, fromDesktop: true))
        }
    }

    func setClickCaptureEnabled(_ enabled: Bool) {
        lock.withLock { state in
            guard state.clickCaptureEnabled != enabled else { return }
            state.clickCaptureEnabled = enabled
            Self.cancel(&state)
        }
    }

    func resetButtonEvents() {
        lock.withLock { Self.cancel(&$0) }
    }

    private static func cancel(_ state: inout State) {
        state.edges.removeAll(keepingCapacity: true)
        state.epoch &+= 1
        state.cancelled = true
        state.suppressed = state.pointerFrame.isDown || state.pointerFrame.isRightDown
        // Otherwise a press cut off here leaves desktopFrame down and the next desktop press is not seen as a change.
        state.desktopFrame = .neutral
    }

    func isCurrentButtonCursor(_ cursor: ButtonCursor) -> Bool {
        lock.withLock { $0.epoch == cursor.epoch }
    }

    func takeButtonEvents(through cursor: ButtonCursor) -> ButtonBatch {
        lock.withLock { state in
            guard cursor.epoch == state.epoch else {
                // An old snapshot cannot consume a new scene's events.
                return ButtonBatch(edges: [], cancelled: true, snapshotCurrent: false)
            }
            let count = state.edges.prefix { $0.cursor.sequence <= cursor.sequence }.count
            let edges = Array(state.edges.prefix(count))
            state.edges.removeFirst(count)
            let cancelled = state.cancelled
            state.cancelled = false
            return ButtonBatch(edges: edges, cancelled: cancelled, snapshotCurrent: true)
        }
    }

    // MARK: - Reader

    func read() -> Reading {
        lock.withLock { state in
            Reading(
                pointerSample: Self.pointerSample(
                    forScreenLocation: state.mouseScreenLocation,
                    geometry: state.geometry
                ),
                pointerFrame: state.pointerFrame,
                clickCaptureEnabled: state.clickCaptureEnabled,
                mouseTimestampNanos: state.mouseTimestampNanos,
                buttonCursor: .init(epoch: state.epoch, sequence: state.sequence),
                buttonsSuppressed: state.suppressed
            )
        }
    }

    func sample(screenLocation: CGPoint) -> WPEMetalPointerSample {
        lock.withLock { state in
            Self.pointerSample(
                forScreenLocation: screenLocation,
                geometry: state.geometry
            )
        }
    }

    // MARK: - Pure mapping

    /// Assumes the wallpaper view fills its window with an identity bounds↔frame transform (no scaling); if a view ever scales, carry the bounds size in `Geometry` and divide by it here.
    static func pointerSample(
        forScreenLocation location: CGPoint,
        geometry: Geometry
    ) -> WPEMetalPointerSample {
        let rect = geometry.viewFrameInScreen
        guard rect.width > 0, rect.height > 0, rect.contains(location),
              geometry.interactiveFrames?.contains(where: { $0.contains(location) }) ?? true else {
            return .inactive
        }
        let x = Double((location.x - rect.minX) / rect.width)
        let y = 1.0 - Double((location.y - rect.minY) / rect.height)
        return .inside(SIMD2<Double>(x, y))
    }
}
#endif
