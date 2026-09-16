import CoreGraphics
@testable import LiveWallpaper
import Metal
import QuartzCore
import Testing

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

    /// HDR-ness must be read from the DRAWABLE, not the defaults key: the surface
    /// refuses HDR output when no attached screen can show EDR.
    @Test("HDR output is read back from the drawable format, not from the defaults key")
    func hdrOutputIsReadFromTheDrawable() {
        #expect(WPEDisplayHDROutput.isHDROutput(drawablePixelFormat: .rgba16Float))
        #expect(WPEDisplayHDROutput.isHDROutput(drawablePixelFormat: .rgba8Unorm_srgb) == false)
        #expect(WPEDisplayHDROutput.isHDROutput(drawablePixelFormat: .bgra8Unorm) == false)
        for enabled in [true, false] {
            #expect(WPEDisplayHDROutput.isHDROutput(
                drawablePixelFormat: WPEDisplayHDROutput.drawablePixelFormat(hdrOutputEnabled: enabled)
            ) == enabled)
        }
    }

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

    /// EDR needs all three: a float format, an extended-range colorspace, and the
    /// request itself - the request is not optional decoration.
    /// The tag must name the scene's working space: sRGB textures decode to linear sRGB and no
    /// pass converts primaries, so a Display P3 tag would reinterpret every saturated colour.
    @Test("on tags the drawable extended-linear sRGB and requests EDR")
    func onRequestsEDR() {
        let layer = CAMetalLayer()
        layer.colorspace = nil
        layer.wantsExtendedDynamicRangeContent = false

        WPEDisplayHDROutput.apply(to: layer, hdrOutputEnabled: true)

        #expect(layer.wantsExtendedDynamicRangeContent == true)
        #expect(layer.colorspace?.name == CGColorSpace.extendedLinearSRGB)
        #expect(layer.colorspace?.name != CGColorSpace.extendedLinearDisplayP3)
    }

    /// The four pairings the present path can produce. Only float→8-bit is refused: the
    /// scaler does not tone map, so values past 1 would have nowhere to go.
    @Test("MetalFX accepts every format pairing except a float source into an 8-bit drawable")
    func metalFXFormatMatrix() {
        #expect(WPEMetalFXSpatialUpscaler.formatRejection(
            sourceFormat: .rgba8Unorm_srgb, drawableFormat: .rgba8Unorm_srgb
        ) == nil)
        #expect(WPEMetalFXSpatialUpscaler.formatRejection(
            sourceFormat: .rgba16Float, drawableFormat: .rgba16Float
        ) == nil)
        #expect(WPEMetalFXSpatialUpscaler.formatRejection(
            sourceFormat: .rgba8Unorm_srgb, drawableFormat: .rgba16Float
        ) == nil)
        #expect(WPEMetalFXSpatialUpscaler.formatRejection(
            sourceFormat: .rgba16Float, drawableFormat: .rgba8Unorm_srgb
        ) == .hdrInput)
    }

    /// The mode follows the SOURCE encoding: `.perceptual` for 8-bit sRGB-ish
    /// input, `.hdr` for linear float past 1.
    @Test("MetalFX picks the colour-processing mode from the source format")
    func metalFXColorProcessingMode() {
        #expect(WPEMetalFXSpatialUpscaler.colorProcessingMode(sourceFormat: .rgba8Unorm_srgb) == .perceptual)
        #expect(WPEMetalFXSpatialUpscaler.colorProcessingMode(sourceFormat: .bgra8Unorm) == .perceptual)
        #expect(WPEMetalFXSpatialUpscaler.colorProcessingMode(sourceFormat: .rgba16Float) == .hdr)
        #expect(WPEMetalFXSpatialUpscaler.colorProcessingMode(sourceFormat: .r8Unorm) == nil)
    }

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
        #expect(plan(isHDR: false, hdrOutputEnabled: false).verdict == .active)
        #expect(plan(isHDR: false, hdrOutputEnabled: true).verdict == .active)
    }
}
