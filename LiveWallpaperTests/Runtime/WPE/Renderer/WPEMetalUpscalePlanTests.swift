import CoreGraphics
import Testing
@testable import LiveWallpaper

/// The load-time MetalFX verdict. Every rejection the present-time scaler can
/// make for a reason known up front must be made here instead — a scene that
/// renders small and is then refused has paid resolution for nothing.
@Suite("WPE MetalFX upscale plan")
struct WPEMetalUpscalePlanTests {

    private static let hd = CGSize(width: 1920, height: 1080)
    private static let uhd = CGSize(width: 3840, height: 2160)

    private static func plan(
        canvas: CGSize = hd,
        drawable: CGSize = uhd,
        fitMode: WPEPresentFitMode = .cover,
        isHDR: Bool = false,
        renderScale: Double = 0.75,
        deviceSupports: Bool = true
    ) -> WPEMetalUpscalePlan {
        WPEMetalUpscalePlan.make(
            worldCanvas: canvas,
            drawableSize: drawable,
            fitMode: fitMode,
            isHDR: isHDR,
            renderScale: renderScale,
            deviceSupportsScaler: deviceSupports
        )
    }

    // MARK: - Every inactive verdict must be a true no-op

    @Test("Inactive verdicts all render at full resolution and cap no textures")
    func inactiveVerdictsAreTrueNoOps() {
        let inactive: [(String, WPEMetalUpscalePlan)] = [
            ("settingOff", Self.plan(renderScale: 1.0)),
            ("deviceUnsupported", Self.plan(deviceSupports: false)),
            ("hdr", Self.plan(isHDR: true)),
            ("center", Self.plan(fitMode: .center)),
            ("aspectMismatch", Self.plan(drawable: CGSize(width: 1728, height: 1117))),
        ]
        for (label, plan) in inactive {
            #expect(plan.isActive == false, "\(label) must not be active")
            // The bit-identity guarantee: an inactive plan has to leave every
            // downstream size derivation exactly where it was pre-feature.
            #expect(plan.renderPixelScale == 1.0, "\(label) must not scale targets")
            #expect(plan.maxSourceTextureEdge == nil, "\(label) must not cap textures")
        }
    }

    @Test("Each rejection reports its own reason")
    func verdictsAreDistinguishable() {
        #expect(Self.plan(renderScale: 1.0).verdict == .settingOff)
        #expect(Self.plan(deviceSupports: false).verdict == .deviceUnsupported)
        #expect(Self.plan(isHDR: true).verdict == .hdrScene)
        #expect(Self.plan(fitMode: .center).verdict == .fitModeIncompatible)
        #expect(Self.plan(drawable: CGSize(width: 1728, height: 1117)).verdict == .aspectMismatch)
    }

    // MARK: - Active sizing

    @Test("Matching aspect keeps the requested scale")
    func matchingAspectUsesRequestedScale() {
        let plan = Self.plan()
        #expect(plan.verdict == .active)
        #expect(plan.renderPixelScale == 0.75)
        // 1920x1080 x 0.75 = 1440x810, longest edge 1440.
        #expect(plan.maxSourceTextureEdge == 1440)
    }

    @Test("A canvas larger than the screen is clamped to the screen BEFORE scaling")
    func canvasLargerThanDrawableClampsToDrawable() {
        // 4K scene on a 1080p display: without the clamp this renders 2880x1620,
        // which the scaler then refuses as a downscale — the saving stops at the
        // authored canvas instead of following the screen.
        let plan = Self.plan(canvas: Self.uhd, drawable: Self.hd)
        #expect(plan.verdict == .active)
        #expect(plan.renderPixelScale == 0.375)
        let pixels = WPEMetalFXSpatialUpscaler.scaledCanvasSize(
            Self.uhd, pixelScale: plan.renderPixelScale
        )
        #expect(pixels == CGSize(width: 1440, height: 810))
        #expect(pixels.width < Self.hd.width)
        #expect(pixels.height < Self.hd.height)
    }

    @Test("Never renders above the authored canvas")
    func neverSupersamples() {
        // A tiny canvas on a 4K screen must not be promoted to drawable size —
        // that is supersampling, the opposite of this feature.
        let plan = Self.plan(canvas: CGSize(width: 640, height: 360))
        #expect(plan.renderPixelScale <= 0.75)
    }

    @Test("Stretch tolerates a mismatched aspect that cover rejects")
    func stretchIgnoresAspect() {
        let odd = CGSize(width: 1728, height: 1117)
        #expect(Self.plan(drawable: odd, fitMode: .cover).verdict == .aspectMismatch)
        let stretched = Self.plan(drawable: odd, fitMode: .stretch)
        #expect(stretched.verdict == .active)
        #expect(stretched.renderPixelScale < 0.75)
    }

    @Test("A sizeless drawable is its own verdict, and re-planning revives it")
    func drawableUnknownThenReplan() {
        // Real-machine regression: the layer has no size until its view enters a
        // window, and `load()` can win the race against that callback. Reported
        // as `noHeadroom` before, which read like a legitimate rejection.
        let atLoad = Self.plan(canvas: Self.uhd, drawable: .zero)
        #expect(atLoad.verdict == .drawableUnknown)
        #expect(atLoad.renderPixelScale == 1.0)

        // Geometry lands → the scene must start scaling.
        let revived = atLoad.adopting(Self.plan(canvas: Self.uhd, drawable: Self.uhd))
        #expect(revived.verdict == .active)
        #expect(revived.renderPixelScale == 0.75)
        // The cap is latched separately at upload time, so the refreshed plan
        // simply reports what it would be.
        #expect(revived.maxSourceTextureEdge == 2880)
    }

