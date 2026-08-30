#if !LITE_BUILD
import AppKit
import QuartzCore

/// Target of the AppKit-vended `CADisplayLink`. Because the link is added to the render
/// thread's run loop, `step(_:)` fires there — it enters the actor's isolation
/// synchronously and produces exactly one frame, the same shape old MTKView `draw(in:)`
/// had. Holds the actor weakly: the link retains this target and the actor retains the link, so a strong back-reference would leak the actor (and the renderer).
final class WPEDisplayLinkTarget: NSObject {
    private weak var renderActor: WPEDisplayRenderActor?

    init(renderActor: WPEDisplayRenderActor) {
        self.renderActor = renderActor
        super.init()
    }

    @objc func step(_: CADisplayLink) {
        // On the render thread (the link's run loop). assumeIsolated grants sync
        // isolated access via the executor's checkIsolated — a misrouted callback
        // would trap rather than race.
        renderActor?.assumeIsolatedOnRenderThread { $0.renderFrame() }
    }
}

/// One-shot carrier handing a main-thread-created `CADisplayLink` to the render actor.
/// `@unchecked Sendable`: the link is created on main (`NSScreen`'s API is main-only) and
/// transferred exactly once; after `replaceDisplayLink` registers it on the render run
/// loop, only the render thread touches it. Falsifiable: unsound if the surface keeps/mutates the link after handoff, or hands the same link to two actors.
struct WPEDisplayLinkHandoff: @unchecked Sendable {
    let link: CADisplayLink
}

/// The renderer's pacing seam in `.renderThread` mode: the four pacing/redraw calls
/// (`applyPacing`/`setNeedsRedraw`/`drawImmediately`/`releaseDrawables`) are rerouted
/// here — pause+rate drive the render-thread `CADisplayLink`, a one-off redraw renders
/// one frame on the render thread — instead of touching the now purely-hosting MTKView.
/// Click capture, drawable release, and detach still forward straight to the
/// main-thread surface.
///
/// Renderer-owned calls arrive on the render thread and take the sync fast path, but
/// `WPESurfaceControl` is also an any-thread delivery seam (continuation/cancellation
/// callbacks from a cooperative executor), so off-thread calls hop back to the render
/// actor instead of entering `assumeIsolatedOnRenderThread` and trapping.
///
/// `@unchecked Sendable` (required by `WPESurfaceControl`): the only non-Sendable field
/// is `weak var renderActor` (a reference to a `Sendable` actor, nil'd only by ARC);
/// `surface` is itself `Sendable`. Falsifiable: breaks if a non-Sendable mutable field
/// is added or the off-thread branch mutates actor state outside `deliverToRenderActor`.
final class WPERenderThreadFramePacer: WPESurfaceControl, @unchecked Sendable {
    private weak var renderActor: WPEDisplayRenderActor?
    /// The real main-thread surface, kept behind the `Sendable` protocol so this
    /// pacer stays free of the concrete `@MainActor` view graph.
    private let surface: any WPESurfaceControl

    init(surface: any WPESurfaceControl, renderActor: WPEDisplayRenderActor) {
        self.surface = surface
        self.renderActor = renderActor
    }

    nonisolated func applyPacing(_ update: WPERenderPacingUpdate) {
        // `enableSetNeedsDisplay` is an MTKView knob; the host view stays paused,
        // so only the link's pause + rate matter here.
        deliverToRenderActor { actor in
            if let paused = update.isPaused { actor.setLinkPaused(paused) }
            if let fps = update.preferredFramesPerSecond { actor.setLinkPreferredFPS(fps) }
        }
        // The pointer-event monitor gate belongs to the main-thread surface (like
        // click capture); forward only that field so the view knobs stay dropped.
        if let pointerEvents = update.pointerEventsEnabled {
            surface.applyPacing(WPERenderPacingUpdate(pointerEventsEnabled: pointerEvents))
        }
    }

    nonisolated func setNeedsRedraw() {
        // Paused link (static scene) or one-off refresh: render exactly one frame on
        // the render thread — the single-frame effect the MTKView `setNeedsDisplay`
        // path produced.
        deliverToRenderActor { $0.renderFrame() }
    }

    nonisolated func drawImmediately() {
        // The old `mtkView.draw()` rendered synchronously before returning. Keep
        // that behavior for actor-owned calls; an any-thread protocol caller gets
        // non-blocking delivery onto the render actor.
        deliverToRenderActor { $0.renderFrame() }
    }

    nonisolated func releaseDrawables() { surface.releaseDrawables() }

    nonisolated func detach() { surface.detach() }

    nonisolated func setClickCaptureEnabled(_ enabled: Bool) {
        surface.setClickCaptureEnabled(enabled)
    }

    private nonisolated func deliverToRenderActor(
        _ body: @escaping @Sendable (isolated WPEDisplayRenderActor) -> Void
    ) {
        guard let actor = renderActor else { return }
        if actor.isOnRenderThread {
            actor.assumeIsolatedOnRenderThread(body)
        } else {
            Task {
                await actor.run(body)
            }
        }
    }
}
#endif
