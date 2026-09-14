#if !LITE_BUILD
import Foundation

struct WPEFrameInputs: Sendable {
    /// Mailbox `clickCaptureEnabled` — the per-screen Interaction toggle.
    let clickCaptureEnabled: Bool
    /// Result of `pointerSampler.sample()`. Sampled unconditionally here; the mouse-interaction gate stays in `sampleFrameContext` because it reads renderer-private `mouseInteractionEnabled`.
    let pointerSample: WPEMetalPointerSample
    let pointerFrame: WPEPointerFrame
    /// The renderer's `effectiveFPS`, used only by the audio-capture diag log.
    let preferredFramesPerSecond: Int
}
#endif
