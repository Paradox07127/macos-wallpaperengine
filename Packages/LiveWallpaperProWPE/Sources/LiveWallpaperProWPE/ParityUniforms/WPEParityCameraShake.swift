import Foundation
import simd

/// `general.camerashake` (fields 140199780.c:1442-1550, defaults 140186c90.c:203-205).
public struct WPEParityCameraShake: Sendable, Equatable {
    public var speed: Float
    public var amplitude: Float
    public var roughness: Float
    /// general+0xe0 bit 3: the shake stays in the canvas plane and scales with the ortho height.
    public var orthographic: Bool

    public init(speed: Float = 3, amplitude: Float = 0.5, roughness: Float = 1, orthographic: Bool = true) {
        self.speed = speed
        self.amplitude = amplitude
        self.roughness = roughness
        self.orthographic = orthographic
    }

    /// Nil when the scene leaves camerashake off.
    public init?(general: WPESceneGeneral) {
        let settings = general.cameraShake
        guard settings.enabled.resolvedValue else { return nil }
        func value(_ field: WPESceneAuthoredField<Double>, _ absent: Float) -> Float {
            field.isAuthored ? Float(field.resolvedValue) : absent
        }
        self.init(speed: value(settings.speed, 3), amplitude: value(settings.amplitude, 0.5),
                  roughness: value(settings.roughness, 1), orthographic: !general.usesPerspectiveProjection)
    }

    /// FUN_140199580: one Lissajous offset added to both eye and center at g_Time `time`.
    public func shaken(eye: SIMD3<Float>, center: SIMD3<Float>, time: Float, orthoHeight: Float)
        -> (eye: SIMD3<Float>, center: SIMD3<Float>) {
        let t = speed * speed * time
        var direction = SIMD3(cos(t), sin(1.333 * t), sin(t))
        var scale = amplitude * 0.1
        // The ortho flattening comes before the roughness remap, so |v| is the in-plane length.
        if orthographic {
            direction.z = 0
            scale *= orthoHeight * 0.1
        }
        let exponent = roughness * roughness * roughness
        if exponent > 0.001, exponent != 1 {
            let length = simd_length(direction)
            direction *= pow(length, exponent) / length
        }
        let offset = scale * direction
        return (eye + offset, center + offset)
    }
}
