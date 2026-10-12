import simd

/// g_ParallaxPosition (1401891a0.c:279-356). The smoothed value lives in ortho pixels.
public struct WPEParityUniformParallax: Sendable {
    public private(set) var smoothed: SIMD2<Float> = .zero
    public private(set) var position: SIMD2<Float> = .zero

    public init() {}

    /// `pointer` is g_PointerPosition (y down); WPE clamps it to [0, 1] and flips y.
    public mutating func advance(pointer: SIMD2<Float>, mouseInfluence: Float, delay: Float,
                                 eye: SIMD2<Float>, ortho: SIMD2<Float>, frametime: Float) {
        let input = SIMD2(pointer.x, 1 - pointer.y).clamped(lowerBound: .zero, upperBound: .one)
        let target = ortho * (0.5 * (1 - mouseInfluence) + input * mouseInfluence) + eye
        if delay > 0 {
            let factor = min(1, (1 - delay / 3) * 10 * frametime)
            smoothed += (target - smoothed) * factor
        } else {
            smoothed = target
        }
        position = (smoothed / ortho).clamped(lowerBound: .zero, upperBound: .one)
    }

    /// 2D g_EyePosition (1401891a0.c:391-397).
    public static func eyePosition2D(eye: SIMD2<Float>, ortho: SIMD2<Float>) -> SIMD3<Float> {
        SIMD3(eye + ortho * 0.5, 2000)
    }

    /// g_ViewForward/Right/Up from the view matrix rows (14017fa70.c:391-472).
    public static func viewVectors(view: simd_float4x4) -> (forward: SIMD3<Float>, right: SIMD3<Float>,
                                                            up: SIMD3<Float>) {
        let rows = view.transpose
        func xyz(_ row: SIMD4<Float>) -> SIMD3<Float> {
            SIMD3(row.x, row.y, row.z)
        }
        return (-xyz(rows.columns.2), xyz(rows.columns.0), xyz(rows.columns.1))
    }
}
