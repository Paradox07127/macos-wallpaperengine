import Foundation
@testable import LiveWallpaperProWPE
import XCTest

final class ParityScriptCameraTransformsTests: XCTestCase {
    private static let rootDefaults: [WPEParitySceneState.ScriptFieldKey: WPEParitySceneState.ScriptValue] = [
        .init(objectID: "", name: "cameraTransforms.eye"): .vector(SIMD4(0, 0, 0, 0)),
        .init(objectID: "", name: "cameraTransforms.center"): .vector(SIMD4(0, 0, -1, 0)),
        .init(objectID: "", name: "cameraTransforms.up"): .vector(SIMD4(0, 1, 0, 0)),
        .init(objectID: "", name: "cameraTransforms.zoom"): .vector(SIMD4(1, 0, 0, 0)),
    ]

    /// A general.zoom script whose applyUserProperties rewrites only the root zoom; the scene zoom keeps its value.
    func testGeneralZoomScriptSetsRootZoomFromUserPropertiesAndKeepsSceneZoom() throws {
        let zoomScript = """
        'use strict';

        export function applyUserProperties(changedUserProperties) {
            if (changedUserProperties.trainshake != undefined) {
                let cameraTransforms = thisScene.getCameraTransforms();
                cameraTransforms.zoom = changedUserProperties.trainshake ? 1.01 : 1.0;
                thisScene.setCameraTransforms(cameraTransforms);
            }
        }
        """
        let document = try Self.document(general: ["orthogonalprojection": ["width": 3840, "height": 2160],
                                                   "zoom": ["script": zoomScript, "value": 1.01]],
                                         objects: [["id": 1, "image": "models/a.json", "size": "64 64"]])
        var state = WPEParitySceneState(document: document, hdr: false)
        var logs: [String] = []
        let engine = try WPEParityScriptEngine(document: document, state: state, configuration: .init(
            assets: Self.assets(), canvasSize: SIMD2(3840, 2160), screenResolution: SIMD2(3840, 2160),
            userPropertiesJSON: #"{"trainshake":{"type":"bool","value":true}}"#, fieldDefaults: Self.rootDefaults,
            log: { _, message in logs.append(message) }
        ))
        try engine.start(state: &state)
        XCTAssertEqual(engine.exceptionCount, 0, engine.exceptions.joined(separator: "\n"))
        XCTAssertFalse(logs.contains { $0.contains("general.zoom script is unsupported") }, logs.joined(separator: "\n"))
        XCTAssertEqual(state.scriptField("zoom", of: ""), .vector(SIMD4(1.01, 0, 0, 0)))
        XCTAssertEqual(state.scriptField("cameraTransforms.zoom", of: ""), .vector(SIMD4(1.01, 0, 0, 0)))
        for name in ["eye", "center", "up"] {
            let key = WPEParitySceneState.ScriptFieldKey(objectID: "", name: "cameraTransforms.\(name)")
            XCTAssertEqual(state.scriptField(key.name, of: ""), Self.rootDefaults[key], name)
        }
        let off = #"{"trainshake":{"type":"bool","value":false}}"#
        engine.applyUserProperties(changedJSON: off, mergedJSON: off, state: &state)
        XCTAssertEqual(engine.exceptionCount, 0, engine.exceptions.joined(separator: "\n"))
        XCTAssertEqual(state.scriptField("cameraTransforms.zoom", of: ""), .vector(SIMD4(1, 0, 0, 0)))
        XCTAssertEqual(state.scriptField("zoom", of: ""), .vector(SIMD4(1.01, 0, 0, 0)))
    }

    /// An update reads back its own set in the same callback; an eye/center set keeps up and the earlier zoom.
    func testUpdateReadsBackCameraTransformsAndKeepsUnsetMembers() throws {
        let panScript = "export function update(v){var c=thisScene.getCameraTransforms();c.eye=new Vec3(80,20,10);"
            + "c.center=new Vec3(80,20,9);thisScene.setCameraTransforms(c);return .5;}"
        let zoomScript = "export function update(v){var c=thisScene.getCameraTransforms();c.zoom=2;"
            + "thisScene.setCameraTransforms(c);return thisScene.getCameraTransforms().zoom/4;}"
        let document = try Self.document(general: ["orthogonalprojection": ["width": 256, "height": 128]], objects: [
            ["id": 1, "image": "models/a.json", "size": "48 96", "alpha": ["value": 1, "script": panScript]],
            ["id": 2, "image": "models/a.json", "size": "48 96", "alpha": ["value": 1, "script": zoomScript]],
        ])
        var state = WPEParitySceneState(document: document, hdr: false)
        let engine = try WPEParityScriptEngine(document: document, state: state, configuration: .init(
            assets: Self.assets(), canvasSize: SIMD2(256, 128), screenResolution: SIMD2(256, 128),
            fieldDefaults: Self.rootDefaults
        ))
        try engine.start(state: &state)
        engine.tick(dt: 0.1, state: &state)
        XCTAssertEqual(engine.exceptionCount, 0, engine.exceptions.joined(separator: "\n"))
        XCTAssertEqual(state.object("1")?.alpha, 0.5)
        XCTAssertEqual(state.object("2")?.alpha, 0.5)
        XCTAssertEqual(state.scriptField("cameraTransforms.eye", of: ""), .vector(SIMD4(80, 20, 10, 0)))
        XCTAssertEqual(state.scriptField("cameraTransforms.center", of: ""), .vector(SIMD4(80, 20, 9, 0)))
        XCTAssertEqual(state.scriptField("cameraTransforms.up", of: ""), .vector(SIMD4(0, 1, 0, 0)))
        XCTAssertEqual(state.scriptField("cameraTransforms.zoom", of: ""), .vector(SIMD4(2, 0, 0, 0)))
    }

    private static func document(general: [String: Any], objects: [[String: Any]]) throws -> WPESceneDocument {
        try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: [
            "camera": ["eye": "0 0 0", "center": "0 0 -1", "up": "0 1 0"], "general": general, "objects": objects,
        ]), userValues: [:])
    }

    private static func assets() throws -> WPEParityProgramAssets {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/ParityScript/baseclasses.js")
        let baseClasses = try Data(contentsOf: fixture)
        return WPEParityProgramAssets(sources: [.lookup(fixture.deletingLastPathComponent()) { path in
            path == "scripts/jsclasses/baseclasses.js" ? baseClasses : nil
        }])
    }
}
