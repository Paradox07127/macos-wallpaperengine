import CoreGraphics
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import simd
import Testing

@Suite("WPE projected composelayer quad")
struct WPEProjectedComposeQuadTests {
    private static let sceneSize = CGSize(width: 3840, height: 2160)

    private static func quad2077(
        angles: SIMD3<Double> = SIMD3(2.5, -2.5, 0) * .pi / 180,
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

    private static func camera(fov: Double, sceneIDs: Set<String>, perspectiveScene: Bool = false) -> WPEMetalCameraUniforms {
        WPEMetalCameraUniforms(
            orthogonalProjection: .init(width: 3840, height: 2160, auto: false),
            sceneCamera: .defaultCamera, usesPerspectiveProjection: perspectiveScene,
            perspectiveOverrideFOVDegrees: fov, perspectiveObjectIDs: sceneIDs
        )
    }

    @Test("2077 tilt corners match the derivation in clip space and screen pixels")
    func tiltCornersMatchDerivation() throws {
        let quad = try #require(Self.quad2077())
        let expectedClip: [SIMD3<Double>] = [
            SIMD3(-1401.161085, -1402.663703, 1250.057322),
            SIMD3(1404.166322, -1402.663703, 1032.309341),
            SIMD3(-1404.166322, 1402.663703, 1127.690659),
            SIMD3(1401.161085, 1402.663703, 909.942678),
        ]
        let expectedPixels: [SIMD2<Double>] = [
            SIMD2(-232.085, 2291.846), SIMD2(4531.620, 2547.464),
            SIMD2(-470.726, -263.344), SIMD2(4876.482, -584.805),
        ]
        #expect(quad.clipCorners.count == 4)
        for (corner, expected) in zip(quad.clipCorners, expectedClip) {
            #expect(simd_length(corner - expected) <= 1e-3, "\(corner) != \(expected)")
        }
        for (corner, expected) in zip(quad.clipCorners, expectedPixels) {
            let pixel = SIMD2((0.5 + 0.5 * corner.x / corner.z) * 3840, (0.5 - 0.5 * corner.y / corner.z) * 2160)
            Self.expectClose(pixel, expected, 1e-3)
        }
    }

    @Test("Capture homography maps layer uv to scene uv as the derivation does")
    func captureHomographyMatchesDerivation() throws {
        let quad = try #require(Self.quad2077())
        let normalized = quad.captureHomography * (1 / quad.captureHomography[2, 2])
        let expected = simd_double3x3(rows: [
            SIMD3(1.147291326, 0.055587895, -0.122584886),
            SIMD3(-0.096545972, 1.298092719, -0.121918649),
            SIMD3(-0.193091944, 0.108510842, 1),
        ])
        for column in 0 ..< 3 {
            for row in 0 ..< 3 {
                #expect(abs(normalized[column, row] - expected[column, row]) <= 1e-6, "Hc[\(row)][\(column)]")
            }
        }
        let sampled = quad.captureHomography * SIMD3(0.25, 0.25, 1)
        Self.expectClose(SIMD2(sampled.x, sampled.y) / sampled.z, SIMD2(0.181983, 0.182323), 1e-6)
        let layerUV = try #require(quad.layerUV(screenUV: SIMD2(0, 0)))
        Self.expectClose(layerUV, SIMD2(0.101929, 0.101502), 1e-6)
    }

    @Test("Hit test inverts the homography onto the layer's unit square")
    func containsUsesInverseHomography() throws {
        let quad = try #require(Self.quad2077())
        #expect(quad.contains(screenPixel: SIMD2(1920, 1080)))
        // Inside the axis-aligned bounds of the tilted quad but outside its trapezoid.
        #expect(!quad.contains(screenPixel: SIMD2(-400, -500)))
        #expect(quad.contains(screenPixel: SIMD2(-400, 0)))
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
