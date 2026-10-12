public struct WPEEngineComboFlags: Sendable, Equatable {
    public var orthographicProjection = false
    public var fogDistance = false
    public var fogHeight = false
    public var backbufferMSAA = false
    public var hdr = false
    public var pointLights: Int32 = 0
    public var spotLights: Int32 = 0
    public var tubeLights: Int32 = 0
    public var directionalLights: Int32 = 0
    public var spotShadowCookieLights: Int32 = 0
    public var spotShadowLights: Int32 = 0
    public var spotCookieLights: Int32 = 0
    public var directionalShadowLights: Int32 = 0
    public var pointShadowLights: Int32 = 0
    public var shadowQuality: Int32 = 0
    /// TEXI format values, including textures loaded from sampler defaults.
    public var textureFormats: [Int32: Int32] = [:]

    public init() {}
}

public struct WPEPassJSONCombo: Sendable, Equatable {
    public var key: String
    public var value: Int32

    public init(key: String, value: Int32) {
        self.key = key
        self.value = value
    }
}

public struct WPEBoundComboTexture: Sendable, Equatable {
    public var flags: UInt32
    /// Nil uses the components in the sampler annotation.
    public var componentCombos: [String]?

    public init(flags: UInt32 = 0, componentCombos: [String]? = nil) {
        self.flags = flags
        self.componentCombos = componentCombos
    }
}
