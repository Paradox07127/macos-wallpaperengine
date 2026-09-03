import Foundation

/// Parent/child composition of a WPE object transform (origin, scale, XYZ Euler angles).
public enum WPEEulerTransform {
    public static func combine(
        origin: SIMD3<Double>,
        scale: SIMD3<Double>,
        angles: SIMD3<Double>,
        childOrigin: SIMD3<Double>,
        childScale: SIMD3<Double>,
        childAngles: SIMD3<Double>
    ) -> (origin: SIMD3<Double>, scale: SIMD3<Double>, angles: SIMD3<Double>) {
        let scaled = SIMD3<Double>(
            childOrigin.x * scale.x,
            childOrigin.y * scale.y,
            childOrigin.z * scale.z
        )
        let rotated = rotate(scaled, by: angles)

        return (
            origin: SIMD3<Double>(
                origin.x + rotated.x,
                origin.y + rotated.y,
                origin.z + rotated.z
            ),
            scale: SIMD3<Double>(
                scale.x * childScale.x,
                scale.y * childScale.y,
                scale.z * childScale.z
            ),
            angles: angles + childAngles
        )
    }

    public static func rotate(_ value: SIMD3<Double>, by angles: SIMD3<Double>) -> SIMD3<Double> {
        var result = value

        if angles.x != 0 {
            let c = cos(angles.x)
            let s = sin(angles.x)
            result = SIMD3<Double>(
                result.x,
                result.y * c - result.z * s,
                result.y * s + result.z * c
            )
        }
        if angles.y != 0 {
            let c = cos(angles.y)
            let s = sin(angles.y)
            result = SIMD3<Double>(
                result.x * c + result.z * s,
                result.y,
                -result.x * s + result.z * c
            )
        }
        if angles.z != 0 {
            let c = cos(angles.z)
            let s = sin(angles.z)
            result = SIMD3<Double>(
                result.x * c - result.y * s,
                result.x * s + result.y * c,
                result.z
            )
        }

        return result
    }
}
