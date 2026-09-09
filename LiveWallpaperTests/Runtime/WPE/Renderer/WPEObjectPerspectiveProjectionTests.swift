import CoreGraphics
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import Testing

/// WPE's perspective camera inside an otherwise orthographic scene.
///
/// A 2D scene whose `general.perspectiveoverridefov` is non-zero still publishes a
/// PERSPECTIVE `g_ViewProjectionMatrix`; objects carrying `perspective: true` are projected
/// through it while every image layer keeps the ortho canvas matrix. 3437487219's Earth and
/// cloud models were being projected with the ortho matrix instead, which put a
/// 6500-unit-radius sphere in the wrong half of the frame and upside down.
///
/// Every expected number below is read off a Windows RenderDoc capture, not derived from
/// this renderer. The four captures span two canvases and three authored FOVs, which is what
/// separates the general rule from a curve fitted to one scene:
///
/// | scene      | canvas    | perspectiveoverridefov | g_ViewProjectionMatrix [1][1] | [3][3]    |
/// |------------|-----------|------------------------|-------------------------------|-----------|
/// | 3437487219 | 7680x4320 | 21                     | 5.395517                      | 11654.317 |
/// | 3448877775 | 3840x2160 | 95                     | 0.916331                      |   989.638 |
/// | 3554161528 | 3840x2160 | 90                     | 1.000000                      |  1080.000 |
/// | 2370927443 | 3840x2160 | 95                     | 0.916331                      |   989.638 |
@Suite("WPE per-object perspective projection")
struct WPEObjectPerspectiveProjectionTests {
    /// Column-major, matching `WPEMetalCameraUniforms.viewProjectionMatrix`.
    private static func element(_ matrix: [Double], row: Int, column: Int) -> Double {
        matrix[column * 4 + row]
    }

    private static func matrix(canvas: CGSize, fov: Double) -> [Double] {
        WPEMetalCameraUniforms.objectPerspectiveViewProjectionMatrix(
            width: canvas.width, height: canvas.height, fovDegrees: fov
        )
    }

