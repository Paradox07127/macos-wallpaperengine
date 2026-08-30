#if !LITE_BUILD
import CoreGraphics
import Foundation
import os

/// Main-thread delivery shim between `WPERenderSurface` (AppKit MTKView owner) and
/// `WPEMetalSceneRenderer` (frame producer): funnels `draw(in:)`/drawable-size
/// callbacks onto the render actor instead of calling the renderer inline, because
/// `draw(in:)` is always on the main thread but the renderer lives in
/// `WPEDisplayRenderActor`, which may be backed by a dedicated render thread.
///
/// Backing-dependent delivery (passed at construction):
/// - `.main`: `draw(in:)` already runs on the actor's isolation thread, so the shim
///   enters isolation **synchronously** via `assumeIsolatedOnRenderThread` and renders
///   inline — preserving "`draw(in:)` returns only once the frame is produced" (an
///   async hop would let `draw` return before the render ran).
/// - `.renderThread`: an async, latest-wins hop. `frameInFlight` allows at most one
///   scheduled frame — a `draw` arriving while one is pending is dropped, not queued,
///   because `renderFrame` always reads the newest renderer state, so the pending
///   render presents it and folds in the dropped draw's side effects (an appended
///   live-poster continuation, a fresh `outputTexture`).
@MainActor
final class WPERenderSurfaceClientShim: WPERenderSurfaceClient {
    /// The render actor to deliver onto. Weak: the actor owns the renderer, which
    /// owns this shim; this points back so it can schedule without a retain cycle.
    private weak var renderActor: WPEDisplayRenderActor?

    /// True when the actor is `.main`-backed, so `draw(in:)` renders synchronously.
    private let synchronousDraw: Bool

    /// Set while a frame render is scheduled/in flight (`.renderThread` only);
    /// test-and-set on `draw`, cleared when that render completes. An
    /// `OSAllocatedUnfairLock<Bool>` (the library's Sendable-flag idiom) so the
    /// flag is safe to touch from the render actor's completion without itself
    /// being actor-isolated state.
    private let frameInFlight = OSAllocatedUnfairLock(initialState: false)

    #if DEBUG
    /// Frames the shim has finished delivering. For the synchronous (`.main`) path the
    /// increment happens inline before `renderAndPresentFrame` returns; for the async path
    /// it happens in the completion (off-main), so it's lock-backed rather than
    /// actor-isolated — the observable for the "draw returns = frame produced" invariant.
    /// DEBUG-only: the counter has no production reader, and incrementing it took a lock on every frame of every display.
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
        // Geometry is a Sendable value; deliver through the actor's ordered config
        // channel so only the latest size ever wins and it stays ordered against
        // the other config setters. No render-value dependency, so a one-frame
        // latency is fine.
        renderActor?.submitConfig(.surfaceGeometry(drawableSize))
    }
}
#endif
