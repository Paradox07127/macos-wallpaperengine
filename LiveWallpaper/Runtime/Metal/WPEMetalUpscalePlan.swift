#if !LITE_BUILD
import CoreGraphics
import Foundation

/// Whether MetalFX render scaling can pay off, decided before anything is sized.
/// Source textures downsample at load (irreversible), so deferring the decision to
/// present time (where the scaler's own check lives) is too late — a scene rendered
/// small and then refused paid the resolution for nothing; every knowable rejection
/// is made here.
///
/// A derived value, not one-shot: inputs land at different times (world canvas from
/// parsing, drawable from window layout, fit mode from config submit), so each change
/// refreshes it via `refreshUpscalePlan` — only the texture cap latches.
///
/// Does NOT gate the present-time scaler: perspective renders at a drawable-derived
/// world size and still needs the scaler to restore it — the plan governs what we
/// allocate, `preScalerRejection` governs what we present.
struct WPEMetalUpscalePlan: Equatable, Sendable {

    /// Carried into the logs so a shipping session can answer "did this machine
    /// actually upscale, and if not why" instead of leaving it to inference.
    enum Verdict: String, Equatable, Sendable {
        case active
        case settingOff
        case deviceUnsupported
        /// `rgba16Float`, which the `.perceptual` scaler refuses — measured
        /// `created=false` on Apple M5 Pro.
        case hdrScene
        /// `.center` keeps source pixels 1:1, so a full-rect scale is never right.
        case fitModeIncompatible
        /// cover/contain only match the scaler's full-rect map at an equal aspect.
        case aspectMismatch
        case noHeadroom
        /// The scaler refused a real frame; scaling given up for this scene.
        case declinedAtPresent
        /// Not a rejection but a "re-plan when geometry lands" state.
        case drawableUnknown
    }

    let verdict: Verdict
    /// Multiplies the WORLD canvas to get render-target pixels. Exactly 1.0
    /// whenever `verdict != .active`, which keeps every downstream size
    /// derivation bit-identical to the pre-feature path.
    let renderPixelScale: Double
    /// Longest source-texture edge worth uploading, or nil when inactive.
    let maxSourceTextureEdge: Int?
    /// The drawable this verdict was decided against. A present-time decline is
    /// only meaningful when the frame was presented to THAT drawable: a display
    /// reconfiguration can land a frame on a new, smaller drawable before the
    /// geometry callback arrives, and treating that as a permanent refusal
    /// would strand the scene at native for no reason.
    let plannedDrawableSize: CGSize

    var isActive: Bool { verdict == .active }

    static let inactive = WPEMetalUpscalePlan(
        verdict: .settingOff, renderPixelScale: 1.0,
        maxSourceTextureEdge: nil, plannedDrawableSize: .zero
    )

    /// Give up scaling for the rest of this scene after the present-time scaler declined
    /// anyway. Load-time inputs can't see everything: `makeSpatialScaler` can refuse a
    /// size/format pair the device claims to support, the drawable's usage can fall short,
    /// and `presentFitMode` can change after the plan was fixed — whatever the cause, a
    /// declined frame means the resolution was paid for nothing, so subsequent frames render native. `maxSourceTextureEdge` is deliberately kept: those textures are already uploaded, and the reload path must keep matching them.
    func demotedToNative() -> WPEMetalUpscalePlan {
        WPEMetalUpscalePlan(
            verdict: .declinedAtPresent,
            renderPixelScale: 1.0,
            maxSourceTextureEdge: maxSourceTextureEdge,
            plannedDrawableSize: plannedDrawableSize
        )
    }

    /// Whether a decline seen while presenting to `drawableSize` reflects THIS
    /// plan rather than a drawable that changed under it.
    func declineIsConclusive(forDrawableSize drawableSize: CGSize) -> Bool {
        drawableSize == plannedDrawableSize
    }

