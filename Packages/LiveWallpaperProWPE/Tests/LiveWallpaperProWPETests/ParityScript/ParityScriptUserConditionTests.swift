import Foundation
@testable import LiveWallpaperProWPE
import XCTest

final class ParityScriptUserConditionTests: XCTestCase {
    func testComboChangeComparesItsTextWithEachCondition() throws {
        let script = """
        export var scriptProperties = createScriptProperties().addCheckbox({name:'play',value:false})
            .addCheckbox({name:'pause',value:false}).finish();
        export function applyUserProperties() {
            thisLayer.alpha = scriptProperties.pause === true ? 1 : 0;
            thisLayer.brightness = scriptProperties.play === false ? 1 : 0;
        }
        """
        var scene = try Self.scene([Self.layer(1, "A", script: script, properties: [
            "play": ["user": ["name": "k", "condition": "1"], "value": false],
            "pause": ["user": ["name": "k", "condition": "0"], "value": false],
        ])])
        try scene.engine.start(state: &scene.state)
        let combo = #"{"k":{"type":"combo","value":"0"}}"#
        scene.engine.applyUserProperties(changedJSON: combo, mergedJSON: combo, state: &scene.state)
        XCTAssertEqual(scene.state.object("1")?.alpha, 1)
        XCTAssertEqual(scene.state.object("1")?.brightness, 1)
        XCTAssertEqual(scene.engine.exceptionCount, 0, scene.engine.exceptions.joined(separator: "\n"))
    }

    func testConditionTextFollowsJsoncppAsStringAndContainersPassThrough() throws {
        let script = """
        export var scriptProperties = createScriptProperties().addCheckbox({name:'b',value:false})
            .addCheckbox({name:'i',value:false}).addCheckbox({name:'f',value:false})
            .addText({name:'a',value:''}).addSlider({name:'p',value:0}).finish();
        export function applyUserProperties() {
            const p = scriptProperties;
            thisLayer.origin = new Vec3(p.b === true ? 1 : 0, p.i === true ? 1 : 0, p.f === true ? 1 : 0);
            thisLayer.scale = new Vec3(Array.isArray(p.a) ? p.a.length : 0, p.p, 0);
        }
        """
        var scene = try Self.scene([Self.layer(1, "A", script: script, properties: [
            "b": ["user": ["name": "b", "condition": "true"], "value": false],
            "i": ["user": ["name": "i", "condition": "2"], "value": false],
            "f": ["user": ["name": "f", "condition": "0.10000000000000001"], "value": false],
            "a": ["user": ["name": "a", "condition": "1"], "value": ""],
            "p": ["user": "p", "value": 0],
        ])])
        try scene.engine.start(state: &scene.state)
        let changed = #"{"a":{"type":"x","value":[1,2,3]},"b":{"type":"bool","value":true},"#
            + #""f":{"type":"slider","value":0.1},"i":{"type":"slider","value":2},"p":{"type":"slider","value":7}}"#
        scene.engine.applyUserProperties(changedJSON: changed, mergedJSON: changed, state: &scene.state)
        XCTAssertEqual(scene.state.object("1")?.origin, SIMD3(1, 1, 1))
        XCTAssertEqual(scene.state.object("1")?.scale, SIMD3(3, 7, 0))
        XCTAssertEqual(scene.engine.exceptionCount, 0, scene.engine.exceptions.joined(separator: "\n"))
    }

    /// Each callback appends its digit: init A 1, init B 2, apply A 3, apply B 4, update A 5, update B 6.
    func testLoadRunsApplyUserPropertiesAfterEveryInitAndBeforeTheFirstUpdate() throws {
        func script(_ base: Int) -> String {
            """
            function record(digit) {
                shared.order = (shared.order || 0) * 10 + digit;
                thisScene.getLayer('Log').alpha = shared.order;
            }
            export function init() { record(\(base)); }
            export function applyUserProperties() { record(\(base + 2)); }
            export function update() { record(\(base + 4)); }
            """
        }
        var scene = try Self.scene([
            Self.layer(1, "A", script: script(1)), Self.layer(2, "B", script: script(2)), Self.layer(3, "Log"),
        ], userPropertiesJSON: #"{"k":{"type":"combo","value":"0"}}"#)
        try scene.engine.start(state: &scene.state)
        scene.engine.tick(dt: 1 / 60, state: &scene.state)
        XCTAssertEqual(scene.state.object("3")?.alpha, 123_456)
        XCTAssertEqual(scene.engine.dispatchCount(.applyUserProperties), 1)
        XCTAssertEqual(scene.engine.exceptionCount, 0, scene.engine.exceptions.joined(separator: "\n"))
    }

    private struct Scene {
        let engine: WPEParityScriptEngine
        var state: WPEParitySceneState
    }

    private static func layer(_ id: Int, _ name: String, script: String? = nil,
                              properties: [String: Any] = [:]) -> [String: Any] {
        var object: [String: Any] = ["id": id, "name": name, "image": "models/\(name).json", "size": "100 100"]
        if let script {
            object["alpha"] = ["value": 1, "script": script, "scriptproperties": properties]
        }
        return object
    }

    private static func scene(_ objects: [[String: Any]], userPropertiesJSON: String = "{}") throws -> Scene {
        let json: [String: Any] = [
            "camera": ["eye": "0 0 0", "center": "0 0 -1", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": 64, "height": 64]],
            "objects": objects,
        ]
        let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: json),
                                                        userValues: [:], makeTransformScriptResolver: { _, _ in NoScripts() })
        var state = WPEParitySceneState(document: document, hdr: false)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/ParityScript/baseclasses.js")
        let baseClasses = try Data(contentsOf: fixture)
        let assets = WPEParityProgramAssets(sources: [.lookup(fixture.deletingLastPathComponent()) { path in
            path == "scripts/jsclasses/baseclasses.js" ? baseClasses : nil
        }])
        let engine = try WPEParityScriptEngine.prepare(
            document: document, state: &state,
            configuration: .init(assets: assets, canvasSize: SIMD2(64, 64), screenResolution: SIMD2(64, 64),
                                 userPropertiesJSON: userPropertiesJSON),
            volume: { _, _ in }, command: { _, _, _ in false }
        )
        return Scene(engine: engine, state: state)
    }
}

private struct NoScripts: WPESceneTransformScriptResolving {
    func resolveVec3(script _: String, properties _: [String: WPESceneScriptPropertyValue],
                     seed _: SIMD3<Double>) -> SIMD3<Double>? {
        nil
    }
}
