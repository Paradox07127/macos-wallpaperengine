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
        /// An HDR scene while display-HDR output is off: the scene renders `rgba16Float`
        /// into an 8-bit drawable, and the scaler does not tone map across that pair.
        /// With HDR output on the pair is float→float and the scaler runs in `.hdr` mode,
        /// so this verdict no longer applies.
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
    /// Multiplies the WORLD canvas to get render-target pixels. Equals
    /// `displayFitScale` whenever `verdict != .active`, so an inactive MetalFX
    /// verdict is bit-identical to the pre-feature path for every canvas the
    /// display can actually resolve, and clamps the ones it cannot.
    let renderPixelScale: Double
    /// Largest scale (<= 1) at which no pixel the viewer sees is under-sampled.
    /// Below 1 only when the authored canvas exceeds the drawable — rendering
    /// above it is pixels the display cannot resolve. Independent of MetalFX:
    /// shrinking the source is right whether the scaler runs or the plain present
    /// blit does, which is why a scaler rejection falls back to THIS, not to 1.0.
    let displayFitScale: Double
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
        verdict: .settingOff, renderPixelScale: 1.0, displayFitScale: 1.0,
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
            // NOT 1.0: the scaler refusing to upscale says nothing about a canvas
            // larger than the display, which the plain present blit resolves just
            // as well. Going back to the authored canvas here would restore the
            // over-render this plan exists to prevent.
            renderPixelScale: displayFitScale,
            displayFitScale: displayFitScale,
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
        guard verdict != .declinedAtPresent else {
            // The refusal sticks, but a new drawable still gets its own display clamp —
            // keeping the old one would over-render (or under-render) the new display.
            return WPEMetalUpscalePlan(
                verdict: .declinedAtPresent,
                renderPixelScale: fresh.displayFitScale,
                displayFitScale: fresh.displayFitScale,
                maxSourceTextureEdge: maxSourceTextureEdge,
                plannedDrawableSize: fresh.plannedDrawableSize
            )
        }
        return WPEMetalUpscalePlan(
            verdict: fresh.verdict,
            renderPixelScale: fresh.renderPixelScale,
            displayFitScale: fresh.displayFitScale,
            maxSourceTextureEdge: fresh.maxSourceTextureEdge,
            plannedDrawableSize: fresh.plannedDrawableSize
        )
    }

    /// No MetalFX upscale, but still never above what the display resolves.
    /// `verdict` keeps naming the MetalFX rejection so a shipping log can still
    /// answer "why did this machine not upscale"; `maxSourceTextureEdge` stays nil
    /// because the source-texture cap is latched irreversibly at upload and a
    /// display clamp can change when the wallpaper moves screens.
    private static func inactive(
        _ verdict: Verdict, drawableSize: CGSize = .zero, displayFitScale: Double = 1.0
    ) -> WPEMetalUpscalePlan {
        WPEMetalUpscalePlan(
            verdict: verdict, renderPixelScale: displayFitScale, displayFitScale: displayFitScale,
            maxSourceTextureEdge: nil, plannedDrawableSize: drawableSize
        )
    }

    /// The per-axis drawable/canvas ratios the present transform actually applies, reduced
    /// to one uniform scale that under-samples nothing. `contain` letterboxes, so the
    /// smaller ratio is the whole picture; `cover` crops and `stretch` fills, so the larger
    /// ratio is what the visible pixels are scaled by. `center` presents 1:1 — shrinking the
    /// source there shrinks the picture, so it never clamps.
    static func displayFitScale(
        worldCanvas: CGSize, drawableSize: CGSize, fitMode: WPEPresentFitMode
    ) -> Double {
        guard worldCanvas.width > 0, worldCanvas.height > 0,
              drawableSize.width > 0, drawableSize.height > 0 else { return 1.0 }
        let axisX = Double(drawableSize.width / worldCanvas.width)
        let axisY = Double(drawableSize.height / worldCanvas.height)
        let fit: Double = switch fitMode {
        case .center: 1.0
        case .contain: min(axisX, axisY)
        case .cover, .stretch: max(axisX, axisY)
        }
        // Never above 1: rendering past the authored canvas is supersampling, a
        // different feature.
        return min(1.0, fit)
    }

    static func make(
        worldCanvas: CGSize,
        drawableSize: CGSize,
        fitMode: WPEPresentFitMode,
        isHDR: Bool,
        hdrOutputEnabled: Bool,
        renderScale: Double,
        deviceSupportsScaler: Bool
    ) -> WPEMetalUpscalePlan {
        // Sizes first: the display clamp is not a MetalFX feature and survives every
        // rejection below, so nothing may return before it is known.
        guard drawableSize.width > 0, drawableSize.height > 0 else {
            return inactive(.drawableUnknown)
        }
        guard worldCanvas.width > 0, worldCanvas.height > 0 else {
            return inactive(.noHeadroom)
        }
        let displayFit = displayFitScale(
            worldCanvas: worldCanvas, drawableSize: drawableSize, fitMode: fitMode
        )
        func withoutUpscale(_ verdict: Verdict) -> WPEMetalUpscalePlan {
            inactive(verdict, drawableSize: drawableSize, displayFitScale: displayFit)
        }

        guard renderScale < 1.0 else { return withoutUpscale(.settingOff) }
        guard deviceSupportsScaler else { return withoutUpscale(.deviceUnsupported) }
        // An HDR scene renders float. That only reaches the scaler when the drawable is
        // float too — i.e. display-HDR output is on — because `MTLFXSpatialScaler` does not
        // tone map a float source down to an 8-bit drawable. With HDR output on, the pair
        // is float→float and the scaler runs in `.hdr` mode.
        guard !isHDR || hdrOutputEnabled else { return withoutUpscale(.hdrScene) }
        guard fitMode != .center else { return withoutUpscale(.fitModeIncompatible) }

        // The scaler's source must fit inside the drawable on BOTH axes
        // (`preScalerRejection`), so its clamp is the smaller ratio even where the present
        // transform scales by the larger one. Applied BEFORE the user's scale: without it an
        // authored canvas larger than the screen keeps rendering above the drawable even at
        // 0.75, the scaler refuses it as a downscale, and the saving stops at the authored
        // canvas instead of following the screen.
        let scalerFit = min(
            1.0,
            Double(min(
                drawableSize.width / worldCanvas.width,
                drawableSize.height / worldCanvas.height
            ))
        )
        let effectiveScale = scalerFit * renderScale

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
            case .aspectMismatch: return withoutUpscale(.aspectMismatch)
            case .fitMode: return withoutUpscale(.fitModeIncompatible)
            default: return withoutUpscale(.noHeadroom)
            }
        }

        return WPEMetalUpscalePlan(
            verdict: .active,
            renderPixelScale: effectiveScale,
            displayFitScale: displayFit,
            maxSourceTextureEdge: Int(max(pixelSize.width, pixelSize.height)),
            plannedDrawableSize: drawableSize
        )
    }
}
#endif
