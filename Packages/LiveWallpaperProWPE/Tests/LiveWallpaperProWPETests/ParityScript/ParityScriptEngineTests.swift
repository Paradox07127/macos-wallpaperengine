import Foundation
import LiveWallpaperProWPE
import XCTest

final class ParityScriptEngineTests: XCTestCase {
    static let install = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Steam/steamapps/common/wallpaper_engine/assets")

    private struct Scene {
        let document: WPESceneDocument
        var state: WPEParitySceneState
        let engine: WPEParityScriptEngine
    }

    private static func scene(_ objects: [[String: Any]],
                              constants: [WPEParityMaterialPassKey: [String: [Double]]] = [:],
                              angleConstants: Set<WPEParityScriptEngine.ConstantKey> = []) throws -> Scene {
        guard FileManager.default.fileExists(atPath: install.appendingPathComponent("scripts").path) else {
            throw XCTSkip("No Wallpaper Engine assets")
        }
        let json: [String: Any] = ["camera": ["center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"], "general": ["orthogonalprojection": ["width": 1920, "height": 1080]],
                                   "objects": objects]
        let document = try WPESceneDocumentParser.parse(
            data: JSONSerialization.data(withJSONObject: json), userValues: [:],
            makeTransformScriptResolver: { _, _ in NoScripts() }
        )
        let state = WPEParitySceneState(document: document, hdr: false, constants: constants)
        let configuration = WPEParityScriptEngine.Configuration(
            assets: WPEParityProgramAssets(sceneDirectory: FileManager.default.temporaryDirectory,
                                           assetRoots: [install]),
            canvasSize: SIMD2(1920, 1080), screenResolution: SIMD2(1920, 1080), angleConstants: angleConstants
        )
        return try Scene(document: document, state: state,
                         engine: WPEParityScriptEngine(document: document, state: state, configuration: configuration))
    }

    private static func layer(_ id: Int, _ name: String, _ fields: [String: Any] = [:]) -> [String: Any] {
        ["id": id, "name": name, "image": "models/\(name).json", "size": "100 100"].merging(fields) { _, new in new }
    }

    private static func scripted(_ value: Any, _ script: String) -> [String: Any] {
        ["value": value, "script": script]
    }

    /// update writes the frame number into alpha; after N ticks the state reads N.
    func testUpdateWritesTheFrameNumberIntoAlphaEveryTick() throws {
        var scene = try Self.scene([
            Self.layer(1, "A", ["alpha": Self.scripted(1, """
            let frame = 0;
            export function update(value) { frame += 1; return frame; }
            """)]),
            Self.layer(2, "B"),
        ])
        scene.engine.start(state: &scene.state)
        for frame in 1 ... 5 {
            scene.engine.tick(dt: 1 / 60, state: &scene.state)
            XCTAssertEqual(scene.state.object("1")?.alpha, Float(frame))
        }
        XCTAssertEqual(scene.state.object("2")?.alpha, 1)
        XCTAssertEqual(scene.engine.exceptionCount, 0, scene.engine.exceptions.joined(separator: "\n"))
    }

    /// With a keyframe animation on the property, update receives this frame's animated value and its return wins.
    func testUpdateReceivesTheAnimatedValueAndItsReturnOverridesIt() throws {
        let animation: [String: Any] = [
            "c0": [["frame": 0, "value": 0], ["frame": 10, "value": 1]],
            "options": ["fps": 10, "length": 10, "mode": "loop"],
        ]
        var scene = try Self.scene([
            Self.layer(1, "A", ["alpha": ["value": 1, "animation": animation, "script": """
            export function update(value) { thisLayer.brightness = value; return value * 0.5; }
            """]]),
            Self.layer(2, "B"),
        ])
        var animations = WPEParitySceneAnimations(document: scene.document, state: scene.state,
                                                  constantComponents: [:])
        scene.engine.start(state: &scene.state)
        for _ in 0 ..< 7 {
            animations.advance(dt: 0.13, state: &scene.state)
            let animated = try XCTUnwrap(scene.state.object("1")?.alpha)
            scene.engine.tick(dt: 0.13, state: &scene.state)
            XCTAssertEqual(scene.state.object("1")?.brightness, animated)
            XCTAssertEqual(scene.state.object("1")?.alpha, Float(Double(animated) * 0.5))
        }
        XCTAssertGreaterThan(scene.state.object("1")?.brightness ?? 0, 0)
    }

