import CoreGraphics
import Testing
@testable import LiveWallpaper

@Suite("WPE MetalFX upscale plan")
struct WPEMetalUpscalePlanTests {

    private static let hd = CGSize(width: 1920, height: 1080)
    private static let uhd = CGSize(width: 3840, height: 2160)

    private static func plan(
        canvas: CGSize = hd,
        drawable: CGSize = uhd,
        fitMode: WPEPresentFitMode = .cover,
        isHDR: Bool = false,
        hdrOutputEnabled: Bool = false,
        renderScale: Double = 0.75,
        deviceSupports: Bool = true
    ) -> WPEMetalUpscalePlan {
        WPEMetalUpscalePlan.make(
            worldCanvas: canvas,
            drawableSize: drawable,
            fitMode: fitMode,
            isHDR: isHDR,
            hdrOutputEnabled: hdrOutputEnabled,
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
            #expect(plan.renderPixelScale == 1.0, "\(label) must not scale targets")
            #expect(plan.maxSourceTextureEdge == nil, "\(label) must not cap textures")
        }
    }

    @Test("Each rejection reports its own reason")
    func verdictsAreDistinguishable() {
        #expect(Self.plan(renderScale: 1.0).verdict == .settingOff)
        #expect(Self.plan(deviceSupports: false).verdict == .deviceUnsupported)
        // Rejected because the helper leaves `hdrOutputEnabled` false — an HDR scene IS
        // upscalable once display-HDR output is on (`WPEDisplayHDROutputTests`).
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
        let atLoad = Self.plan(canvas: Self.uhd, drawable: .zero)
        #expect(atLoad.verdict == .drawableUnknown)
        #expect(atLoad.renderPixelScale == 1.0)

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
        // `guard plan.isActive else { continue }` turns a broken contain path green.
        let contain = Self.plan(
            canvas: CGSize(width: 2560, height: 1440), drawable: Self.uhd, fitMode: .contain
        )
        #expect(contain.verdict == .active)
        #expect(contain.renderPixelScale == 0.75)
        #expect(Self.plan(fitMode: .stretch).verdict == .active)
    }

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

    // MARK: - The display clamp is independent of MetalFX

    @Test("An oversized canvas is clamped to the display even with MetalFX off")
    func oversizedCanvasClampsWithoutMetalFX() {
        let eightK = CGSize(width: 7680, height: 4320)
        let plan = Self.plan(canvas: eightK, drawable: Self.uhd, renderScale: 1.0)
        #expect(plan.isActive == false, "MetalFX is off; this is not an upscale")
        #expect(plan.displayFitScale == 0.5)
        #expect(plan.renderPixelScale == 0.5)
        let pixels = WPEMetalFXSpatialUpscaler.scaledCanvasSize(
            eightK, pixelScale: plan.renderPixelScale
        )
        #expect(pixels == Self.uhd)
    }

    @Test("Every MetalFX rejection still clamps an oversized canvas")
    func rejectionsStillClamp() {
        let eightK = CGSize(width: 7680, height: 4320)
        let cases: [(String, WPEMetalUpscalePlan)] = [
            ("settingOff", Self.plan(canvas: eightK, drawable: Self.uhd, renderScale: 1.0)),
            ("deviceUnsupported", Self.plan(canvas: eightK, drawable: Self.uhd, deviceSupports: false)),
            ("hdrScene", Self.plan(canvas: eightK, drawable: Self.uhd, isHDR: true)),
        ]
        for (label, plan) in cases {
            #expect(plan.isActive == false, "\(label) must not claim an active upscale")
            #expect(plan.renderPixelScale == 0.5, "\(label) must still clamp to the display")
        }
    }

    /// `.center` presents source pixels 1:1, so shrinking the source shrinks the picture.
    @Test("Center fit never clamps")
    func centerFitNeverClamps() {
        let plan = Self.plan(
            canvas: CGSize(width: 7680, height: 4320), drawable: Self.uhd, fitMode: .center
        )
        #expect(plan.displayFitScale == 1.0)
        #expect(plan.renderPixelScale == 1.0)
    }

    /// Cover crops, so the visible part is scaled by the LARGER axis ratio. Clamping on the
    /// smaller one would under-sample whatever survives the crop.
    @Test("Cover clamps on the axis that fills the drawable")
    func coverClampsOnTheFillingAxis() {
        // 16:9 canvas on a 16:10 drawable: height fills, width overflows and is cropped.
        let canvas = CGSize(width: 7680, height: 4320)
        let drawable = CGSize(width: 3840, height: 2400)
        let cover = Self.plan(canvas: canvas, drawable: drawable, fitMode: .cover, renderScale: 1.0)
        #expect(cover.displayFitScale == 2400.0 / 4320.0)
        // Contain letterboxes instead, so the smaller ratio is the honest one there.
        let contain = Self.plan(canvas: canvas, drawable: drawable, fitMode: .contain, renderScale: 1.0)
        #expect(contain.displayFitScale == 3840.0 / 7680.0)
    }

    @Test("A present-time decline falls back to the display clamp, not to native")
    func declineFallsBackToDisplayFit() {
        let eightK = CGSize(width: 7680, height: 4320)
        let declined = Self.plan(canvas: eightK, drawable: Self.uhd).demotedToNative()
        #expect(declined.verdict == .declinedAtPresent)
        #expect(declined.renderPixelScale == 0.5)
    }

    @Test("A canvas within the display is untouched")
    func canvasWithinDisplayIsUntouched() {
        for canvas in [Self.hd, Self.uhd, CGSize(width: 640, height: 360)] {
            let plan = Self.plan(canvas: canvas, drawable: Self.uhd, renderScale: 1.0)
            #expect(plan.displayFitScale == 1.0)
            #expect(plan.renderPixelScale == 1.0)
            #expect(plan.maxSourceTextureEdge == nil)
        }
    }

    @Test("A coprime drawable cannot scale under cover, but still can under stretch")
    func coprimeDrawableAspect() {
        // 1081 and 1920 are coprime: no reduced integer size keeps the ratio, so the
        // zero-tolerance cover gate must refuse. A real constraint, not a gap.
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
