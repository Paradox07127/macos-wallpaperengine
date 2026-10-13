import Foundation
import LiveWallpaperProWPE
import XCTest

final class ParityScriptEngineTests: XCTestCase {
    func testLightAndCameraModuleGettersUseFactoryDefaultsAndTypedWrites() throws {
        let json = #"""
        {"camera":{"eye":"0 0 0","center":"0 0 -1","up":"0 1 0"},
         "general":{"orthogonalprojection":{"width":200,"height":100}},
         "objects":[
          {"id":1,"light":"lpoint","intensity":{"script":"const sum = thisObject.color.x + thisObject.intensity + thisObject.radius + thisObject.exponent + thisObject.innercone + thisObject.outercone; if (!thisObject.solid || thisObject.parallaxDepth.x !== 1 || thisObject.parallaxDepth.y !== 1) throw new Error('native defaults'); export function init(v) { thisObject.color = new Vec3(0.25, 0.5, 1); return sum; }"}},
          {"id":2,"camera":"camera","visible":false,"zoom":{"script":"const fov = thisObject.fov; export function init(v) { return fov; }"}}]}
        """#
        let document = try WPESceneDocumentParser.parse(data: Data(json.utf8), userValues: [:],
                                                        makeTransformScriptResolver: { _, _ in NoScripts() })
        var state = WPEParitySceneState(document: document, hdr: false)
        // Fixed shipped helper, SHA256 708e6636167f0456eebf3ba05274d7b7763d17dfbd44c2711dc3d6d98f0cb294.
        // Kept outside the test target's source directory; this guard needs no installed Steam assets.
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/ParityScript/baseclasses.js")
        let baseClasses = try Data(contentsOf: fixture)
        let engine = try WPEParityScriptEngine(document: document, state: state, configuration: .init(
            assets: WPEParityProgramAssets(sources: [.lookup(fixture.deletingLastPathComponent()) { path in
                path == "scripts/jsclasses/baseclasses.js" ? baseClasses : nil
            }]),
            canvasSize: SIMD2(200, 100), screenResolution: SIMD2(200, 100)
        ))
        engine.start(state: &state)
        XCTAssertEqual(state.scriptField("intensity", of: "1"), .vector(SIMD4(53, 0, 0, 0)))
        XCTAssertEqual(state.object("1")?.color, SIMD3(0.25, 0.5, 1))
        XCTAssertEqual(state.scriptField("zoom", of: "2"), .vector(SIMD4(50, 0, 0, 0)))
        XCTAssertEqual(engine.exceptionCount, 0, engine.exceptions.joined(separator: "\n"))
    }

    static let install = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Steam/steamapps/common/wallpaper_engine/assets")

    private struct Scene {
        let document: WPESceneDocument
        var state: WPEParitySceneState
        let engine: WPEParityScriptEngine
    }

    private static func scene(_ objects: [[String: Any]],
                              constants: [WPEParityMaterialPassKey: [String: [Double]]] = [:],
                              angleConstants: Set<WPEParityScriptEngine.ConstantKey> = [],
                              general: [String: Any] = [:],
                              configure: (inout WPEParityScriptEngine.Configuration) -> Void = { _ in }) throws -> Scene {
        guard FileManager.default.fileExists(atPath: install.appendingPathComponent("scripts").path) else {
            throw XCTSkip("No Wallpaper Engine assets")
        }
        var generalJSON: [String: Any] = ["orthogonalprojection": ["width": 1920, "height": 1080]]
        generalJSON.merge(general) { _, new in new }
        let json: [String: Any] = ["camera": ["center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"], "general": generalJSON,
                                   "objects": objects]
        let document = try WPESceneDocumentParser.parse(
            data: JSONSerialization.data(withJSONObject: json), userValues: [:],
            makeTransformScriptResolver: { _, _ in NoScripts() }
        )
        let state = WPEParitySceneState(document: document, hdr: false, constants: constants)
        var configuration = WPEParityScriptEngine.Configuration(
            assets: WPEParityProgramAssets(sceneDirectory: FileManager.default.temporaryDirectory,
                                           assetRoots: [install]),
            canvasSize: SIMD2(1920, 1080), screenResolution: SIMD2(1920, 1080), angleConstants: angleConstants
        )
        configure(&configuration)
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

    /// engine.setTimeout / setInterval return a function that cancels the timer, as Workshop 3326873240 calls it.
    func testTimersReturnACancelFunction() throws {
        var scene = try Self.scene([
            Self.layer(1, "A", ["alpha": Self.scripted(1, """
            let ticks = 0;
            let stop;
            export function init() { stop = engine.setInterval(() => { ticks += 1; }, 10); }
            export function update(value) { if (ticks === 2) stop(); return ticks; }
            """)]),
        ])
        scene.engine.start(state: &scene.state)
        for _ in 0 ..< 6 {
            scene.engine.tick(dt: 0.011, state: &scene.state)
        }
        XCTAssertEqual(scene.state.object("1")?.alpha, 2)
        XCTAssertEqual(scene.engine.exceptionCount, 0, scene.engine.exceptions.joined(separator: "\n"))
    }

    /// Module scope already reads the loaded layer values.
    func testModuleScopeReadsTheLoadedState() throws {
        var scene = try Self.scene([
            Self.layer(1, "A", ["origin": "100 200 0", "alpha": Self.scripted(1, """
            const original = thisLayer.origin.x;
            export function update(value) { return original / 100; }
            """)]),
        ])
        scene.engine.start(state: &scene.state)
        scene.engine.tick(dt: 1 / 60, state: &scene.state)
        XCTAssertEqual(scene.state.object("1")?.alpha, 1)
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
        ], configure: { configuration in
            configuration.destroyLayer = { _, _ in true }
        })
        scene.engine.start(state: &scene.state)
        scene.engine.tick(dt: 0.01, state: &scene.state)
        XCTAssertEqual(scene.state.object("1")?.color, SIMD3(3, 2, -1))
        XCTAssertEqual(scene.state.object("1")?.brightness, 1)
        XCTAssertEqual(scene.state.object("3")?.alpha, 2)
        XCTAssertEqual(scene.engine.destroyedObjectIDs, ["2"])
        scene.engine.tick(dt: 0.01, state: &scene.state)
        XCTAssertEqual(scene.state.object("3")?.alpha, 2)
    }

    /// A JS-only facade cannot count as a created product layer: resources/state must be provided synchronously.
    func testCreateLayerRequiresAProductTransaction() throws {
        var scene = try Self.scene([
            Self.layer(1, "A", ["alpha": Self.scripted(1, """
            export function init(value) {
                thisLayer.brightness = thisScene.createLayer({ image: 'models/x.json', name: 'x' }) === null ? 7 : 9;
                return thisScene.getLayerCount();
            }
            """)]),
            Self.layer(2, "B"),
        ])
        scene.engine.start(state: &scene.state)
        XCTAssertEqual(scene.state.object("1")?.brightness, 7)
        XCTAssertEqual(scene.state.object("1")?.alpha, 2)
        XCTAssertTrue(scene.engine.createdLayers.isEmpty)
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

    /// Independent expectations are the 16 Windows inputs paired across init/update in return-coercion.md.
    func testNativeTypedReturnProtocolAcrossInitAndUpdate() throws {
        typealias Value = WPEParitySceneState.ScriptValue
        let one = Value.vector(SIMD4(1, 0, 0, 0)), white = Value.vector(SIMD4(1, 1, 1, 0))
        let inputs: [(String, Any, String, Value)] = [
            ("visible", true, "'false'", one), ("visible", true, "0", one),
            ("alpha", 1, "'audit-nonnumeric'", one), ("alpha", 1, "true", one),
            ("alpha", 1, "({valueOf(){thisLayer.brightness=99;throw Error('unexpected valueOf');}})", one),
            ("alpha", 1, "null", one), ("alpha", 1, "'0.375'", one), ("alpha", 1, "undefined", one),
            ("alpha", 1, "({valueOf(){thisLayer.brightness=99;return 0.625;}})", one),
            ("sortorder", 0, "3.75", .integer(3)),
            ("name", "driver", "null", .string("driver")), ("name", "driver", "17", .string("17")),
            ("color", "1 1 1", "({x:0.25,y:0.5})", white), ("color", "1 1 1", "null", white),
            ("color", "1 1 1", "({x:0.25,y:0.5,z:0.75})", .vector(SIMD4(0.25, 0.5, 0.75, 0))),
            ("color", "1 1 1", "0.25", .vector(SIMD4(0.25, 0.25, 0.25, 0))),
        ]
        var objects: [[String: Any]] = []
        for event in ["init", "update"] {
            for (name, seed, expression, _) in inputs {
                let id = objects.count + 1
                objects.append(Self.layer(id, "driver", [name: Self.scripted(seed,
                                                                             "export function \(event)(value) { return \(expression); }")]))
            }
        }
        var scene = try Self.scene(objects)
        scene.engine.start(state: &scene.state)
        scene.engine.tick(dt: 0.01, state: &scene.state)
        let descriptors = WPEParityScriptProperty.base + [WPEParityScriptProperty.visible] + WPEParityScriptProperty.image
        for index in objects.indices {
            let (name, _, expression, expected) = inputs[index % inputs.count]
            let descriptor = try XCTUnwrap(descriptors.first { $0.name == name })
            XCTAssertEqual(descriptor.read(objectID: String(index + 1), from: scene.state), expected,
                           "\(index < inputs.count ? "init" : "update") \(name) <- \(expression)")
            XCTAssertEqual(scene.state.object(String(index + 1))?.brightness, 1, "valueOf must not run")
        }
        XCTAssertEqual(scene.engine.exceptionCount, 0, scene.engine.exceptions.joined(separator: "\n"))
    }

    func testDirectWritesInt32AndByteBoolUseNativeTypes() throws {
        var scene = try Self.scene([
            Self.layer(1, "A", ["sortorder": 16_777_217, "alpha": Self.scripted(1, """
            export function init(value) {
                thisLayer.brightness = thisLayer.sortorder === 16777217 ? 1 : 99;
                thisLayer.alpha = '0.25';
                thisLayer.color = {x:0.25,y:0.5};
                const video = thisLayer.getVideoTexture();
                const before = video.loop;
                video.loop = 0;
                thisLayer.origin = new Vec3(typeof before === 'number' ? 1 : 99, before, video.loop);
                video.loop = false;
                return value;
            }
            export function update(value) {
                thisLayer.sortorder = 2147483647;
                return thisLayer.sortorder === 2147483647 ? value : 99;
            }
            """)]),
        ], configure: { configuration in
            configuration.fieldDefaults[.init(objectID: "1", name: "video.loop")] = .vector(SIMD4(1, 0, 0, 0))
        })
        scene.engine.start(state: &scene.state)
        XCTAssertEqual(scene.state.scriptField("sortorder", of: "1"), .integer(16_777_217))
        XCTAssertEqual(scene.state.object("1")?.brightness, 1)
        XCTAssertEqual(scene.state.object("1")?.color, .one)
        XCTAssertEqual(scene.state.object("1")?.origin, SIMD3(1, 1, 1))
        XCTAssertEqual(scene.state.scriptField("video.loop", of: "1"), .vector(.zero))
        scene.engine.tick(dt: 0.01, state: &scene.state)
        XCTAssertEqual(scene.state.scriptField("sortorder", of: "1"), .integer(Int32.max))
        XCTAssertEqual(scene.state.object("1")?.alpha, 1)
    }

    /// T03/T05b/T06b/T09b/T11/T12b: bounded timers, no callback-internal cancellation or Windows crash policy.
    func testPerScriptTimerSnapshotsCancellationAndEventExceptionMask() throws {
        var scene = try Self.scene([
            Self.layer(1, "timers", ["alpha": Self.scripted(1, """
            let scope = 0, depth = 0, clearWitness = 0, intervals = 0;
            const surface = typeof engine.clearInterval === 'undefined' && typeof globalThis.setTimeout === 'undefined'
                && typeof globalThis.setInterval === 'undefined' && typeof globalThis.clearTimeout === 'undefined'
                && typeof globalThis.clearInterval === 'undefined';
            try { engine.setTimeout(() => {}, 0); } catch(e) { if (e instanceof SyntaxError) scope += 1; }
            try { engine.setInterval(() => {}, 1); } catch(e) { if (e instanceof SyntaxError) scope += 1; }
            export function init() {
                const cancel = engine.setTimeout(() => { thisLayer.brightness = 99; }, 250);
                const first = cancel(), second = cancel();
                const survivor = engine.setTimeout(() => { clearWitness += 1; }, 10);
                const cleared = engine.clearTimeout(survivor);
                thisLayer.color = new Vec3(first === true ? 1 : 99, second === false ? 1 : 99, cleared === false ? 1 : 99);
                engine.setTimeout(() => { depth = 1; engine.setTimeout(() => { depth = 2; }, 0); }, 0);
                engine.setInterval(() => { intervals += 1; if (intervals === 1) throw Error('expected timer'); }, 50);
                engine.setInterval(() => { thisLayer.brightness = 99; }, 0);
                engine.setInterval(() => { thisLayer.brightness = 99; }, -1);
            }
            export function update() {
                thisLayer.origin = new Vec3(surface ? scope : 99, clearWitness, intervals);
                return depth;
            }
            """)]),
            Self.layer(2, "throwing", ["alpha": Self.scripted(1, """
            let calls = 0;
            export function init() { engine.setTimeout(() => { thisLayer.brightness = 7; }, 15); throw Error('expected init'); }
            export function update() { calls += 1; thisLayer.alpha = calls; throw Error('expected update'); }
            """)]),
        ])
        scene.engine.start(state: &scene.state)
        scene.engine.tick(dt: 0.01, state: &scene.state)
        XCTAssertEqual(scene.state.object("1")?.alpha, 1, "new child waits for the next sweep of its script")
        XCTAssertEqual(scene.state.object("1")?.color, .one)
        XCTAssertEqual(scene.state.object("1")?.origin, SIMD3(2, 1, 0))
        scene.engine.tick(dt: 0.01, state: &scene.state)
        XCTAssertEqual(scene.state.object("1")?.alpha, 2)
        XCTAssertEqual(scene.state.object("2")?.brightness, 7, "a masked update retains its previously scheduled timers")
        scene.engine.tick(dt: 0.2, state: &scene.state)
        XCTAssertEqual(scene.state.object("1")?.origin.z, 1, "one interval call per sweep, without catchup")
        scene.engine.tick(dt: 0.2, state: &scene.state)
        XCTAssertEqual(scene.state.object("1")?.origin.z, 2, "timer exceptions do not mask the timer or update event")
        XCTAssertEqual(scene.state.object("1")?.brightness, 1, "cancelled and nonpositive interval bodies stay silent")
        XCTAssertEqual(scene.state.object("2")?.alpha, 1, "update exception masks only that binding's update event")
        XCTAssertEqual(scene.engine.exceptionCount, 3)
    }

    func testStoragePhaseStrictKeysScopeAndSerializedIsolation() throws {
        var scene = try Self.scene([
            Self.layer(1, "storage", ["alpha": Self.scripted(1, """
            let phase = false;
            try { localStorage.set('module-key', 1); } catch(e) { phase = true; }
            export function init() {
                const value = {nested: {number: 1}};
                localStorage.set('key', value);
                value.nested.number = 99;
                const first = localStorage.get('key');
                first.nested.number = 88;
                localStorage.set('key', {nested:{number: 2}}, localStorage.LOCATION_GLOBAL);
                let strict = false;
                try { localStorage.get({toString(){throw Error('must not coerce');}}); } catch(e) { strict = true; }
                thisLayer.color = new Vec3(localStorage.get('key', 'other').nested.number,
                    localStorage.get('key', 'global').nested.number, localStorage.get('key', 0).nested.number);
                thisLayer.origin = new Vec3(phase ? 1 : 99, strict ? 1 : 99,
                    localStorage.LOCATION_GLOBAL === 'global' && localStorage.LOCATION_SCREEN === 'screen' ? 1 : 99);
                thisLayer.brightness = localStorage.delete('key') === true && localStorage.delete('key') === false
                    && localStorage.clear('global') === true ? 7 : 99;
            }
            """)]),
        ])
        scene.engine.start(state: &scene.state)
        XCTAssertEqual(scene.state.object("1")?.color, SIMD3(1, 2, 1))
        XCTAssertEqual(scene.state.object("1")?.origin, .one)
        XCTAssertEqual(scene.state.object("1")?.brightness, 7)
        XCTAssertEqual(scene.engine.exceptionCount, 0)
    }

    func testMaterialDefaultsWrapperIdentityReadOnlyAndAngleBranches() throws {
        let pass = WPEParityMaterialPassKey(objectID: "1", effectID: "5")
        var scene = try Self.scene([
            Self.layer(1, "A", [
                "angles": Self.scripted("0 0 0", "export function update() { return 90; }"),
                "alpha": Self.scripted(1, """
                export function init() {
                    const descriptor = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(thisLayer), 'brightness');
                    thisLayer.origin = new Vec3(descriptor.set === undefined ? 1 : 99,
                        thisLayer.getEffect(0) === thisLayer.getEffect('effect') ? 1 : 99,
                        thisLayer.getVideoTexture() === thisLayer.getVideoTexture() ? 1 : 99);
                }
                """),
                "effects": [["id": 5, "name": "effect", "file": "effects/x.json",
                             "visible": Self.scripted(true, """
                             export function init(value) {
                                 thisLayer.color = new Vec3(thisObject === thisLayer.getEffect(0) ? 1 : 99,
                                     thisObject !== thisLayer ? 1 : 99, thisObject.getMaterialCount());
                                 return value;
                             }
                             """), "passes": [["constantshadervalues": [
                                 "v2": Self.scripted("0 0", """
                                 export function init() { shared.material = thisObject; return new Vec2(90, 180); }
                                 """),
                                 "v4": Self.scripted("0 0 0 0", """
                                 export function init() {
                                     thisLayer.alpha = thisObject === shared.material && thisObject.extra === 7 ? 0.5 : 99;
                                     thisObject.extra = 8;
                                     return new Vec4(90, 180, 270, 360);
                                 }
                                 """),
                             ]]]]],
            ]),
        ], constants: [pass: ["v2": [0, 0], "v4": [0, 0, 0, 0], "extra": [7]]],
        configure: { configuration in
            configuration.materialConstants = [
                .init(pass: pass, name: "v2"): .init(value: .zero, components: 2, angle: true),
                .init(pass: pass, name: "v4"): .init(value: .zero, components: 4, angle: true),
                .init(pass: pass, name: "extra"): .init(value: SIMD4(7, 0, 0, 0), components: 1),
            ]
            configuration.propertyOverrides = [WPEParityScriptProperty(name: "brightness", owner: .image,
                                                                       type: .float, flags: .notFromJSON, target: .object(.brightness))]
        })
        scene.engine.start(state: &scene.state)
        XCTAssertEqual(scene.state.object("1")?.origin, .one)
        XCTAssertEqual(scene.state.object("1")?.color, .one)
        XCTAssertEqual(scene.state.object("1")?.alpha, 0.5)
        XCTAssertEqual(scene.state.constant("extra", of: pass)?.value.x, 8)
        XCTAssertEqual(scene.state.constant("v2", of: pass)?.value, SIMD4(90, 180, 0, 0))
        XCTAssertEqual(scene.state.constant("v4", of: pass)?.value, SIMD4(90, 180, 270, 360))
        scene.engine.tick(dt: 0.01, state: &scene.state)
        XCTAssertEqual(scene.state.object("1")?.angles, SIMD3(90, 90, 90), "scalar vec3 angle branch skips conversion")
        XCTAssertEqual(scene.engine.exceptionCount, 0, scene.engine.exceptions.joined(separator: "\n"))
    }

    func testGeneralLowercaseWrapperFieldMirrorAndAnimationTypedReturn() throws {
        var scene = try Self.scene([
            Self.layer(1, "A", ["alpha": Self.scripted(1, """
            export function animationEvent(event, value) {
                thisLayer.brightness = event.factor;
                return value * event.factor;
            }
            """)]),
        ], general: ["bloomstrength": Self.scripted(1, """
        export function init(value) {
            const layer = thisScene.getLayer(0);
            layer.origin = new Vec3(thisObject === thisLayer ? 1 : 99,
                thisObject !== thisScene ? 1 : 99, typeof thisScene.bloomStrength === 'undefined' ? 1 : 99);
            return value;
        }
        export function applyUserProperties() { thisScene.getLayer(0).alpha = thisObject.bloomstrength; }
        """)])
        scene.engine.start(state: &scene.state)
        XCTAssertEqual(scene.state.object("1")?.origin, .one)
        scene.state.setScriptField("bloomstrength", of: "", to: .vector(SIMD4(0.75, 0, 0, 0)), invalidating: .bloom)
        scene.engine.applyUserProperties(changedJSON: "{}", mergedJSON: "{}", state: &scene.state)
        XCTAssertEqual(scene.state.object("1")?.alpha, 0.75)
        scene.engine.dispatch(.animationEvent, payloadJSON: "{\"factor\":0.5}", target: "1", state: &scene.state)
        XCTAssertEqual(scene.state.object("1")?.alpha, 0.375)
        XCTAssertEqual(scene.state.object("1")?.brightness, 0.5)
        XCTAssertEqual(scene.engine.exceptionCount, 0, scene.engine.exceptions.joined(separator: "\n"))
    }

    /// H04 reads the real native defaults, including padding32 and the font identifier missing from the old slots.
    func testNativeTextDefaultsAndStringFieldMirror() throws {
        var scene = try Self.scene([
            ["id": 1, "name": "Text", "text": "Audit", "alpha": Self.scripted(1, """
            export function init() {
                thisLayer.color = new Vec3(thisLayer.pointsize, thisLayer.padding.x, thisLayer.padding.y);
                thisLayer.origin = new Vec3(thisLayer.maxwidth, thisLayer.maxrows, thisLayer.spacing.x);
                thisLayer.brightness = thisLayer.font === 'systemfont_arial' ? 7 : 99;
            }
            export function update() { return thisLayer.text.length; }
            """)],
        ])
        scene.engine.start(state: &scene.state)
        XCTAssertEqual(scene.state.object("1")?.color, SIMD3(32, 32, 32))
        XCTAssertEqual(scene.state.object("1")?.origin, SIMD3(500, 1, 0))
        XCTAssertEqual(scene.state.object("1")?.brightness, 7)
        scene.state.setScriptField("text", of: "1", to: .string("next"), invalidating: .textLayout)
        scene.engine.tick(dt: 0.01, state: &scene.state)
        XCTAssertEqual(scene.state.object("1")?.alpha, 4)
        XCTAssertEqual(scene.engine.exceptionCount, 0, scene.engine.exceptions.joined(separator: "\n"))
    }

    func testParticleMetadataKeepsAuthoredColorAndUnspecifiedControlPointSentinel() throws {
        var scene = try Self.scene([
            ["id": 1, "name": "particles", "particle": "particles/probe.json", "instanceoverride": [
                "color": "255 0 0", "controlpoint0": "2 3 4", "alpha": Self.scripted(1, """
                export function init(value) {
                    const witness = thisScene.getLayer('witness');
                    witness.color = thisObject.colorn;
                    witness.origin = thisObject.controlpoint0;
                    witness.brightness = thisObject.controlpoint1.x === 3.4028234663852886e38 ? 7 : 99;
                    return value;
                }
                """),
            ]],
            Self.layer(2, "witness"),
        ])
        scene.engine.start(state: &scene.state)
        XCTAssertEqual(scene.state.object("2")?.color, SIMD3(1, 0, 0))
        XCTAssertEqual(scene.state.object("2")?.origin, SIMD3(2, 3, 4))
        XCTAssertEqual(scene.state.object("2")?.brightness, 7)
        XCTAssertEqual(scene.state.scriptField("instance.controlpoint1", of: "1"),
                       .vector(SIMD4(Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude,
                                     Float.greatestFiniteMagnitude, 0)))
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