    /// getLayerCount leaves out a pending destroy, getLayerIndex misses with −1, destroyLayer runs after the tick.
    func testLayerCountIndexAndDeferredDestroy() throws {
        var scene = try Self.scene([
            Self.layer(1, "A", ["alpha": Self.scripted(1, """
            export function update(value) {
                if (engine.runtime > 0.02) return value;
                const before = thisScene.getLayerCount();
                thisScene.destroyLayer(thisScene.getLayer('B'));
                thisLayer.color = new Vec3(before, thisScene.getLayerCount(), thisScene.getLayerIndex({}));
                thisLayer.brightness = thisScene.getLayerIndex(thisScene.getLayer('B'));
                return value;
            }
            """)]),
            Self.layer(2, "B"),
            Self.layer(3, "C", ["alpha": Self.scripted(1, """
            export function update(value) { return thisScene.getLayerCount(); }
            """)]),
        ])
        scene.engine.start(state: &scene.state)
        scene.engine.tick(dt: 0.01, state: &scene.state)
        XCTAssertEqual(scene.state.object("1")?.color, SIMD3(3, 2, -1))
        XCTAssertEqual(scene.state.object("1")?.brightness, 1)
        XCTAssertEqual(scene.state.object("3")?.alpha, 2)
        XCTAssertEqual(scene.engine.destroyedObjectIDs, ["2"])
        scene.engine.tick(dt: 0.01, state: &scene.state)
        XCTAssertEqual(scene.state.object("3")?.alpha, 2)
    }

    /// createLayer returns null once the scene holds 2048 objects.
    func testCreateLayerStopsAtTheObjectLimit() throws {
        var scene = try Self.scene([
            Self.layer(1, "A", ["alpha": Self.scripted(1, """
            export function init(value) {
                let created = 0;
                while (thisScene.createLayer({ image: 'models/x.json', name: 'x' }) !== null) created += 1;
                thisLayer.brightness = created;
                return thisScene.getLayerCount();
            }
            """)]),
            Self.layer(2, "B"),
        ])
        scene.engine.start(state: &scene.state)
        XCTAssertEqual(scene.state.object("1")?.brightness, 2046)
        XCTAssertEqual(scene.state.object("1")?.alpha, 2048)
        XCTAssertEqual(scene.engine.createdLayers.count, 2046)
    }

    /// Script `Vec3(0,0,90)` on angles lands as radians; setMaterialProperty multiplies π/180 for an angle constant only.
    func testAnglesAndSetMaterialPropertyConvertDegrees() throws {
        let pass = WPEParityMaterialPassKey(objectID: "1", effectID: "5")
        var scene = try Self.scene([
            Self.layer(1, "A", [
                "angles": Self.scripted("0 0 0", """
                export function update(value) {
                    const effect = thisLayer.getEffect(0);
                    effect.setMaterialProperty('turn', 90);
                    effect.setMaterialProperty('speed', 90);
                    thisLayer.brightness = value.z;
                    return new Vec3(0, 0, 90);
                }
                """),
                "effects": [["id": 5, "file": "effects/x.json", "visible": true,
                             "passes": [["constantshadervalues": ["turn": 0, "speed": 0]]]]],
            ]),
        ], constants: [pass: ["turn": [0], "speed": [0]]],
        angleConstants: [WPEParityScriptEngine.ConstantKey(pass: pass, name: "turn")])
        scene.engine.start(state: &scene.state)
        scene.engine.tick(dt: 0.01, state: &scene.state)
        let degrees = WPEParityScriptProperty.degreesToRadians
        XCTAssertEqual(scene.state.object("1")?.angles, SIMD3(0, 0, 90 * degrees))
        XCTAssertEqual(scene.state.constant("turn", of: pass)?.value.x, 90 * degrees)
        XCTAssertEqual(scene.state.constant("speed", of: pass)?.value.x, 90)
        scene.engine.tick(dt: 0.01, state: &scene.state)
        XCTAssertEqual(scene.state.object("1")?.brightness ?? 0, 90, accuracy: 1e-4)
        XCTAssertEqual(scene.engine.exceptionCount, 0, scene.engine.exceptions.joined(separator: "\n"))
    }

