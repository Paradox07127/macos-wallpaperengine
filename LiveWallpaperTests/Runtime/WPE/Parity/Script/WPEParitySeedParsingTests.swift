#if !LITE_BUILD && DEBUG
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import simd
import XCTest

/// Parsing imports authored seeds; only the bounded parity VM may execute the preserved property scripts.
final class WPEParitySeedParsingTests: XCTestCase {
    func testStaticOriginKeepsItsAuthoredSeedUntilParityInitAndUpdate() throws {
        let script = """
        export function init(value) { value.x += 10; return value; }
        export function update(value) { value.y += 100; return value; }
        """
        let document = try document(objects: [
            ["id": 1, "image": "models/witness.json", "size": "16 16",
             "origin": ["value": "1 2 3", "script": script]],
        ])
        XCTAssertEqual(try XCTUnwrap(document.imageObjects.first).localOrigin, SIMD3(1, 2, 3))
        var state = WPEParitySceneState(document: document, hdr: false)
        XCTAssertEqual(state.object("1")?.origin, SIMD3(1, 2, 3))
        let engine = try engine(document: document, state: &state)
        XCTAssertEqual(state.object("1")?.origin, SIMD3(1, 2, 3), "preparation must not call init/update")
        try engine.start(state: &state)
        XCTAssertEqual(state.object("1")?.origin, SIMD3(11, 2, 3), "init runs once on the authored seed")
        engine.tick(dt: 0, state: &state)
        XCTAssertEqual(state.object("1")?.origin, SIMD3(11, 102, 3), "the first frame applies update once")
        XCTAssertEqual(engine.exceptionCount, 0, engine.exceptions.joined(separator: "\n"))
    }

    func testStaticScriptedParentIsComposedAfterParityInitWithoutBakingItsChild() throws {
        let script = """
        export function init(value) { value.x += 30; return value; }
        export function update(value) { value.y += 40; return value; }
        """
        let document = try document(objects: [
            ["id": 10, "solid": true, "origin": ["value": "10 20 0", "script": script]],
            ["id": 11, "parent": 10, "image": "models/witness.json", "size": "16 16", "origin": "5 7 0"],
        ])
        XCTAssertEqual(try XCTUnwrap(document.transformHostObjects.first { $0.id == "10" }).localOrigin, SIMD3(10, 20, 0))
        XCTAssertEqual(try XCTUnwrap(document.imageObjects.first).localOrigin, SIMD3(5, 7, 0))
        var state = WPEParitySceneState(document: document, hdr: false)
        var transforms = WPEParityLayerTransformSet(document: document, renderTargetSize: SIMD2(320, 180))
        XCTAssertEqual(transforms.world("11").columns.3, SIMD4(15, 27, 0, 1))
        let engine = try engine(document: document, state: &state)
        try engine.start(state: &state)
        refresh(&transforms, from: state)
        XCTAssertEqual(transforms.world("11").columns.3, SIMD4(45, 27, 0, 1))
        XCTAssertEqual(state.object("11")?.origin, SIMD3(5, 7, 0), "a parent update must not rewrite child-local origin")
        engine.tick(dt: 0, state: &state)
        refresh(&transforms, from: state)
        XCTAssertEqual(transforms.world("11").columns.3, SIMD4(45, 67, 0, 1))
        XCTAssertEqual(engine.exceptionCount, 0, engine.exceptions.joined(separator: "\n"))
    }

    func testCameraAndCanvasUseAuthoredSeedsBeforeParityInitializesItsParent() throws {
        let parentScript = """
        export function init(value) { value.x += 30; return value; }
        export function update(value) { value.y += 40; return value; }
        """
        let cameraScript = """
        export function init(value) { value.z += engine.canvasSize.x / 160; return value; }
        export function update(value) { return value; }
        """
        let document = try document(objects: [
            ["id": 10, "solid": true, "origin": ["value": "10 20 0", "script": parentScript]],
            ["id": 20, "parent": 10, "camera": "default",
             "origin": ["value": "5 7 9", "script": cameraScript], "zoom": 1],
        ])
        XCTAssertEqual(document.general.orthogonalProjection.width, 320)
        XCTAssertEqual(document.general.orthogonalProjection.height, 180)
        XCTAssertEqual(document.camera.eye, SIMD3(15, 27, 9), "parse-time camera pose must compose authored seeds")
        XCTAssertEqual(document.staticCamera.eye, SIMD3(4, 5, 6), "root camera remains independent of object scripts")
        var state = WPEParitySceneState(document: document, hdr: false)
        let engine = try engine(document: document, state: &state)
        try engine.start(state: &state)
        XCTAssertEqual(state.object("20")?.origin, SIMD3(5, 7, 11), "parity init sees the authored 320-pixel canvas")
        var transforms = WPEParityLayerTransformSet(document: document, renderTargetSize: SIMD2(320, 180))
        refresh(&transforms, from: state)
        XCTAssertEqual(WPEParityCamera.activeObjectID(document: document, state: state), "20")
        let camera = WPEParityCamera.root(document: document, renderTargetSize: SIMD2(320, 180))
            .applyingObject(world: transforms.world("20"), objectID: "20", document: document, state: state, generalZoom: 1)
        XCTAssertEqual(camera.eye, SIMD3(45, 27, 11))
        XCTAssertEqual(camera.center, SIMD3(45, 27, 10))
        XCTAssertEqual(camera.size, SIMD2(320, 180))
        XCTAssertEqual(engine.exceptionCount, 0, engine.exceptions.joined(separator: "\n"))
    }

    private func document(objects: [[String: Any]]) throws -> WPESceneDocument {
        try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: [
            "camera": ["eye": "4 5 6", "center": "4 5 5", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": 320, "height": 180], "bloom": false],
            "objects": objects,
        ]), userValues: [:])
    }

    private func engine(document: WPESceneDocument, state: inout WPEParitySceneState) throws -> WPEParityScriptEngine {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../../Packages/LiveWallpaperProWPE/Tests/Fixtures/ParityScript/baseclasses.js")
            .standardizedFileURL
        let baseClasses = try Data(contentsOf: fixture)
        let assets = WPEParityProgramAssets(sources: [.lookup(fixture.deletingLastPathComponent()) { path in
            path == "scripts/jsclasses/baseclasses.js" ? baseClasses : nil
        }])
        return try WPEParityScriptEngine.prepare(document: document, state: &state, configuration: .init(
            assets: assets, canvasSize: SIMD2(320, 180), screenResolution: SIMD2(320, 180)
        ), volume: { _, _ in XCTFail("No sound objects") }, command: { _, _, _ in false })
    }

    private func refresh(_ transforms: inout WPEParityLayerTransformSet, from state: WPEParitySceneState) {
        for id in state.ids {
            guard let object = state.object(id) else { continue }
            transforms.setTransform(id, origin: object.origin, angles: object.angles, scale: object.scale)
        }
        transforms.refreshWorlds()
    }
}
#endif
