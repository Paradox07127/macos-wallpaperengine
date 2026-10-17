import Foundation

/// Switches and raw uniform values for the tail of FUN_14017fa70.
public struct WPEParityPostProcessConfig: Sendable {
    public var sceneBloomEnabled: Bool
    public var userBloomEnabled: Bool
    public var objectTableNonEmpty: Bool
    public var hdrEnabled: Bool
    /// Postprocessing "displayhdr" (Main+0x128 bit14): the HDR bloom combine uses `combine_dhdr_upsample.json`.
    public var displayHDREnabled: Bool
    /// The target screen's maximum potential EDR value, in reference-white units (1 = SDR white).
    public var maximumPotentialEDR: Float
    /// One disables MSAA; otherwise this is the scene target's sample count.
    public var msaaSampleCount: Int
    /// A prepared material's actual active slot requests the resource, independently of quality.
    public var sceneMipMappedFrameBufferEnabled: Bool
    /// Main+0x128 bit7: native general.reflection, normalised to true when absent or not a JSON bool.
    public var qualityMipMappedFrameBufferEnabled: Bool
    public var bloomSettings: WPEParityBloomSettings
    /// ccsimple.json is loaded (`WPEParityColorCorrection.drawn`); `colorCorrection` gives its combos and values.
    public var colorCorrectionEnabled: Bool
    public var colorCorrection = WPEParityColorCorrection()
    /// See `WPEParitySceneDescription.offscreenScaleTier`; post shrinks only the HDR bloom's first level, from 2.
    public var offscreenScaleTier = 0
    /// fade.json is loaded: camerafade on and camera paths present. The draw runs only on frames whose
    /// `WPEParityCameraPaths.fadeAlpha` is above 0.
    public var fadeActive: Bool
    public var backbufferWidth: Int
    public var backbufferHeight: Int
    public var backbufferFormat: String

    public init(sceneBloomEnabled: Bool = false, userBloomEnabled: Bool = false,
                objectTableNonEmpty: Bool = false, hdrEnabled: Bool = false, displayHDREnabled: Bool = false,
                maximumPotentialEDR: Float = 1, msaaSampleCount: Int = 1,
                sceneMipMappedFrameBufferEnabled: Bool = false, qualityMipMappedFrameBufferEnabled: Bool = false,
                bloomSettings: WPEParityBloomSettings = WPEParityBloomSettings(), colorCorrectionEnabled: Bool = false,
                fadeActive: Bool = false, backbufferWidth: Int, backbufferHeight: Int,
                backbufferFormat: String = "rgba8unorm") {
        self.sceneBloomEnabled = sceneBloomEnabled
        self.userBloomEnabled = userBloomEnabled
        self.objectTableNonEmpty = objectTableNonEmpty
        self.hdrEnabled = hdrEnabled
        self.displayHDREnabled = displayHDREnabled
        self.maximumPotentialEDR = maximumPotentialEDR
        self.msaaSampleCount = msaaSampleCount
        self.sceneMipMappedFrameBufferEnabled = sceneMipMappedFrameBufferEnabled
        self.qualityMipMappedFrameBufferEnabled = qualityMipMappedFrameBufferEnabled
        self.bloomSettings = bloomSettings
        self.colorCorrectionEnabled = colorCorrectionEnabled
        self.fadeActive = fadeActive
        self.backbufferWidth = backbufferWidth
        self.backbufferHeight = backbufferHeight
        self.backbufferFormat = backbufferFormat
    }

    public var bloomEnabled: Bool {
        sceneBloomEnabled && userBloomEnabled && objectTableNonEmpty
    }

    /// 14017fa70:699–701/713–715: a requested resource is updated only with Main+0x128 bit7.
    public var mipMappedFrameBufferRefreshEnabled: Bool {
        sceneMipMappedFrameBufferEnabled && qualityMipMappedFrameBufferEnabled
    }

    /// Main prepares dimension-available capacity before selecting the active iteration count (17f1b0:126–210).
    public var hdrBloomCapacity: Int {
        var size = min(backbufferWidth, backbufferHeight)
        var halvings = 0
        while halvings < 8, size / 2 >= 1 {
            size /= 2
            halvings += 1
        }
        return max(1, halvings)
    }

    /// The raw signed field stays unchanged; only active N is clamped (17f1b0:340–355,184020).
    public var hdrBloomLevelCount: Int {
        max(1, min(bloomSettings.hdrIterations, hdrBloomCapacity))
    }
}

/// Scene `general` bloom values, initialised to WPE's defaults (140186c90.c:215-241).
public struct WPEParityBloomSettings: Hashable, Sendable {
    public var strength: Float = 2
    public var threshold: Float = 0.65
    public var hdrStrength: Float = 2
    public var hdrThreshold: Float = 1
    public var hdrFeather: Float = 0.1
    public var hdrScatter: Float = 1.619
    public var hdrIterations = 8
    public var tint = SIMD3<Float>(1, 1, 1)

    public init() {}
}

/// WPE's per-wallpaper colour-correction user settings as it stores them (140181f30.c:196-248), with the defaults
/// of 14012b890.c:28-40.
public struct WPEParityColorCorrection: Hashable, Sendable {
    /// `wec_e`
    public var enabled = false
    /// `wec_con` ÷ 50
    public var contrast: Float = 1
    /// `wec_brs` ÷ 50
    public var brightness: Float = 1
    /// `wec_sa` ÷ 50
    public var saturation: Float = 1
    /// `wec_hue` ÷ 100 − 0.5
    public var hue: Float = 0
    /// `wcc_v`, the LUT file under `lut/`.
    public var lut = ""
    /// `wcc_amt` ÷ 100
    public var lutAmount: Float = 1

    public init() {}

    /// Raw setting values; nil keeps the default.
    public init(wecE: Bool? = nil, wecCon: Double? = nil, wecBrs: Double? = nil, wecSa: Double? = nil,
                wecHue: Double? = nil, wccV: String? = nil, wccAmt: Double? = nil) {
        enabled = wecE ?? enabled
        contrast = wecCon.map { Float($0) / 50 } ?? contrast
        brightness = wecBrs.map { Float($0) / 50 } ?? brightness
        saturation = wecSa.map { Float($0) / 50 } ?? saturation
        hue = wecHue.map { Float($0) / 100 - 0.5 } ?? hue
        lut = wccV ?? lut
        lutAmount = wccAmt.map { Float($0) / 100 } ?? lutAmount
    }

    /// Combo COL: `wec_e` with any value off neutral.
    public var adjustsColor: Bool {
        enabled && !(contrast == 1 && brightness == 1 && saturation == 1 && hue == 0)
    }

    /// Combo LUT.
    public var appliesLUT: Bool {
        !lut.isEmpty && lutAmount > 0
    }

    /// 14017fa70.c:737: ccsimple is drawn only when either combo is on.
    public var drawn: Bool {
        adjustsColor || appliesLUT
    }

    /// g_Params (140181f30.c:409-413), written only with COL.
    public var params: [Float] {
        [pow(brightness, 2), pow(contrast, 0.5), pow(saturation, 0.5), hue]
    }
}