    /// A compile failure keeps its binding with no exports; the scene's other scripts still run.
    func testCompileFailureKeepsTheBindingSilent() throws {
        var scene = try Self.scene([
            Self.layer(1, "A", ["alpha": Self.scripted(1, "export function update(value) { return ; ) }")]),
            Self.layer(2, "B", ["alpha": Self.scripted(1, "export function update(value) { return 0.5; }")]),
        ])
        XCTAssertEqual(scene.engine.bindings.map(\.compiled), [false, true])
        XCTAssertEqual(scene.engine.bindings.map(\.exportBits), [0, WPEParityScriptEvent.update.exportBit])
        scene.engine.start(state: &scene.state)
        scene.engine.tick(dt: 0.01, state: &scene.state)
        XCTAssertEqual(scene.state.object("1")?.alpha, 1)
        XCTAssertEqual(scene.state.object("2")?.alpha, 0.5)
    }

    func testModuleNamesResolveAsWPEAssetPaths() {
        XCTAssertEqual(WPEParityScriptModule.resolve("WEMath", importer: "scripts/jsmodules/wevector.js"),
                       "scripts/jsmodules/wemath.js")
        XCTAssertEqual(WPEParityScriptModule.resolve("./util", importer: "scripts/image_origin.js"),
                       "scripts/util.js")
        XCTAssertEqual(WPEParityScriptModule.resolve("../lib/a.js", importer: "scripts/sub/b.js"),
                       "scripts/lib/a.js")
    }

    /// Two overlapping solid layers: enter, move, down on the top one; disablepropagation stops the one below.
    func testCursorPassOrdersEventsAndStopsAtDisablePropagation() {
        let square = (SIMD2<Float>(0, 0), SIMD2<Float>(10, 0), SIMD2<Float>(10, 10), SIMD2<Float>(0, 10))
        var tracker = WPEParityCursorTracker()
        let open = [WPEParityCursorTarget(id: "top", quad: square), WPEParityCursorTarget(id: "below", quad: square)]
        let press = tracker.update(targets: open, cursor: SIMD2(5, 5), leftDown: true, moved: true)
        XCTAssertEqual(press.map { "\($0.event.functionName!) \($0.id)" }, [
            "cursorEnter top", "cursorMove top", "cursorDown top",
            "cursorEnter below", "cursorMove below", "cursorDown below",
        ])
        let release = tracker.update(targets: open, cursor: SIMD2(5, 5), leftDown: false, moved: false)
        XCTAssertEqual(release.map { "\($0.event.functionName!) \($0.id)" }, [
            "cursorUp top", "cursorClick top", "cursorUp below", "cursorClick below",
        ])
        var blocking = WPEParityCursorTracker()
        let stop = [WPEParityCursorTarget(id: "top", quad: square, disablePropagation: true),
                    WPEParityCursorTarget(id: "below", quad: square)]
        XCTAssertEqual(blocking.update(targets: stop, cursor: SIMD2(5, 5), leftDown: false, moved: false).map(\.id),
                       ["top"])
        let away = blocking.update(targets: stop, cursor: SIMD2(50, 5), leftDown: false, moved: true)
        XCTAssertEqual(away.map { "\($0.event.functionName!) \($0.id)" }, ["cursorLeave top"])
    }
}

private struct NoScripts: WPESceneTransformScriptResolving {
    func resolveVec3(script _: String, properties _: [String: WPESceneScriptPropertyValue],
                     seed _: SIMD3<Double>) -> SIMD3<Double>? {
        nil
    }
}
