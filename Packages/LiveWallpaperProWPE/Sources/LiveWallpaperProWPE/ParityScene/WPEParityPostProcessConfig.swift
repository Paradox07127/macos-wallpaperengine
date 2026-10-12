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
    /// Shader uniform names and values are passed through without normalization.
    public var bloomParameters: [String: SIMD4<Float>]
    public var colorCorrectionEnabled: Bool
    public var fadeActive: Bool
    public var backbufferWidth: Int
    public var backbufferHeight: Int
    public var backbufferFormat: String

    public init(sceneBloomEnabled: Bool = false, userBloomEnabled: Bool = false,
                objectTableNonEmpty: Bool = false, hdrEnabled: Bool = false, displayHDREnabled: Bool = false,
                msaaSampleCount: Int = 1,
                sceneMipMappedFrameBufferEnabled: Bool = false, qualityMipMappedFrameBufferEnabled: Bool = false,
                bloomParameters: [String: SIMD4<Float>] = [:], colorCorrectionEnabled: Bool = false,
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
        self.bloomParameters = bloomParameters
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
}
