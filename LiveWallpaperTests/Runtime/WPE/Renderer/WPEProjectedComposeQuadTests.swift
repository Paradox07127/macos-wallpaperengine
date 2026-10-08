import CoreGraphics
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import simd
import Testing

@Suite("WPE projected composelayer quad")
struct WPEProjectedComposeQuadTests {
    private static let sceneSize = CGSize(width: 3840, height: 2160)

    /// Windows RenderDoc capture of scene 3808922316 #2077, frame center-a1.
    private static let measuredAngles = SIMD3<Double>(-2.5046, 2.4974, -0.1001) * .pi / 180

    private static func quad2077(
        angles: SIMD3<Double> = measuredAngles,
        fovDegrees: Double = 90
    ) -> WPEProjectedComposeQuad? {
        WPEProjectedComposeQuad(
            origin: SIMD3(1920, 1080, 0), scale: SIMD3(1.3, 1.3, 1.5), angles: angles,
            size: sceneSize, sceneSize: sceneSize, fovDegrees: fovDegrees
        )
    }

    private static func expectClose(_ lhs: SIMD2<Double>, _ rhs: SIMD2<Double>, _ tolerance: Double) {
        #expect(abs(lhs.x - rhs.x) <= tolerance && abs(lhs.y - rhs.y) <= tolerance, "\(lhs) != \(rhs)")
    }

    /// Top-left scene pixels of layer uv as the draw-back rasterises it from the clip corners.
    private static func drawBackPixel(_ quad: WPEProjectedComposeQuad, _ uv: SIMD2<Double>) -> SIMD2<Double> {
        let corners = quad.clipCorners
        let clip = (1 - uv.x) * (1 - uv.y) * corners[2] + uv.x * (1 - uv.y) * corners[3]
            + (1 - uv.x) * uv.y * corners[0] + uv.x * uv.y * corners[1]
        return SIMD2((0.5 + 0.5 * clip.x / clip.z) * 3840, (0.5 - 0.5 * clip.y / clip.z) * 2160)
    }

    @Test("Draw-back corners and card points match the Windows capture")
    func drawBackMatchesMeasurement() throws {
        let quad = try #require(Self.quad2077())
        #expect(quad.clipCorners.count == 4)
        let corners: [(SIMD2<Double>, SIMD2<Double>)] = [
            (SIMD2(0, 0), SIMD2(-688.5, -391.7)), (SIMD2(1, 0), SIMD2(4074.2, -128.1)),
            (SIMD2(0, 1), SIMD2(-1039.4, 2739.6)), (SIMD2(1, 1), SIMD2(4308.9, 2427.8)),
        ]
        let cardPoints: [(SIMD2<Double>, SIMD2<Double>)] = [
            (SIMD2(1, 1) / 6, SIMD2(207.3, 113.7)), (SIMD2(5, 1) / 6, SIMD2(3424.4, 236.4)),
            (SIMD2(1, 5) / 6, SIMD2(62.8, 2121.5)), (SIMD2(5, 5) / 6, SIMD2(3535.2, 1991.3)),
        ]
        var worst = 0.0
        for (uv, measured) in corners + cardPoints {
            let rasterised = Self.drawBackPixel(quad, uv)
            Self.expectClose(rasterised, measured, 0.1)
            let mapped = quad.drawBackHomography * SIMD3(uv.x, uv.y, 1)
            Self.expectClose(SIMD2(mapped.x, mapped.y) / mapped.z * SIMD2(3840, 2160), measured, 0.1)
            let roundTrip = try #require(quad.layerUV(screenUV: measured / SIMD2(3840, 2160)))
            Self.expectClose(roundTrip, uv, 1e-4)
            worst = max(worst, simd_reduce_max(simd_abs(rasterised - measured)))
        }
        print("WPEProjectedComposeQuadTests draw-back worst pixel error \(worst)")
    }

    @Test("Capture homography is the orthographic projection of the layer quad")
    func captureHomographyIsOrthographic() throws {
        let quad = try #require(Self.quad2077())
        let expected = simd_double3x3(rows: [
            SIMD3(1.298763, 0.000116, -0.149440),
            SIMD3(0.004033, 1.298760, -0.151397),
            SIMD3(0, 0, 1),
        ])
        var worst = 0.0
        for column in 0 ..< 3 {
            for row in 0 ..< 3 {
                let error = abs(quad.captureHomography[column, row] - expected[column, row])
                #expect(error <= 1e-5, "Hc[\(row)][\(column)]")
                worst = max(worst, error)
            }
        }
        print("WPEProjectedComposeQuadTests capture worst element error \(worst)")
    }

