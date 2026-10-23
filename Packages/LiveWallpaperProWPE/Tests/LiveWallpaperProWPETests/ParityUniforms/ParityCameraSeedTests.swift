import Foundation
import LiveWallpaperCore
@testable import LiveWallpaperProWPE
import simd
import XCTest

/// The camera reads user-resolved scene JSON with strict seeds and native defaults, not the parser's typed fields.
final class ParityCameraSeedTests: XCTestCase {
    private let target = SIMD2<Float>(200, 100)

    private func document(general: [String: Any], objects: [[String: Any]] = [],
                          userValues: [String: WallpaperEngineProjectPropertyValue] = [:]) throws -> WPESceneDocument {
        try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: [
            "camera": ["eye": "0 0 1", "center": "0 0 0", "up": "0 1 0"],
            "general": general, "objects": objects,
        ]), userValues: userValues)
    }

    private static var ortho: [String: Any] {
        ["orthogonalprojection": ["width": 200, "height": 100]]
    }

    func testLastVisibleObjectWithAStringCameraIsActive() throws {
        let document = try document(general: Self.ortho, objects: [
            ["id": 1, "camera": "a"],
            ["name": "named", "camera": "b"],
            ["id": "two", "camera": "c"],
            ["id": true, "name": "flagged", "camera": "d"],
            ["id": 3, "camera": true],
            ["id": 4, "camera": ["value": "e"]],
            ["id": 5],
        ])
        var state = WPEParitySceneState(document: document, hdr: false)
        XCTAssertEqual(WPEParityCamera.activeObjectID(document: document, state: state), "flagged")
        state.set(.visible, of: "flagged", to: .zero)
        XCTAssertEqual(WPEParityCamera.activeObjectID(document: document, state: state), "two")
        state.set(.visible, of: "two", to: .zero)
        XCTAssertEqual(WPEParityCamera.activeObjectID(document: document, state: state), "named")
        state.set(.visible, of: "named", to: .zero)
        XCTAssertEqual(WPEParityCamera.activeObjectID(document: document, state: state), "1")
        state.set(.visible, of: "1", to: .zero)
        XCTAssertNil(WPEParityCamera.activeObjectID(document: document, state: state))
        state.set(.visible, of: "two", to: SIMD4(1, 0, 0, 0))
        XCTAssertEqual(WPEParityCamera.activeObjectID(document: document, state: state), "two")
    }

    func testCameraObjectSeedsUnwrapEnvelopesAndYieldToScriptFields() throws {
        var general: [String: Any] = ["orthogonalprojection": NSNull(), "fov": 45]
        general["zoom"] = 1
        let document = try document(general: general, objects: [
            ["id": 1, "camera": "a", "fov": ["value": 70], "zoom": ["value": 2]],
            ["id": 2, "camera": "b", "fov": "80", "zoom": true],
            ["id": "three", "camera": "c"],
            ["id": 4, "camera": "d", "fov": ["user": "camfov", "value": 40], "zoom": 0.5],
        ], userValues: ["camfov": .number(65)])
        var state = WPEParitySceneState(document: document, hdr: false)
        let root = WPEParityCamera.root(document: document, renderTargetSize: target)
        XCTAssertEqual(root.scenePerspective?.fov, 45)
        let world = matrix_identity_float4x4
        func applied(_ id: String) -> WPEParityCamera {
            root.applyingObject(world: world, objectID: id, document: document, state: state, generalZoom: 1.5)
        }
        XCTAssertEqual(applied("1").scenePerspective?.fov, 70)
        XCTAssertEqual(applied("1").zoom, 3)
        XCTAssertEqual(applied("2").scenePerspective?.fov, 50, "a numeric string is not a seed")
        XCTAssertEqual(applied("2").zoom, 1.5, "a Bool zoom seeds 1")
        XCTAssertEqual(applied("three").scenePerspective?.fov, 50)
        XCTAssertEqual(applied("three").zoom, 1.5)
        XCTAssertEqual(applied("4").scenePerspective?.fov, 65, "the user value replaces the authored seed")
        XCTAssertEqual(applied("4").zoom, 0.75)
        XCTAssertEqual(applied("missing").scenePerspective?.fov, 50)
        state.setScriptField("fov", of: "1", to: .vector(SIMD4(90, 0, 0, 0)), invalidating: .none)
        state.setScriptField("zoom", of: "1", to: .vector(SIMD4(4, 0, 0, 0)), invalidating: .none)
        XCTAssertEqual(applied("1").scenePerspective?.fov, 90)
        XCTAssertEqual(applied("1").zoom, 6)
        XCTAssertEqual(applied("2").scenePerspective?.fov, 50)
    }

    func testParallaxSeedsAreStrictWithNativeDefaults() throws {
        func amount(_ fields: [String: Any], userValues: [String: WallpaperEngineProjectPropertyValue] = [:]) throws
            -> Float? {
            let document = try document(general: Self.ortho.merging(fields) { $1 }, userValues: userValues)
            let camera = WPEParityCamera(document: document, renderTargetSize: target)
            XCTAssertEqual(WPEParityCamera.root(document: document, renderTargetSize: target).parallaxAmount,
                           camera.parallaxAmount)
            return camera.parallaxAmount
        }
        XCTAssertNil(try amount([:]))
        XCTAssertNil(try amount(["cameraparallax": 1, "cameraparallaxamount": 2]), "a numeric flag is not a seed")
        XCTAssertEqual(try amount(["cameraparallax": ["value": true]]), 0.5)
        XCTAssertEqual(try amount(["cameraparallax": true, "cameraparallaxamount": "2"]), 0.5)
        XCTAssertEqual(try amount(["cameraparallax": true, "cameraparallaxamount": ["value": 1.5]]), 1.5)
        XCTAssertEqual(try amount(["cameraparallax": true,
                                   "cameraparallaxamount": ["user": "amount", "value": 0.2]],
                                  userValues: ["amount": .number(0.9)]), 0.9)
        XCTAssertNil(try amount(["cameraparallax": ["user": "parallax", "value": true]],
                                userValues: ["parallax": .bool(false)]))
        let perspective = try document(general: ["orthogonalprojection": NSNull(), "cameraparallax": true])
        XCTAssertNil(WPEParityCamera(document: perspective, renderTargetSize: target).parallaxAmount)
    }

    func testPerspectiveSeedsAreStrictWithNativeDefaults() throws {
        let general: [String: Any] = ["orthogonalprojection": NSNull(), "fov": ["value": 70], "nearz": "1",
                                      "farz": 500, "perspectiveoverridefov": ["value": 60]]
        let plain = try document(general: general)
        let camera = WPEParityCamera(document: plain, renderTargetSize: target)
        XCTAssertEqual(camera.scenePerspective, WPEParityScenePerspective(fov: 70, near: Float(bitPattern: 0x3DCC_CCCD),
                                                                          far: 500))
        XCTAssertEqual(camera.perspectiveFOV, 60)
        XCTAssertEqual(WPEParityCamera.root(document: plain, renderTargetSize: target).scenePerspective, camera.scenePerspective)

        let defaults = try document(general: ["orthogonalprojection": NSNull(), "fov": "70", "nearz": true,
                                              "perspectiveoverridefov": "60"])
        let fallback = WPEParityCamera(document: defaults, renderTargetSize: target)
        XCTAssertEqual(fallback.scenePerspective, WPEParityScenePerspective())
        XCTAssertEqual(fallback.perspectiveFOV, 95)

        let resolved = try document(general: ["orthogonalprojection": NSNull(), "fov": ["user": "fov", "value": 30],
                                              "farz": ["user": "far", "value": 900]],
                                    userValues: ["fov": .number(80), "far": .number(1200)])
        XCTAssertEqual(WPEParityCamera(document: resolved, renderTargetSize: target).scenePerspective,
                       WPEParityScenePerspective(fov: 80, near: Float(bitPattern: 0x3DCC_CCCD), far: 1200))

        let ortho = try document(general: Self.ortho.merging(["fov": 70]) { $1 })
        XCTAssertNil(WPEParityCamera(document: ortho, renderTargetSize: target).scenePerspective)
    }

    /// With a camera object the loaded perspective FOV is the object's; the root camera returns to general `fov`.
    func testRootPerspectiveFOVIgnoresTheCameraObject() throws {
        let document = try document(general: ["orthogonalprojection": NSNull(), "fov": ["value": 33], "farz": 700],
                                    objects: [["id": 1, "camera": "a", "fov": 77, "origin": "0 0 0", "angles": "0 0 0"]])
        let root = WPEParityCamera.root(document: document, renderTargetSize: target)
        XCTAssertEqual(root.scenePerspective, WPEParityScenePerspective(fov: 33, near: Float(bitPattern: 0x3DCC_CCCD),
                                                                        far: 700))
        let loaded = WPEParityCamera(document: document, renderTargetSize: target)
        XCTAssertEqual(loaded.scenePerspective?.fov, Float(document.camera.fov))
        XCTAssertEqual(loaded.scenePerspective?.far, 700)
    }

    func testShakeSeedsAreStrictWithNativeDefaults() throws {
        let fields: [String: Any] = ["camerashake": true, "camerashakespeed": ["value": 4],
                                     "camerashakeamplitude": "2", "camerashakeroughness": 2]
        let ortho = try document(general: Self.ortho.merging(fields) { $1 })
        XCTAssertEqual(WPEParityCamera(document: ortho, renderTargetSize: target).shake,
                       WPEParityCameraShake(speed: 4, amplitude: 0.5, roughness: 2, orthographic: true))
        let perspective = try document(general: fields.merging(["orthogonalprojection": NSNull()]) { $1 })
        XCTAssertEqual(WPEParityCamera(document: perspective, renderTargetSize: target).shake,
                       WPEParityCameraShake(speed: 4, amplitude: 0.5, roughness: 2, orthographic: false))
        let disabledFields: [String: Any] = ["camerashake": ["value": false], "camerashakespeed": 9]
        let disabled = try document(general: Self.ortho.merging(disabledFields) { $1 })
        XCTAssertNil(WPEParityCamera(document: disabled, renderTargetSize: target).shake)
        let numeric = try document(general: Self.ortho.merging(["camerashake": 1]) { $1 })
        XCTAssertNil(WPEParityCamera(document: numeric, renderTargetSize: target).shake)
        let user = try document(general: Self.ortho.merging(["camerashake": ["user": "shake", "value": false]]) { $1 },
                                userValues: ["shake": .bool(true)])
        XCTAssertEqual(WPEParityCamera(document: user, renderTargetSize: target).shake, WPEParityCameraShake())
    }
}
