import CoreGraphics
@testable import LiveWallpaper
import Metal
import QuartzCore
import Testing

/// True display-HDR output (WPE's "Ultra (Display HDR)" counterpart). The switch is a
/// kill switch defaulting to OFF, so the guard that matters most is that OFF reproduces
/// the previous 8-bit sRGB present path exactly.
@Suite("WPE display HDR output")
struct WPEDisplayHDROutputTests {
    @Test("off keeps the 8-bit sRGB drawable the pre-feature path used")
    func offKeepsLegacyFormat() {
        #expect(
            WPEDisplayHDROutput.drawablePixelFormat(hdrOutputEnabled: false)
                == WPEMetalRenderExecutor.outputPixelFormat
        )
        // Pin the literal too: outputPixelFormat changing silently would make the
        // equality above pass while the present path stopped being 8-bit sRGB.
        #expect(WPEDisplayHDROutput.drawablePixelFormat(hdrOutputEnabled: false) == .rgba8Unorm_srgb)
    }

    @Test("on widens the drawable to rgba16Float so >1 survives present")
    func onWidensDrawable() {
        #expect(WPEDisplayHDROutput.drawablePixelFormat(hdrOutputEnabled: true) == .rgba16Float)
    }

    /// The upscale plan must ask the DRAWABLE whether output is HDR, not the defaults key.
    /// The two can disagree: the surface refuses HDR output when no attached screen can show
    /// EDR, and a plan that still believed the key would call an HDR scene float-to-float,
    /// render it small for MetalFX, then have the scaler refuse the 8-bit drawable at present
    /// and demote the scene to native for the rest of its life.
    @Test("HDR output is read back from the drawable format, not from the defaults key")
    func hdrOutputIsReadFromTheDrawable() {
        #expect(WPEDisplayHDROutput.isHDROutput(drawablePixelFormat: .rgba16Float))
        #expect(WPEDisplayHDROutput.isHDROutput(drawablePixelFormat: .rgba8Unorm_srgb) == false)
        #expect(WPEDisplayHDROutput.isHDROutput(drawablePixelFormat: .bgra8Unorm) == false)
        // Round-trips with the formatter the surface actually builds the drawable from.
        for enabled in [true, false] {
            #expect(WPEDisplayHDROutput.isHDROutput(
                drawablePixelFormat: WPEDisplayHDROutput.drawablePixelFormat(hdrOutputEnabled: enabled)
            ) == enabled)
        }
    }

    /// The defaults key alone is not enough to widen the drawable: an all-SDR setup pays the
    /// wider drawable for output it cannot show. WPE gates its own "Ultra (Display HDR)"
    /// option the same way.
    @Test("The drawable request needs both the setting and a capable screen")
    func requestNeedsSettingAndCapableScreen() {
        #expect(WPEDisplayHDROutput.shouldRequestHDROutput(settingEnabled: true, hasCapableScreen: true))
        #expect(WPEDisplayHDROutput.shouldRequestHDROutput(settingEnabled: true, hasCapableScreen: false) == false)
        #expect(WPEDisplayHDROutput.shouldRequestHDROutput(settingEnabled: false, hasCapableScreen: true) == false)
        #expect(WPEDisplayHDROutput.shouldRequestHDROutput(settingEnabled: false, hasCapableScreen: false) == false)
    }

    @Test("off leaves the layer's colorspace and EDR request untouched")
    func offLeavesLayerAlone() {
        let layer = CAMetalLayer()
        layer.colorspace = nil
        layer.wantsExtendedDynamicRangeContent = false

        WPEDisplayHDROutput.apply(to: layer, hdrOutputEnabled: false)

        #expect(layer.colorspace == nil)
        #expect(layer.wantsExtendedDynamicRangeContent == false)
    }

    /// EDR needs all three together: a float format, an extended-range colorspace, and the
    /// request itself. The probe's negative-control row (EDR request off, same float layer)
    /// showed 4.0 and 1.0 rendering identically, so the request is not optional decoration.
    @Test("on sets the extended-linear colorspace and requests EDR")
    func onRequestsEDR() {
        let layer = CAMetalLayer()
        layer.colorspace = nil
        layer.wantsExtendedDynamicRangeContent = false

        WPEDisplayHDROutput.apply(to: layer, hdrOutputEnabled: true)

        #expect(layer.wantsExtendedDynamicRangeContent == true)
        #expect(layer.colorspace?.name == CGColorSpace.extendedLinearDisplayP3)
    }

    /// The four pairings the present path can produce. Only float→8-bit is refused: the
    /// scaler does not tone map, so values past 1 would have nowhere to go.
    @Test("MetalFX accepts every format pairing except a float source into an 8-bit drawable")
    func metalFXFormatMatrix() {
        #expect(WPEMetalFXSpatialUpscaler.formatRejection(
            sourceFormat: .rgba8Unorm_srgb, drawableFormat: .rgba8Unorm_srgb
        ) == nil)
        // HDR scene + display-HDR output: the pairing this feature adds.
        #expect(WPEMetalFXSpatialUpscaler.formatRejection(
            sourceFormat: .rgba16Float, drawableFormat: .rgba16Float
        ) == nil)
        // SDR scene while display-HDR output is on — the scene RT stays 8-bit.
        #expect(WPEMetalFXSpatialUpscaler.formatRejection(
            sourceFormat: .rgba8Unorm_srgb, drawableFormat: .rgba16Float
        ) == nil)
        // HDR scene with display-HDR output off: >1 cannot survive an 8-bit drawable.
        #expect(WPEMetalFXSpatialUpscaler.formatRejection(
            sourceFormat: .rgba16Float, drawableFormat: .rgba8Unorm_srgb
        ) == .hdrInput)
    }

    /// The mode must follow the SOURCE encoding: `.perceptual` reads 8-bit sRGB-ish input,
    /// `.hdr` reads linear float past 1. Feeding float through `.perceptual` was what made
    /// HDR scenes ineligible for upscaling before.
    @Test("MetalFX picks the colour-processing mode from the source format")
    func metalFXColorProcessingMode() {
        #expect(WPEMetalFXSpatialUpscaler.colorProcessingMode(sourceFormat: .rgba8Unorm_srgb) == .perceptual)
        #expect(WPEMetalFXSpatialUpscaler.colorProcessingMode(sourceFormat: .bgra8Unorm) == .perceptual)
        #expect(WPEMetalFXSpatialUpscaler.colorProcessingMode(sourceFormat: .rgba16Float) == .hdr)
        #expect(WPEMetalFXSpatialUpscaler.colorProcessingMode(sourceFormat: .r8Unorm) == nil)
    }

    /// Load-time gate. An HDR scene is only upscalable when the drawable is float too, so
    /// the verdict has to consult the HDR-output switch rather than the scene flag alone.
    @Test("An HDR scene is upscalable only while display-HDR output is on")
    func upscalePlanFollowsHDROutput() {
        func plan(isHDR: Bool, hdrOutputEnabled: Bool) -> WPEMetalUpscalePlan {
            WPEMetalUpscalePlan.make(
                worldCanvas: CGSize(width: 1920, height: 1080),
                drawableSize: CGSize(width: 3840, height: 2160),
                fitMode: .cover,
                isHDR: isHDR,
                hdrOutputEnabled: hdrOutputEnabled,
                renderScale: 0.75,
                deviceSupportsScaler: true
            )
        }
        #expect(plan(isHDR: true, hdrOutputEnabled: false).verdict == .hdrScene)
        #expect(plan(isHDR: true, hdrOutputEnabled: true).verdict == .active)
        // The switch must not disturb SDR scenes either way.
        #expect(plan(isHDR: false, hdrOutputEnabled: false).verdict == .active)
        #expect(plan(isHDR: false, hdrOutputEnabled: true).verdict == .active)
    }
}