    @Test("Hit test follows the perspective trapezoid, not the captured quad")
    func containsUsesDrawBackTrapezoid() throws {
        let quad = try #require(Self.quad2077())
        #expect(quad.contains(screenPixel: SIMD2(1920, 1080)))
        // Left of the captured quad's x ≈ −573 edge, right of the trapezoid's x ≈ −1001 edge.
        #expect(quad.contains(screenPixel: SIMD2(-800, 2400)))
        // Inside the captured quad (x < 4413), right of the trapezoid's x ≈ 4086 edge.
        #expect(!quad.contains(screenPixel: SIMD2(4300, 0)))
    }

    private static func camera(fov: Double, sceneIDs: Set<String>, perspectiveScene: Bool = false) -> WPEMetalCameraUniforms {
        WPEMetalCameraUniforms(
            orthogonalProjection: .init(width: 3840, height: 2160, auto: false),
            sceneCamera: .defaultCamera, usesPerspectiveProjection: perspectiveScene,
            perspectiveOverrideFOVDegrees: fov, perspectiveObjectIDs: sceneIDs
        )
    }

    @Test("Zero angles under perspective reduce to the orthographic subregion")
    func zeroAnglesMatchOrthographicSubregion() throws {
        let quad = try #require(Self.quad2077(angles: .zero))
        let expected: [SIMD2<Double>] = [SIMD2(-1.3, -1.3), SIMD2(1.3, -1.3), SIMD2(-1.3, 1.3), SIMD2(1.3, 1.3)]
        for (corner, ndc) in zip(quad.clipCorners, expected) {
            Self.expectClose(SIMD2(corner.x, corner.y) / corner.z, ndc, 1e-9)
        }
    }

    @Test("No perspective camera or a corner at/behind the eye yields nil")
    func degenerateInputsYieldNil() {
        #expect(Self.quad2077(fovDegrees: 0) == nil)
        // Rx 60° lifts the top edge to z = 1404·sin 60° ≈ 1216 > D = 1080.
        #expect(Self.quad2077(angles: SIMD3(.pi / 3, 0, 0)) == nil)
    }

    @Test("Live perspective overrides take precedence over the authored set")
    func liveOverridePrecedence() {
        #expect(Self.camera(fov: 90, sceneIDs: []).withLivePerspectiveOverrides(["2077": true])
            .usesProjectedCompose(objectID: "2077"))
        #expect(Self.camera(fov: 90, sceneIDs: ["2077"]).usesProjectedCompose(objectID: "2077"))
        #expect(!Self.camera(fov: 90, sceneIDs: ["2077"]).withLivePerspectiveOverrides(["2077": false])
            .usesProjectedCompose(objectID: "2077"))
        #expect(!Self.camera(fov: 0, sceneIDs: ["2077"]).withLivePerspectiveOverrides(["2077": true])
            .usesProjectedCompose(objectID: "2077"))
        #expect(!Self.camera(fov: 90, sceneIDs: ["2077"], perspectiveScene: true).usesProjectedCompose(objectID: "2077"))
        #expect(!Self.camera(fov: 90, sceneIDs: []).withLivePerspectiveOverrides(["2077": true])
            .usesObjectPerspective(objectID: "2077"))
    }

    @Test("Empty overrides keep camera equality and scene motion carries overrides")
    func overridesSurviveSceneMotion() {
        let base = Self.camera(fov: 90, sceneIDs: ["a"])
        let motion = WPESceneCameraMotionSample(origin: SIMD3(37, -23, 0), zoom: 1.75)
        #expect(base.withLivePerspectiveOverrides([:]) == base)
        #expect(base.withLivePerspectiveOverrides([:]).applyingSceneMotion(motion) == base.applyingSceneMotion(motion))
        let live = base.withLivePerspectiveOverrides(["b": true])
        #expect(live != base)
        #expect(live.applyingSceneMotion(motion).livePerspectiveOverrides == ["b": true])
    }

    @Test("Presentation merge keeps the newest perspective write")
    func presentationMergeCarriesPerspective() {
        var mutation = WPELayerScriptPresentationMutation(perspective: true)
        mutation.merge(.init(alignment: "top"))
        #expect(mutation.perspective == true)
        mutation.merge(.init(perspective: false))
        #expect(mutation.perspective == false)
        #expect(mutation.alignment == "top")
    }
}