    @Test("A present-time decline is sticky across re-planning")
    func declineIsSticky() {
        let declined = Self.plan(canvas: Self.uhd, drawable: Self.uhd).demotedToNative()
        #expect(declined.verdict == .declinedAtPresent)
        // Re-activating after the scaler already refused would just oscillate.
        let readopted = declined.adopting(Self.plan(canvas: Self.uhd, drawable: Self.uhd))
        #expect(readopted.verdict == .declinedAtPresent)
        #expect(readopted.renderPixelScale == 1.0)
    }

    @Test("Degenerate sizes fall back to inactive instead of trapping")
    func degenerateSizes() {
        #expect(Self.plan(canvas: .zero).isActive == false)
        #expect(Self.plan(drawable: .zero).isActive == false)
    }

    // MARK: - Plan and runtime must never disagree

    @Test("An active plan's pixel size passes the scaler's own eligibility check")
    func activePlanAgreesWithRuntimePredicate() {
        let cases: [(CGSize, CGSize, WPEPresentFitMode)] = [
            (Self.hd, Self.uhd, .cover),
            (Self.uhd, Self.hd, .cover),
            (Self.hd, CGSize(width: 1728, height: 1117), .stretch),
            (CGSize(width: 2560, height: 1440), Self.uhd, .contain),
        ]
        for (canvas, drawable, fitMode) in cases {
            let plan = Self.plan(canvas: canvas, drawable: drawable, fitMode: fitMode)
            guard plan.isActive else { continue }
            let pixels = WPEMetalFXSpatialUpscaler.scaledCanvasSize(
                canvas, pixelScale: plan.renderPixelScale
            )
            // If these ever diverge the frame renders small and is then refused
            // at present — resolution paid for nothing.
            #expect(WPEMetalFXSpatialUpscaler.preScalerRejection(
                fitMode: fitMode,
                sourceWidth: Int(pixels.width),
                sourceHeight: Int(pixels.height),
                drawableWidth: Int(drawable.width),
                drawableHeight: Int(drawable.height)
            ) == nil, "plan says active but the scaler would refuse \(canvas) -> \(drawable)")
        }
    }

    @Test("contain and stretch both reach the active path")
    func nonCoverFitModesActivate() {
        // Without this the agreement test above silently skips them: its
        // `guard plan.isActive else { continue }` turns a broken contain path
        // into a green run.
        let contain = Self.plan(
            canvas: CGSize(width: 2560, height: 1440), drawable: Self.uhd, fitMode: .contain
        )
        #expect(contain.verdict == .active)
        #expect(contain.renderPixelScale == 0.75)
        #expect(Self.plan(fitMode: .stretch).verdict == .active)
    }

    /// The two canvas shapes that dominate this machine's actual library:
    /// 77% of scenes author 3840x2160, and the largest author 7680x4320. Both
    /// are presented on a 3840x2160 drawable.
    @Test("The corpus's dominant 4K canvas really renders below native")
    func realWorldCorpusShapes() {
        let fourK = Self.plan(canvas: Self.uhd, drawable: Self.uhd)
        #expect(fourK.verdict == .active)
        let fourKPixels = WPEMetalFXSpatialUpscaler.scaledCanvasSize(
            Self.uhd, pixelScale: fourK.renderPixelScale
        )
        #expect(fourKPixels == CGSize(width: 2880, height: 1620))

        // 8K canvas: the drawable clamp bites before the user's scale does.
        let eightK = CGSize(width: 7680, height: 4320)
        let plan8 = Self.plan(canvas: eightK, drawable: Self.uhd)
        #expect(plan8.verdict == .active)
        let pixels8 = WPEMetalFXSpatialUpscaler.scaledCanvasSize(
            eightK, pixelScale: plan8.renderPixelScale
        )
        #expect(pixels8 == CGSize(width: 2880, height: 1620))
    }

    @Test("A coprime drawable cannot scale under cover, but still can under stretch")
    func coprimeDrawableAspect() {
        // 1081 and 1920 are coprime, so no reduced integer size keeps the ratio
        // and the zero-tolerance cover gate must refuse. Documented as a real
        // constraint, not a gap — scaling anyway would hand the scaler a
        // full-rect map that cover did not ask for.
        let odd = CGSize(width: 1920, height: 1081)
        #expect(Self.plan(canvas: odd, drawable: odd, fitMode: .cover).verdict == .aspectMismatch)
        #expect(Self.plan(canvas: odd, drawable: odd, fitMode: .stretch).verdict == .active)
    }

    @Test("A decline only sticks when it came from the planned drawable")
    func declineNeedsMatchingDrawable() {
        let plan = Self.plan(canvas: Self.uhd, drawable: Self.uhd)
        #expect(plan.declineIsConclusive(forDrawableSize: Self.uhd))
        // A display reconfiguration can land a frame on a new drawable before
        // the geometry callback arrives; that refusal says nothing about this plan.
        #expect(plan.declineIsConclusive(forDrawableSize: Self.hd) == false)
    }

    @Test("The texture cap equals the longest edge actually rendered")
    func textureCapMatchesRenderedEdge() {
        for (canvas, drawable) in [(Self.hd, Self.uhd), (Self.uhd, Self.hd)] {
            let plan = Self.plan(canvas: canvas, drawable: drawable)
            let pixels = WPEMetalFXSpatialUpscaler.scaledCanvasSize(
                canvas, pixelScale: plan.renderPixelScale
            )
            #expect(plan.maxSourceTextureEdge == Int(max(pixels.width, pixels.height)))
        }
    }
}
