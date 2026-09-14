#if !LITE_BUILD
import CoreGraphics
import Foundation

/// Decided before anything is sized: source downsample at load is irreversible. Does not gate the present-time scaler (`preScalerRejection` does); the plan governs what we allocate.
struct WPEMetalUpscalePlan: Equatable, Sendable {

    enum Verdict: String, Equatable, Sendable {
        case active
        case settingOff
        case deviceUnsupported
        /// HDR scene while display-HDR output is off: `rgba16Float` into an 8-bit drawable; the scaler does not tone map that pair.
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
    /// Multiplies the world canvas to get render-target pixels. Equals `displayFitScale` when `verdict != .active` (inactive MetalFX is bit-identical to the pre-feature path, and clamps canvases the display cannot resolve).
    let renderPixelScale: Double
    /// Largest scale (<= 1) at which no visible pixel is under-sampled. Independent of MetalFX: a scaler rejection falls back to this, not to 1.0.
    let displayFitScale: Double
    /// Longest source-texture edge worth uploading, or nil when inactive.
    let maxSourceTextureEdge: Int?
    /// The drawable this verdict was decided against. A present-time decline is only meaningful for THAT drawable — a reconfiguration can land a frame on a new size before the geometry callback.
    let plannedDrawableSize: CGSize

    var isActive: Bool { verdict == .active }

    static let inactive = WPEMetalUpscalePlan(
        verdict: .settingOff, renderPixelScale: 1.0, displayFitScale: 1.0,
        maxSourceTextureEdge: nil, plannedDrawableSize: .zero
    )

    /// Give up scaling for the rest of this scene after the present-time scaler declined. Keep `maxSourceTextureEdge`: those textures are already uploaded, and the reload path must keep matching them.
    func demotedToNative() -> WPEMetalUpscalePlan {
        WPEMetalUpscalePlan(
            verdict: .declinedAtPresent,
            // Not 1.0: scaler refusal says nothing about a canvas larger than the display. Going back to the authored canvas would restore the over-render this plan exists to prevent.
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

    /// Do not carry the texture cap over — the renderer latches it at upload (`latchedTextureCap`). A present-time decline is sticky: re-activating after the scaler refused would oscillate.
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

    /// No MetalFX upscale, but still never above what the display resolves. `maxSourceTextureEdge` stays nil: the cap is latched at upload, and a display clamp can change when the wallpaper moves screens.
    private static func inactive(
        _ verdict: Verdict, drawableSize: CGSize = .zero, displayFitScale: Double = 1.0
    ) -> WPEMetalUpscalePlan {
        WPEMetalUpscalePlan(
            verdict: verdict, renderPixelScale: displayFitScale, displayFitScale: displayFitScale,
            maxSourceTextureEdge: nil, plannedDrawableSize: drawableSize
        )
    }

    /// `contain` uses the smaller axis ratio (letterbox); `cover`/`stretch` use the larger (crop/fill). `center` is 1:1 — shrinking the source there shrinks the picture, so it never clamps.
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
        // HDR float only reaches the scaler when the drawable is float too (`MTLFXSpatialScaler` does not tone map float→8-bit).
        guard !isHDR || hdrOutputEnabled else { return withoutUpscale(.hdrScene) }
        guard fitMode != .center else { return withoutUpscale(.fitModeIncompatible) }

        // Scaler source must fit inside the drawable on both axes, so clamp is the smaller ratio (even when present uses the larger). Applied before the user's scale, or a canvas larger than the screen still renders above the drawable.
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
        // cover/contain compare aspects with zero tolerance; a coprime drawable admits no reduced integer size with the same ratio (never scales under cover/contain, only stretch). Final gate is the scaler's own predicate, so plan and present cannot disagree.
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
