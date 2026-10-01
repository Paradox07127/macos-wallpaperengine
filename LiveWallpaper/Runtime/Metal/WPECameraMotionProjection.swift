#if !LITE_BUILD
import Foundation
import LiveWallpaperProWPE
import simd

/// Angles are radians composed as inverse(Rz * Ry * Rx); canvas XY is Y-up and the third lane carries world Z.
enum WPECameraMotionProjection {
    static func viewRotation(_ angles: SIMD3<Double>) -> simd_double4x4 {
        WPEMetalObjectUniforms.modelMatrix(origin: .zero, scale: SIMD3(repeating: 1), angles: angles).transpose
    }

    static func canvasMatrix(motion: WPESceneCameraMotionSample, size: CGSize) -> simd_double4x4 {
        let half = SIMD2(max(size.width, 1) * 0.5, max(size.height, 1) * 0.5)
        var world = simd_double4x4(diagonal: SIMD4(half.x, half.y, 1, 1))
        world.columns.3 = SIMD4(half.x - motion.origin.x, half.y - motion.origin.y, -motion.origin.z, 1)
        let normalize = simd_double4x4(diagonal: SIMD4(motion.zoom / half.x, motion.zoom / half.y, 1, 1))
        var offset = matrix_identity_double4x4
        offset.columns.3 = SIMD4(-motion.zoom, -motion.zoom, 0, 1)
        return offset * normalize * viewRotation(motion.angles) * world
    }

    /// Shader world is raw Y-up canvas space, unlike native mesh paths with a Y-down ABI.
    static func shaderViewProjection(motion: WPESceneCameraMotionSample, size: CGSize) -> simd_double4x4 {
        let half = SIMD2(max(size.width, 1) * 0.5, max(size.height, 1) * 0.5)
        var rawWorldToCanvas = simd_double4x4(diagonal: SIMD4(1 / half.x, 1 / half.y, 1, 1))
        rawWorldToCanvas.columns.3 = SIMD4(-1, -1, 0, 1)
        var matrix = canvasMatrix(motion: motion, size: size) * rawWorldToCanvas
        for column in 0 ..< 4 {
            matrix[column][2] *= 0.00025
        }
        matrix.columns.3.z += 0.5
        return matrix
    }

    /// Existing native paths already applied origin/zoom. This composes only
    /// their missing orientation and Z contribution, preserving the zero-angle ABI.
    static func correction(motion: WPESceneCameraMotionSample, size: CGSize) -> simd_float4x4 {
        guard motion.angles != .zero else { return matrix_identity_float4x4 }
        let legacy = canvasMatrix(motion: .init(origin: SIMD3(motion.origin.x, motion.origin.y, 0), zoom: motion.zoom), size: size)
        let matrix = canvasMatrix(motion: motion, size: size) * legacy.inverse
        return simd_float4x4(SIMD4<Float>(matrix.columns.0), SIMD4<Float>(matrix.columns.1),
                             SIMD4<Float>(matrix.columns.2), SIMD4<Float>(matrix.columns.3))
    }

    /// Unprojects at clip depth zero (world z = -2000 under .00025*z + .5), not at the world z=0 plane, then reports Z=0.
    static func cursor(pointer: SIMD2<Double>, size: SIMD2<Double>, motion: WPESceneCameraMotionSample) -> SIMD3<Double>? {
        let target = size * 0.5 + (SIMD2(pointer.x * size.x, (1 - pointer.y) * size.y) - size * 0.5) / motion.zoom
        let point = viewRotation(motion.angles).transpose * SIMD4(target.x, target.y, -2000, 0)
            + SIMD4(motion.origin, 0)
        return point.x.isFinite && point.y.isFinite ? SIMD3(point.x, point.y, 0) : nil
    }

    /// Sprite GS uses the normalized projected model UP axis and its planar
    /// perpendicular, rather than shearing both quad axes.
    static func spriteRotation(modelAngle: Float, cameraAngles: SIMD3<Double>) -> SIMD2<Float> {
        guard cameraAngles != .zero else { return SIMD2(cos(modelAngle), sin(modelAngle)) }
        let up = viewRotation(cameraAngles) * SIMD4(-sin(Double(modelAngle)), cos(Double(modelAngle)), 0, 0)
        let length = hypot(up.x, up.y)
        guard length > 1e-10 else { return SIMD2(cos(modelAngle), sin(modelAngle)) }
        return SIMD2(Float(up.y / length), Float(-up.x / length))
    }
}
#endif
