#if !LITE_BUILD
import AppKit
import QuartzCore

/// Holds the actor weakly: the link retains this target and the actor retains the link, so a strong back-reference would leak.
final class WPEDisplayLinkTarget: NSObject {
    private weak var renderActor: WPEDisplayRenderActor?

    init(renderActor: WPEDisplayRenderActor) {
        self.renderActor = renderActor
        super.init()
    }

    @objc func step(_: CADisplayLink) {
        // assumeIsolated grants sync access via checkIsolated — a misrouted callback would trap rather than race.
        renderActor?.assumeIsolatedOnRenderThread { $0.renderFrame() }
    }
}

/// `@unchecked Sendable`: the link is created on main (`NSScreen`'s API is main-only) and
/// transferred exactly once; after `replaceDisplayLink` registers it on the render run loop,
/// only the render thread touches it. Unsound if the surface keeps or mutates the link after
/// handoff, or hands the same link to two actors.
struct WPEDisplayLinkHandoff: @unchecked Sendable {
    let link: CADisplayLink
}

/// Off-thread calls hop back to the render actor instead of entering
/// `assumeIsolatedOnRenderThread` and trapping.
///
/// `@unchecked Sendable` (required by `WPESurfaceControl`): the only non-Sendable field is
/// `weak var renderActor` (a reference to a `Sendable` actor, nil'd only by ARC); `surface`
/// is itself `Sendable`. Breaks if a non-Sendable mutable field is added, or if the
/// off-thread branch mutates actor state outside `deliverToRenderActor`.
final class WPERenderThreadFramePacer: WPESurfaceControl, @unchecked Sendable {
    private weak var renderActor: WPEDisplayRenderActor?
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
        deliverToRenderActor { $0.renderFrame() }
    }

    nonisolated func drawImmediately() {
        // Actor-owned calls keep the old synchronous `mtkView.draw()` behavior; any-thread callers get non-blocking delivery.
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
