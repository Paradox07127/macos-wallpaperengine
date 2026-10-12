/// Switches and raw uniform values for the tail of FUN_14017fa70.
public struct WPEParityPostProcessConfig: Sendable {
    public var sceneBloomEnabled: Bool
    public var userBloomEnabled: Bool
    public var objectTableNonEmpty: Bool
    public var hdrEnabled: Bool
    /// Postprocessing "displayhdr" (Main+0x128 bit14): the HDR bloom combine uses `combine_dhdr_upsample.json`.
    public var displayHDREnabled: Bool
    /// One disables MSAA; otherwise this is the scene target's sample count.
    public var msaaSampleCount: Int
    public var sceneMipMappedFrameBufferEnabled: Bool
    public var qualityMipMappedFrameBufferEnabled: Bool
    public var bloomSettings: WPEParityBloomSettings
    public var colorCorrectionEnabled: Bool
    public var fadeActive: Bool
    public var backbufferWidth: Int
    public var backbufferHeight: Int
    public var backbufferFormat: String

    public init(sceneBloomEnabled: Bool = false, userBloomEnabled: Bool = false,
                objectTableNonEmpty: Bool = false, hdrEnabled: Bool = false, displayHDREnabled: Bool = false,
                msaaSampleCount: Int = 1,
                sceneMipMappedFrameBufferEnabled: Bool = false, qualityMipMappedFrameBufferEnabled: Bool = false,
                bloomSettings: WPEParityBloomSettings = WPEParityBloomSettings(), colorCorrectionEnabled: Bool = false,
                fadeActive: Bool = false, backbufferWidth: Int, backbufferHeight: Int,
                backbufferFormat: String = "rgba8unorm") {
        self.sceneBloomEnabled = sceneBloomEnabled
        self.userBloomEnabled = userBloomEnabled
        self.objectTableNonEmpty = objectTableNonEmpty
        self.hdrEnabled = hdrEnabled
        self.displayHDREnabled = displayHDREnabled
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

    public var mipMappedFrameBufferRequested: Bool {
        sceneMipMappedFrameBufferEnabled && qualityMipMappedFrameBufferEnabled
    }

    /// HDR pyramid depth N: the iterations, clamped to the halvings of min(W, H) that stay ≥ 1, at most 8
    /// (14017f1b0.c:126-210, 340-355).
    public var hdrBloomLevelCount: Int {
        var size = min(backbufferWidth, backbufferHeight)
        var halvings = 0
        while halvings < 8, size / 2 >= 1 {
            size /= 2
            halvings += 1
        }
        return max(1, min(bloomSettings.hdrIterations, halvings))
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