    /// Take a freshly computed verdict after the drawable size became known or changed,
    /// keeping what cannot be redone. The cap is NOT carried over — it's latched
    /// separately by the renderer when textures upload (`latchedTextureCap`), the only
    /// point the decision becomes irreversible; freezing it here instead meant a plan
    /// decided before the fit mode/drawable settled could cap uploads for a verdict that
    /// no longer held. A present-time decline is sticky: re-activating after the scaler
    /// already refused would just oscillate.
    func adopting(_ fresh: WPEMetalUpscalePlan) -> WPEMetalUpscalePlan {
        guard verdict != .declinedAtPresent else { return self }
        return WPEMetalUpscalePlan(
            verdict: fresh.verdict,
            renderPixelScale: fresh.renderPixelScale,
            maxSourceTextureEdge: fresh.maxSourceTextureEdge,
            plannedDrawableSize: fresh.plannedDrawableSize
        )
    }

    private static func inactive(
        _ verdict: Verdict, drawableSize: CGSize = .zero
    ) -> WPEMetalUpscalePlan {
        WPEMetalUpscalePlan(
            verdict: verdict, renderPixelScale: 1.0,
            maxSourceTextureEdge: nil, plannedDrawableSize: drawableSize
        )
    }

    static func make(
        worldCanvas: CGSize,
        drawableSize: CGSize,
        fitMode: WPEPresentFitMode,
        isHDR: Bool,
        renderScale: Double,
        deviceSupportsScaler: Bool
    ) -> WPEMetalUpscalePlan {
        guard renderScale < 1.0 else { return inactive(.settingOff) }
        guard deviceSupportsScaler else { return inactive(.deviceUnsupported) }
        guard !isHDR else { return inactive(.hdrScene) }
        guard fitMode != .center else { return inactive(.fitModeIncompatible) }
        guard drawableSize.width > 0, drawableSize.height > 0 else {
            return inactive(.drawableUnknown)
        }
        guard worldCanvas.width > 0, worldCanvas.height > 0 else {
            return inactive(.noHeadroom)
        }

        // Clamp the canvas to what the display can actually resolve BEFORE applying the
        // user's scale. Without this, an authored canvas larger than the screen (a 4K scene
        // on a 1080p display) keeps rendering above the drawable even at 0.75 — the scaler
        // then refuses it as a downscale, and the saving stops at the authored canvas instead of following the screen. Capped at 1.0 because rendering ABOVE the authored canvas is supersampling, a different feature.
        let drawableFit = min(
            drawableSize.width / worldCanvas.width,
            drawableSize.height / worldCanvas.height
        )
        let effectiveScale = min(1.0, Double(drawableFit)) * renderScale

        let pixelSize = WPEMetalFXSpatialUpscaler.scaledCanvasSize(
            worldCanvas, pixelScale: effectiveScale
        )
        // NOTE: cover/contain compare aspects with zero tolerance (deliberate — a letterbox
        // the scaler stretched away is still wrong), and a drawable whose dimensions are
        // coprime admits NO reduced integer size with the same ratio, so such a display never
        // scales under cover/contain, only under stretch — correct rather than a gap: scaling
        // it would hand the scaler a full-rect map the fit mode did not ask for. The final
        // gate is the scaler's OWN predicate rather than a copy of its rules, so the plan and
        // the present path can never disagree about eligibility.
        if let rejection = WPEMetalFXSpatialUpscaler.preScalerRejection(
            fitMode: fitMode,
            sourceWidth: Int(pixelSize.width),
            sourceHeight: Int(pixelSize.height),
            drawableWidth: Int(drawableSize.width),
            drawableHeight: Int(drawableSize.height)
        ) {
            switch rejection {
            case .aspectMismatch: return inactive(.aspectMismatch)
            case .fitMode: return inactive(.fitModeIncompatible)
            default: return inactive(.noHeadroom)
            }
        }

        return WPEMetalUpscalePlan(
            verdict: .active,
            renderPixelScale: effectiveScale,
            maxSourceTextureEdge: Int(max(pixelSize.width, pixelSize.height)),
            plannedDrawableSize: drawableSize
        )
    }
}
#endif
