#if !LITE_BUILD
import CoreGraphics
import Foundation
import simd

/// A composelayer drawn through the 2D-scene perspective camera: captured from the scene with its own MVP and drawn back with the same MVP, keeping w.
struct WPEProjectedComposeQuad {
    /// Corners whose clip w is at most this fraction of the eye distance count as at/behind the eye.
    static let minimumDepthFraction = 1e-3

    /// Clip (x, y, w), y-up NDC, in `wpe_object_quad_vertex` strip order: BL(0,1), BR(1,1), TL(0,0), TR(1,0).
    let clipCorners: [SIMD3<Double>]
    /// Layer uv (v down) → (U·w, V·w, w), where (U, V) is the top-left scene texture uv.
    let captureHomography: simd_double3x3
    let inverseCaptureHomography: simd_double3x3
    let sceneSize: CGSize

    /// `angles` in radians, `fovDegrees` is `perspectiveoverridefov`; `parallaxOffset` is a world-space translation applied after the model matrix.
    init?(
        origin: SIMD3<Double>,
        scale: SIMD3<Double>,
        angles: SIMD3<Double>,
        size: CGSize,
        sceneSize: CGSize,
        fovDegrees: Double,
        parallaxOffset: SIMD2<Double> = .zero
    ) {
        guard fovDegrees > 0 else { return nil }
        let columns = WPEMetalCameraUniforms.objectPerspectiveViewProjectionMatrix(
            width: sceneSize.width, height: sceneSize.height, fovDegrees: fovDegrees
        )
        guard let viewProjection = WPEMetalObjectUniforms.matrix4x4(fromColumnMajor: columns) else { return nil }
        let model = WPEMetalObjectUniforms.modelMatrix(
            origin: origin + SIMD3(parallaxOffset.x, parallaxOffset.y, 0), scale: scale, angles: angles
        )
        let width = Double(size.width), height = Double(size.height)
        // (u, v, 1) → layer point (w·(u−½), h·(½−v), 0, 1).
        let layerPoint = simd_double3x4(rows: [
            SIMD3(width, 0, -width / 2),
            SIMD3(0, -height, height / 2),
            SIMD3(0, 0, 0),
            SIMD3(0, 0, 1),
        ])
        let clip = viewProjection * model * layerPoint
        let clipX = clip.transpose.columns.0, clipY = clip.transpose.columns.1, clipW = clip.transpose.columns.3
        let corners = [SIMD2<Double>(0, 1), SIMD2(1, 1), SIMD2(0, 0), SIMD2(1, 0)].map { uv in
            let point = SIMD3(uv.x, uv.y, 1)
            return SIMD3(simd_dot(clipX, point), simd_dot(clipY, point), simd_dot(clipW, point))
        }
        let minimumW = Self.minimumDepthFraction * viewProjection.columns.3.w
        guard corners.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.z > minimumW }) else {
            return nil
        }
        let homography = simd_double3x3(rows: [(clipW + clipX) / 2, (clipW - clipY) / 2, clipW])
        clipCorners = corners
        captureHomography = homography
        inverseCaptureHomography = homography.inverse
        self.sceneSize = sceneSize
    }

    /// nil when the screen point maps behind the layer plane.
    func layerUV(screenUV: SIMD2<Double>) -> SIMD2<Double>? {
        let mapped = inverseCaptureHomography * SIMD3(screenUV.x, screenUV.y, 1)
        guard mapped.z > 0 else { return nil }
        return SIMD2(mapped.x, mapped.y) / mapped.z
    }

    /// `screenPixel` is top-left scene pixels (Y down).
    func contains(screenPixel: SIMD2<Double>) -> Bool {
        let screen = SIMD2(Double(max(sceneSize.width, 1)), Double(max(sceneSize.height, 1)))
        guard let uv = layerUV(screenUV: screenPixel / screen) else { return false }
        return (0 ... 1).contains(uv.x) && (0 ... 1).contains(uv.y)
    }
}
#endif