    /// Verbatim from `.notes/oracle-runs/3437487219-97ad29d672164503b44c2c631a6001c3/windows.json`,
    /// ordinal 5 (`models/Earth/Earth.mdl`), vertex `g_ViewProjectionMatrix`, in row order.
    @Test("The 3437487219 model view-projection is reproduced element for element")
    func matchesEarthCapture() {
        let m = Self.matrix(canvas: CGSize(width: 7680, height: 4320), fov: 21)
        let expected: [[Double]] = [
            [3.034978151321411, 0, 0, -11654.31640625],
            [0, 5.395516872406006, 0, -11654.31640625],
            [0, 0, 0.00033344447729177773, 1.1155991554260254],
            [0, 0, -1, 11654.3173828125],
        ]
        for row in 0 ..< 4 {
            for column in 0 ..< 4 {
                let actual = Self.element(m, row: row, column: column)
                let want = expected[row][column]
                // Loose enough for the capture's float32 rounding, far tighter than any
                // wrong projection would land.
                #expect(
                    abs(actual - want) <= max(1e-4, abs(want) * 1e-5),
                    "[\(row)][\(column)] expected \(want), got \(actual)"
                )
            }
        }
    }

    /// The three other captures. Only the values a model-view-projection cannot hide are
    /// asserted: the two axis scales, the depth row, and the eye distance. (Those captures
    /// expose `g_ModelViewProjectionMatrix`, whose translation carries the model transform.)
    @Test("The scale, depth and eye-distance terms match the other three captures")
    func matchesRemainingCaptures() {
        let cases: [(scene: String, canvas: CGSize, fov: Double, x: Double, y: Double, distance: Double)] = [
            ("3448877775", CGSize(width: 3840, height: 2160), 95, 0.515436, 0.916331, 989.637695),
            ("3554161528", CGSize(width: 3840, height: 2160), 90, 0.5625, 1.0, 1080.0),
            ("2370927443", CGSize(width: 3840, height: 2160), 95, 0.515436, 0.916331, 989.637695),
        ]
        for testCase in cases {
            let m = Self.matrix(canvas: testCase.canvas, fov: testCase.fov)
            #expect(abs(Self.element(m, row: 0, column: 0) - testCase.x) < 1e-5, "\(testCase.scene) x scale")
            #expect(abs(Self.element(m, row: 1, column: 1) - testCase.y) < 1e-5, "\(testCase.scene) y scale")
            #expect(abs(Self.element(m, row: 3, column: 3) - testCase.distance) < 1e-3, "\(testCase.scene) eye distance")
            // The depth row is identical in all four captures despite eye distances from
            // 990 to 11654 — near/far are engine constants, not the scene's nearz/farz.
            #expect(abs(Self.element(m, row: 2, column: 2) - 0.00033344447729177773) < 1e-9, "\(testCase.scene) depth scale")
            // The projection's own bias, recovered from P·V by adding back the eye
            // translation: identical in all four captures.
            let depthScale = Self.element(m, row: 2, column: 2)
            let projectionBias = Self.element(m, row: 2, column: 3) + depthScale * testCase.distance
            #expect(abs(projectionBias - 5.0016669233304185) < 1e-4, "\(testCase.scene) depth bias")
        }
    }

    /// The scene's own `nearz`/`farz` (0.01 / 10000 in all four captures) are NOT what the
    /// matrix uses. Using them would put the canvas plane behind the far plane and clip the
    /// whole scene away, which is how the constants were found in the first place.
    @Test("Near and far are engine constants, reversed-Z")
    func nearFarAreEngineConstants() {
        let m = Self.matrix(canvas: CGSize(width: 7680, height: 4320), fov: 21)
        let depthScale = Self.element(m, row: 2, column: 2)
        // Undo the view translation to recover the projection's own bias.
        let depthBias = Self.element(m, row: 2, column: 3)
            + depthScale * Self.element(m, row: 3, column: 3)
        // ndc.z = -depthScale + depthBias / viewDistance.
        #expect(abs(depthBias / (1 + depthScale) - 5.0) < 1e-3, "near plane")
        #expect(abs(depthBias / depthScale - 15000.0) < 1.0, "far plane")
    }

    /// The z = 0 plane is exactly framed: that is what fixes the eye distance once the FOV
    /// is known, and it is why an ortho-authored canvas keeps its footprint under the
    /// perspective camera.
    @Test("The canvas plane at z = 0 maps to the full viewport")
    func canvasPlaneFillsTheViewport() {
        let canvas = CGSize(width: 7680, height: 4320)
        let m = Self.matrix(canvas: canvas, fov: 21)
        func project(_ point: SIMD3<Double>) -> SIMD2<Double> {
            var clip = SIMD4<Double>(repeating: 0)
            for row in 0 ..< 4 {
                clip[row] = Self.element(m, row: row, column: 0) * point.x
                    + Self.element(m, row: row, column: 1) * point.y
                    + Self.element(m, row: row, column: 2) * point.z
                    + Self.element(m, row: row, column: 3)
            }
            return SIMD2<Double>(clip.x / clip.w, clip.y / clip.w)
        }
        let topLeft = project(SIMD3<Double>(0, 0, 0))
        let bottomRight = project(SIMD3<Double>(canvas.width, canvas.height, 0))
        #expect(abs(topLeft.x + 1) < 1e-4)
        #expect(abs(topLeft.y + 1) < 1e-4)
        #expect(abs(bottomRight.x - 1) < 1e-4)
        #expect(abs(bottomRight.y - 1) < 1e-4)
    }

    // MARK: - Selection

    @Test("Only objects that author perspective: true select the perspective camera")
    func onlyAuthoredObjectsSelectIt() {
        let uniforms = WPEMetalCameraUniforms(
            orthogonalProjection: WPESceneOrthogonalProjection(width: 7680, height: 4320, auto: false),
            sceneCamera: .defaultCamera,
            perspectiveOverrideFOVDegrees: 21,
            perspectiveObjectIDs: ["112", "114"]
        )
        #expect(uniforms.usesPerspectiveProjection == false, "the scene itself stays orthographic")
        #expect(uniforms.objectViewProjectionMatrix(objectID: "112")
            == uniforms.objectPerspectiveViewProjectionMatrix)
        #expect(uniforms.objectViewProjectionMatrix(objectID: "191")
            == uniforms.viewProjectionMatrix)
        #expect(uniforms.usesObjectPerspective(objectID: "114"))
        #expect(uniforms.usesObjectPerspective(objectID: "191") == false)
    }

    /// `perspectiveoverridefov: 0` means the scene never built a perspective camera, so an
    /// object flag alone must not conjure one.
    @Test("Without an authored FOV the object stays orthographic")
    func withoutFOVTheObjectStaysOrthographic() {
        let uniforms = WPEMetalCameraUniforms(
            orthogonalProjection: WPESceneOrthogonalProjection(width: 3840, height: 2160, auto: false),
            sceneCamera: .defaultCamera,
            perspectiveOverrideFOVDegrees: 0,
            perspectiveObjectIDs: ["112"]
        )
        #expect(uniforms.usesObjectPerspective(objectID: "112") == false)
        #expect(uniforms.objectViewProjectionMatrix(objectID: "112") == uniforms.viewProjectionMatrix)
    }

    /// The eye WPE feeds those draws is the canvas centre at z = 2000 — identical in all
    /// four captures, and not the authored `camera.eye` (3437487219 authors
    /// `-783.539 -454.321 0`).
    @Test("The perspective eye is the canvas centre at z = 2000")
    func perspectiveEyeIsCanvasCentre() {
        let uniforms = WPEMetalCameraUniforms(
            orthogonalProjection: WPESceneOrthogonalProjection(width: 7680, height: 4320, auto: false),
            sceneCamera: WPESceneCamera(
                center: SIMD3<Double>(-783.539, -454.321, -1),
                eye: SIMD3<Double>(-783.539, -454.321, 0),
                up: SIMD3<Double>(0, 1, 0),
                nearZ: 0.01,
                farZ: 10000,
                fov: 50
            ),
            perspectiveOverrideFOVDegrees: 21,
            perspectiveObjectIDs: ["112"]
        )
        #expect(uniforms.objectPerspectiveEye == SIMD3<Double>(3840, 2160, 2000))
    }

    // MARK: - Raster state

    /// Both from RenderDoc on 3437487219: the two model passes declare `cullmode: "normal"`
    /// and rasterize `cullMode: back`; every image layer in the same frame declares
    /// `cullmode: "nocull"` and rasterizes `cullMode: none`.
    @Test("cullmode normal is back-face culling, nocull is none")
    func cullModeMapping() {
        #expect(WPEMetalPipelineCache.cullMode(for: "normal") == .back)
        #expect(WPEMetalPipelineCache.cullMode(for: "back") == .back)
        #expect(WPEMetalPipelineCache.cullMode(for: "nocull") == MTLCullMode.none)
        #expect(WPEMetalPipelineCache.cullMode(for: "disabled") == MTLCullMode.none)
        #expect(WPEMetalPipelineCache.cullMode(for: "front") == .front)
    }

    /// The ortho canvas matrix negates Y and the perspective camera does not, so the same
    /// mesh presents opposite windings under the two. Culling only became observable when
    /// `cullmode: "normal"` stopped mapping to `.none`.
    @Test("Front-facing winding follows the projection's handedness")
    func windingFollowsProjection() {
        let uniforms = WPEMetalCameraUniforms(
            orthogonalProjection: WPESceneOrthogonalProjection(width: 7680, height: 4320, auto: false),
            sceneCamera: .defaultCamera,
            perspectiveOverrideFOVDegrees: 21,
            perspectiveObjectIDs: ["112"]
        )
        #expect(uniforms.frontFacingWinding(objectID: "112") == .counterClockwise)
        #expect(uniforms.frontFacingWinding(objectID: "191") == .clockwise)
    }

    // MARK: - Parsing

    @Test("The authored perspective flag reaches the parsed object")
    func parserCarriesTheFlag() throws {
        let json = """
        {
          "general": { "orthogonalprojection": { "width": 7680, "height": 4320 },
                       "perspectiveoverridefov": 21 },
          "camera": { "eye": "0 0 0", "center": "0 0 -1", "up": "0 1 0" },
          "objects": [
            { "id": 112, "name": "Earth", "model": "models/Earth/Earth.mdl", "visible": true,
              "perspective": true, "origin": "3840 -4226.7 -3000", "scale": "65 65 65",
              "angles": "0 0 1.5708" },
            { "id": 191, "name": "The Void", "image": "models/util/solidlayer.json",
              "visible": true, "origin": "3840 2160 0" }
          ]
        }
        """
        let document = try WPESceneDocumentParser.parse(data: Data(json.utf8))
        let earth = try #require(document.imageObjects.first { $0.id == "112" })
        let void = try #require(document.imageObjects.first { $0.id == "191" })
        #expect(earth.usesPerspectiveProjection)
        #expect(void.usesPerspectiveProjection == false)
        #expect(document.general.perspectiveOverrideFOV.resolvedValue == 21)
        #expect(document.general.usesPerspectiveProjection == false)
    }
}
