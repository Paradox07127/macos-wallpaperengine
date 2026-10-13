import simd

/// g_LightAmbientColor / g_LightSkylightColor (codes 0x60 / 0x61, 1400d8300.c:781-792): general `ambientcolor` and
/// `skylightcolor` copied raw into the render context at load (140186c90.c:682-686).
public struct WPEParityUniformLights: Sendable, Equatable {
    public var ambient: SIMD3<Float>
    public var skylight: SIMD3<Float>

    public init(ambient: SIMD3<Float>, skylight: SIMD3<Float>) {
        self.ambient = ambient
        self.skylight = skylight
    }

    public init(document: WPESceneDocument) {
        self.init(ambient: SIMD3<Float>(document.general.lightAmbientColor),
                  skylight: SIMD3<Float>(document.general.lightSkylightColor))
    }

    public var values: [String: WPECBufferValue] {
        [
            "g_LightAmbientColor": .vector([ambient.x, ambient.y, ambient.z]),
            "g_LightSkylightColor": .vector([skylight.x, skylight.y, skylight.z]),
        ]
    }
}
