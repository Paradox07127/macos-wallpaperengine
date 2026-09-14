#if !LITE_BUILD
import CoreGraphics
import Foundation
import os

/// `.main`: enter isolation synchronously so `draw(in:)` returns only once the frame is produced. `.renderThread`: async latest-wins; a draw while one is pending is dropped, not queued.
@MainActor
final class WPERenderSurfaceClientShim: WPERenderSurfaceClient {
    private weak var renderActor: WPEDisplayRenderActor?

    /// True when the actor is `.main`-backed, so `draw(in:)` renders synchronously.
    private let synchronousDraw: Bool

    /// Set while a frame is scheduled/in flight (`.renderThread` only); lock-backed so the render actor's completion can clear it without actor isolation.
    private let frameInFlight = OSAllocatedUnfairLock(initialState: false)

    #if DEBUG
    private let completedFrameDeliveryCount = OSAllocatedUnfairLock(initialState: 0)
    var completedFrameDeliveries: Int { completedFrameDeliveryCount.withLock { $0 } }
    #endif

    init(renderActor: WPEDisplayRenderActor, backing: WPEDisplayRenderActor.Backing) {
        self.renderActor = renderActor
        switch backing {
        case .main: self.synchronousDraw = true
        case .renderThread: self.synchronousDraw = false
        }
    }

    func renderAndPresentFrame() {
        guard let renderActor else { return }
        if synchronousDraw {
            // Already on the actor's isolation thread (main). Enter synchronously so
            // the frame is produced before this returns.
            renderActor.assumeIsolatedOnRenderThread { $0.renderFrame() }
            #if DEBUG
            completedFrameDeliveryCount.withLock { $0 += 1 }
            #endif
            return
        }
        // test-and-set: skip if a render is already scheduled (latest-wins).
        let alreadyPending = frameInFlight.withLock { pending -> Bool in
            if pending { return true }
            pending = true
            return false
        }
        if alreadyPending { return }
        Task { [weak self, renderActor] in
            await renderActor.renderFrame()
            self?.frameInFlight.withLock { $0 = false }
            #if DEBUG
            self?.completedFrameDeliveryCount.withLock { $0 += 1 }
            #endif
        }
    }

    func updateSurfaceGeometry(drawableSize: CGSize) {
        renderActor?.submitConfig(.surfaceGeometry(drawableSize))
    }
}
#endif
