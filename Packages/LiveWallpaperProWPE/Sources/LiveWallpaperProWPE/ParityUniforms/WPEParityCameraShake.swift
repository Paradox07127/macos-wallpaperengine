import Foundation
import simd

/// `general.camerashake` (fields 140199780.c:1442-1550, defaults 140186c90.c:203-205).
public struct WPEParityCameraShake: Sendable, Equatable {
    public var speed: Float
    public var amplitude: Float
    public var roughness: Float
    /// SceneObject+0xe0 bit 3: the shake stays in the canvas plane and scales with the ortho height.
    public var orthographic: Bool

    public init(speed: Float = 3, amplitude: Float = 0.5, roughness: Float = 1, orthographic: Bool = true) {
        self.speed = speed
        self.amplitude = amplitude
        self.roughness = roughness
        self.orthographic = orthographic
    }

    /// Native constructor defaults survive invalid authored values, even while shake is disabled.
    public init(general: WPESceneJSONValue, orthographic: Bool = true) {
        self.init(speed: WPEParityScriptProperty.sceneFloatValue(fromJSON: general["camerashakespeed"]) ?? 3,
                  amplitude: WPEParityScriptProperty.sceneFloatValue(fromJSON: general["camerashakeamplitude"]) ?? 0.5,
                  roughness: WPEParityScriptProperty.sceneFloatValue(fromJSON: general["camerashakeroughness"]) ?? 1,
                  orthographic: orthographic)
    }

    /// FUN_140199580: one Lissajous offset added to both eye and center at g_Time `time`.
    public func shaken(eye: SIMD3<Float>, center: SIMD3<Float>, time: Float, orthoHeight: Float)
        -> (eye: SIMD3<Float>, center: SIMD3<Float>) {
        let t = speed * speed * time
        var direction = SIMD3(cos(t), sin(1.333 * t), sin(t))
        let amplitudeScale = amplitude * 0.1
        // The ortho flattening comes before the roughness remap, so |v| is the in-plane length.
        if orthographic {
            direction.z = 0
        }
        let scale = orthographic ? (orthoHeight * 0.1) * amplitudeScale : amplitudeScale
        let exponent = pow(roughness, 3)
        if exponent > 0.001, exponent != 1 {
            let length = sqrt(direction.x * direction.x + direction.y * direction.y + direction.z * direction.z)
            let inverseLength: Float = 1 / length
            let remapped = pow(length, exponent)
            direction = (inverseLength * direction) * remapped
        }
        let offset = scale * direction
        return (eye + offset, center + offset)
    }
}
