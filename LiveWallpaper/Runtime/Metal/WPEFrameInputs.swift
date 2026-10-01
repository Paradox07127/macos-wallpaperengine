#if !LITE_BUILD
import Foundation

struct WPEFrameInputs: Sendable {
    /// Mailbox `clickCaptureEnabled` — the per-screen Interaction toggle.
    let clickCaptureEnabled: Bool
    /// Result of `pointerSampler.sample()`. Sampled unconditionally here; the mouse-interaction gate stays in `sampleFrameContext` because it reads renderer-private `mouseInteractionEnabled`.
    let pointerSample: WPEMetalPointerSample
    let pointerFrame: WPEPointerFrame
    let buttonCursor: WPEPointerMailbox.ButtonCursor?
    let buttonsSuppressed: Bool

    init(clickCaptureEnabled: Bool, pointerSample: WPEMetalPointerSample,
         pointerFrame: WPEPointerFrame, preferredFramesPerSecond: Int,
         buttonCursor: WPEPointerMailbox.ButtonCursor? = nil, buttonsSuppressed: Bool = false) {
        self.clickCaptureEnabled = clickCaptureEnabled
        self.pointerSample = pointerSample
        self.pointerFrame = pointerFrame
        self.preferredFramesPerSecond = preferredFramesPerSecond
        self.buttonCursor = buttonCursor
        self.buttonsSuppressed = buttonsSuppressed
    }

    /// The renderer's `effectiveFPS`, used only by the audio-capture diag log.
    let preferredFramesPerSecond: Int
}
#endif
