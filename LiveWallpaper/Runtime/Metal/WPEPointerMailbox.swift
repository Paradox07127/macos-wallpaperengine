#if !LITE_BUILD
import CoreGraphics
import Foundation
import os
import simd

final class WPEPointerMailbox: Sendable {
    /// View frame in screen coordinates (bottom-left origin). A zero-size rect means no active surface and resolves samples to `.inactive`.
    struct Geometry: Equatable, Sendable {
        var viewFrameInScreen: CGRect
        static let none = Geometry(viewFrameInScreen: .zero)
    }

    struct Reading: Equatable, Sendable {
        var pointerSample: WPEMetalPointerSample
        var pointerFrame: WPEPointerFrame
        var clickCaptureEnabled: Bool
        var mouseTimestampNanos: UInt64
    }

    private struct State {
        var mouseScreenLocation: CGPoint
        var mouseTimestampNanos: UInt64
        var geometry: Geometry
        var pointerFrame: WPEPointerFrame
        var clickCaptureEnabled: Bool
    }

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

    func publishPointerFrame(_ frame: WPEPointerFrame) {
        lock.withLock { $0.pointerFrame = frame }
    }

    func setClickCaptureEnabled(_ enabled: Bool) {
        lock.withLock { $0.clickCaptureEnabled = enabled }
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
                mouseTimestampNanos: state.mouseTimestampNanos
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
        guard rect.width > 0, rect.height > 0, rect.contains(location) else {
            return .inactive
        }
        let x = Double((location.x - rect.minX) / rect.width)
        let y = 1.0 - Double((location.y - rect.minY) / rect.height)
        return .inside(SIMD2<Double>(x, y))
    }
}
#endif
