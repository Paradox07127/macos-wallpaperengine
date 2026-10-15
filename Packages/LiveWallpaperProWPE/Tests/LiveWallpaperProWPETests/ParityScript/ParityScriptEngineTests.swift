import Foundation
import LiveWallpaperCore
@testable import LiveWallpaperProWPE
import XCTest

final class ParityScriptEngineTests: XCTestCase {
    func testCameraShakeStrictTypedBindingsAndAcceptedDocumentDeltasHaveNoHooks() throws {
        let names = ["camerashake", "camerashakespeed", "camerashakeamplitude", "camerashakeroughness"]
        let invalidSeeds: [Any] = [1, "3", false, ["value": 1]]
        func document(_ seeds: [Any], visible: Bool = true, scripted: Bool = true) throws -> WPESceneDocument {
            var general: [String: Any] = ["orthogonalprojection": ["width": 32, "height": 32]]
            for (index, name) in names.enumerated() {
                let script = index == 0 ? """
                export function init(v) {
                  if (typeof v !== 'boolean') throw new Error('Shake Bool type');
                  thisScene.camerashake = 1;
                  if (thisScene.camerashake !== v) throw new Error('Shake rejected Bool write');
                  thisScene.camerashake = !v;
                  if (thisScene.camerashake !== !v) throw new Error('Shake Bool setter');
                  return !v;
                }
                export function update(v) { return !v; }
                """ : """
                export function init(v) {
                  if (typeof v !== 'number') throw new Error('Shake Float type');
                  thisScene.\(name) = '11';
                  if (thisScene.\(name) !== Math.fround(v)) throw new Error('Shake rejected Float write');
                  thisScene.\(name) = v + 0.25;
                  if (thisScene.\(name) !== Math.fround(v + 0.25)) throw new Error('Shake Float setter');
                  return v + 0.5;
                }
                export function update(v) { return v * 2 + 0.125; }
                """
                general[name] = scripted ? ["value": seeds[index], "script": script]
                    : ["value": seeds[index], "user": "shake\(index)"]
            }
            return try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: [
                "camera": ["eye": "0 0 0", "center": "0 0 -1", "up": "0 1 0"], "general": general,
                "objects": [["id": 1, "image": "models/surface.json", "visible": visible]],
            ]), userValues: [:], makeTransformScriptResolver: { _, _ in NoScripts() })
        }
        let before = try document(invalidSeeds)
        XCTAssertNil(WPEParityScriptProperty.sceneBoolValue(fromJSON: before.resolvedGeneralJSON[names[0]]))
        for name in names.dropFirst() {
            XCTAssertNil(WPEParityScriptProperty.sceneFloatValue(fromJSON: before.resolvedGeneralJSON[name]))
        }
        var state = WPEParitySceneState(document: before, hdr: false)
        let untrusted: [WPEParitySceneState.ScriptFieldKey: WPEParitySceneState.ScriptValue] =
            Dictionary(uniqueKeysWithValues: names.map { (.init(objectID: "", name: $0), .vector(SIMD4(999, 0, 0, 0))) })
        let engine = try WPEParityScriptEngine.prepare(document: before, state: &state, configuration: .init(
            assets: Self.fixedAssets(), canvasSize: SIMD2(32, 32), screenResolution: SIMD2(32, 32), fieldDefaults: untrusted
        ), volume: { _, _ in XCTFail("No sound object") }, command: { _, _, _ in false })
        XCTAssertEqual(Set(engine.bindings.map(\.path)), Set(names))
        XCTAssertEqual(engine.bindings.count, 4)
        XCTAssertTrue(engine.bindings.allSatisfy(\.compiled))
        let defaults: [Float] = [0, 3, 0.5, 1]
        for (name, value) in zip(names, defaults) {
            XCTAssertEqual(state.scriptField(name, of: ""), .vector(SIMD4(value, 0, 0, 0)))
        }
        let bloomGeneration = state.generation(.bloom)
        let transformGeneration = state.generation(.transform)
        XCTAssertNil(engine.start(state: &state))
        XCTAssertEqual(state.scriptField(names[0], of: ""), .vector(SIMD4(1, 0, 0, 0)))
        for (name, value) in zip(names.dropFirst(), defaults.dropFirst()) {
            XCTAssertEqual(state.scriptField(name, of: ""), .vector(SIMD4(value + 0.5, 0, 0, 0)))
        }
        let validSeeds: [Any] = [false, 0.25, -0.5, 2]
        let values: [Float] = [0.25, -0.5, 2]
        let changed = try document(validSeeds)
        let accepted = try XCTUnwrap(WPEParityUserPropertyUpdate(from: before, to: changed))
        XCTAssertEqual(accepted.sceneShakeEnabled, false, "Accepted false must replace the current true")
        XCTAssertEqual(accepted.sceneShakeFloats.map(\.name), Array(names.dropFirst()))
        accepted.apply(to: &state)
        XCTAssertEqual(state.scriptField(names[0], of: ""), .vector(.zero))
        for (name, value) in zip(names.dropFirst(), values) {
            XCTAssertEqual(state.scriptField(name, of: ""), .vector(SIMD4(value, 0, 0, 0)))
        }
        engine.tick(dt: 0.125, state: &state)
        let scriptGeneration = state.scriptFieldsGeneration
        let unrelated = try document(validSeeds, visible: false)
        let invalid = try document(invalidSeeds, visible: false)
        for next in [changed, unrelated, invalid] {
            let preserved = try XCTUnwrap(WPEParityUserPropertyUpdate(from: changed, to: next))
            XCTAssertNil(preserved.sceneShakeEnabled)
            XCTAssertTrue(preserved.sceneShakeFloats.isEmpty)
            preserved.apply(to: &state)
            XCTAssertEqual(state.scriptField(names[0], of: ""), .vector(SIMD4(1, 0, 0, 0)))
            for (name, value) in zip(names.dropFirst(), values) {
                XCTAssertEqual(state.scriptField(name, of: ""), .vector(SIMD4(value * 2 + 0.125, 0, 0, 0)))
            }
            XCTAssertEqual(state.scriptFieldsGeneration, scriptGeneration)
        }
        XCTAssertEqual(state.object("1")?.visible, false)
        let recovered = try XCTUnwrap(WPEParityUserPropertyUpdate(from: invalid, to: unrelated))
        XCTAssertEqual(recovered.sceneShakeEnabled, false)
        XCTAssertEqual(recovered.sceneShakeFloats.count, 3)
        recovered.apply(to: &state)
        for (name, value) in zip(names, [Float(0)] + values) {
            XCTAssertEqual(state.scriptField(name, of: ""), .vector(SIMD4(value, 0, 0, 0)))
        }
        let bindings = try WPEParityUserProperties.bindings(document: document(validSeeds, scripted: false))
        for index in names.indices {
            XCTAssertEqual(bindings["shake\(index)"]?.first?.action, .incremental)
        }
        XCTAssertEqual(state.generation(.bloom), bloomGeneration, "These descriptors have no hook")
        XCTAssertEqual(state.generation(.transform), transformGeneration)
        XCTAssertEqual(engine.exceptionCount, 0, engine.exceptions.joined(separator: "\n"))
    }

    func testCameraParallaxStrictBindingsAndDocumentDeltasPreserveCanonicalFieldsWithoutHooks() throws {
        let names = ["cameraparallax", "cameraparallaxamount", "cameraparallaxdelay", "cameraparallaxmouseinfluence"]
        let invalidSeeds: [Any] = [1, false, "0.1", ["value": 0.5]]
        func document(_ seeds: [Any], visible: Bool = true) throws -> WPESceneDocument {
            var general: [String: Any] = ["orthogonalprojection": ["width": 32, "height": 32]]
            for (index, name) in names.enumerated() {
                let script = index == 0 ? """
                export function init(v) {
                  if (typeof v !== 'boolean') throw new Error('Parallax Bool type');
                  thisScene.cameraparallax = !v;
                  if (thisScene.cameraparallax !== !v) throw new Error('Parallax Bool setter');
                  return !v;
                }
                export function update(v) { return !v; }
                """ : """
                export function init(v) {
                  if (typeof v !== 'number') throw new Error('Parallax Float type');
                  thisScene.\(name) = v + 1;
                  if (thisScene.\(name) !== Math.fround(v + 1)) throw new Error('Parallax Float setter');
                  return v + 2;
                }
                export function update(v) { return Math.fround(v + 1); }
                """
                general[name] = ["value": seeds[index], "script": script]
            }
            let source: [String: Any] = [
                "camera": ["eye": "0 0 0", "center": "0 0 -1", "up": "0 1 0"], "general": general,
                "objects": [["id": 1, "image": "models/surface.json", "visible": visible]],
            ]
            return try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: source), userValues: [:],
                                                    makeTransformScriptResolver: { _, _ in NoScripts() })
        }
        let before = try document(invalidSeeds)
        XCTAssertNil(WPEParityScriptProperty.sceneBoolValue(fromJSON: before.resolvedGeneralJSON[names[0]]))
        for name in names.dropFirst() {
            XCTAssertNil(WPEParityScriptProperty.sceneFloatValue(fromJSON: before.resolvedGeneralJSON[name]))
        }
        var state = WPEParitySceneState(document: before, hdr: false)
        let untrusted: [WPEParitySceneState.ScriptFieldKey: WPEParitySceneState.ScriptValue] =
            Dictionary(uniqueKeysWithValues: names.map { (.init(objectID: "", name: $0), .vector(SIMD4(999, 0, 0, 0))) })
        let engine = try WPEParityScriptEngine.prepare(document: before, state: &state, configuration: .init(
            assets: Self.fixedAssets(), canvasSize: SIMD2(32, 32), screenResolution: SIMD2(32, 32), fieldDefaults: untrusted
        ), volume: { _, _ in XCTFail("No sound object") }, command: { _, _, _ in false })
        XCTAssertEqual(engine.bindings.map(\.path), names)
        XCTAssertTrue(engine.bindings.allSatisfy(\.compiled))
        let defaults: [Float] = [0, 0.5, Float(bitPattern: 0x3DCC_CCCD), 0.5]
        for (name, value) in zip(names, defaults) {
            XCTAssertEqual(state.scriptField(name, of: ""), .vector(SIMD4(value, 0, 0, 0)))
        }
        let bloomGeneration = state.generation(.bloom)
        let transformGeneration = state.generation(.transform)
        XCTAssertNil(engine.start(state: &state))
        XCTAssertEqual(state.scriptField(names[0], of: ""), .vector(SIMD4(1, 0, 0, 0)))
        for (name, value) in zip(names.dropFirst(), defaults.dropFirst()) {
            XCTAssertEqual(state.scriptField(name, of: ""), .vector(SIMD4(value + 2, 0, 0, 0)))
        }

        // A valid false must replace a current true; it cannot be mistaken for an absent accepted write.
        let validSeeds: [Any] = [false, -0.25, 0.75, 1.5]
        let values: [Float] = [-0.25, 0.75, 1.5]
        let changed = try document(validSeeds)
        let accepted = try XCTUnwrap(WPEParityUserPropertyUpdate(from: before, to: changed))
        XCTAssertEqual(accepted.sceneParallaxEnabled, false)
        XCTAssertEqual(accepted.sceneParallaxFloats.map(\.name), Array(names.dropFirst()))
        accepted.apply(to: &state)
        XCTAssertEqual(state.scriptField(names[0], of: ""), .vector(.zero))
        for (name, value) in zip(names.dropFirst(), values) {
            XCTAssertEqual(state.scriptField(name, of: ""), .vector(SIMD4(value, 0, 0, 0)))
        }
        engine.tick(dt: 0, state: &state)
        let scriptGeneration = state.scriptFieldsGeneration
        let unrelated = try document(validSeeds, visible: false)
        let invalid = try document(invalidSeeds, visible: false)
        for next in [changed, unrelated, invalid] {
            let preserved = try XCTUnwrap(WPEParityUserPropertyUpdate(from: changed, to: next))
            XCTAssertNil(preserved.sceneParallaxEnabled)
            XCTAssertTrue(preserved.sceneParallaxFloats.isEmpty)
            preserved.apply(to: &state)
            XCTAssertEqual(state.scriptField(names[0], of: ""), .vector(SIMD4(1, 0, 0, 0)))
            for (name, value) in zip(names.dropFirst(), values) {
                XCTAssertEqual(state.scriptField(name, of: ""), .vector(SIMD4(value + 1, 0, 0, 0)))
            }
            XCTAssertEqual(state.scriptFieldsGeneration, scriptGeneration)
        }
        XCTAssertEqual(state.object("1")?.visible, false)
        let recovered = try XCTUnwrap(WPEParityUserPropertyUpdate(from: invalid, to: unrelated))
        XCTAssertEqual(recovered.sceneParallaxEnabled, false)
        XCTAssertEqual(recovered.sceneParallaxFloats.count, 3)
        recovered.apply(to: &state)
        XCTAssertEqual(state.scriptField(names[0], of: ""), .vector(.zero))
        for (name, value) in zip(names.dropFirst(), values) {
            XCTAssertEqual(state.scriptField(name, of: ""), .vector(SIMD4(value, 0, 0, 0)))
        }
        XCTAssertEqual(state.generation(.bloom), bloomGeneration, "These descriptors have no hook")
        XCTAssertEqual(state.generation(.transform), transformGeneration)
        XCTAssertEqual(engine.exceptionCount, 0, engine.exceptions.joined(separator: "\n"))
    }

    func testBloomTintAndIterationsBindingsAndDocumentDeltasReachCanonicalState() throws {
        let iterationScript = """
        export function init(v) {
          if (typeof v !== 'number') throw new Error('Bloom Int binding type');
          thisScene.bloomhdriterations = v + 1;
          if (thisScene.bloomhdriterations !== v + 1) throw new Error('Bloom Int setter');
          return v + 2;
        }
        export function update(v) { return v + 1; }
        """
        let tintScript = """
        export function init(v) {
          if (typeof v.x !== 'number' || typeof v.y !== 'number' || typeof v.z !== 'number')
            throw new Error('Bloom Vec3 binding type');
          thisScene.bloomtint = new Vec3(v.x + 1, v.y + 1, v.z + 1);
          if (thisScene.bloomtint.x !== v.x + 1 || thisScene.bloomtint.y !== v.y + 1 ||
              thisScene.bloomtint.z !== v.z + 1) throw new Error('Bloom Vec3 setter');
          return new Vec3(v.x + 2, v.y + 2, v.z + 2);
        }
        export function update(v) { return new Vec3(v.x + 1, v.y + 1, v.z + 1); }
        """
        let encodedIteration = try XCTUnwrap(String(data: JSONEncoder().encode(iterationScript), encoding: .utf8))
        let encodedTint = try XCTUnwrap(String(data: JSONEncoder().encode(tintScript), encoding: .utf8))
        func document(_ iterations: String, _ tint: String, alpha: Double = 1) throws -> WPESceneDocument {
            // Raw literals retain the explicit real-token witness `1e100`; native integer-tag extremes are not asserted.
            let source = """
            {"camera":{"eye":"0 0 0","center":"0 0 -1","up":"0 1 0"},
             "general":{"orthogonalprojection":{"width":32,"height":32},
               "bloomhdriterations":{"value":\(iterations),"script":\(encodedIteration)},
               "bloomtint":{"value":\(tint),"script":\(encodedTint)}},
             "objects":[{"id":1,"image":"models/surface.json","alpha":\(alpha)}]}
            """
            return try WPESceneDocumentParser.parse(data: Data(source.utf8), userValues: [:],
                                                    makeTransformScriptResolver: { _, _ in NoScripts() })
        }
        let assets = try Self.fixedAssets()
        let untrusted: [WPEParitySceneState.ScriptFieldKey: WPEParitySceneState.ScriptValue] = [
            .init(objectID: "", name: "bloomhdriterations"): .integer(999),
            .init(objectID: "", name: "bloomtint"): .vector(SIMD4(repeating: 999)),
        ]
        let seeds: [(iterations: String, tint: String, expectedInt: Int32, expectedTint: SIMD3<Float>)] = [
            ("false", "false", 8, SIMD3(repeating: 1)),
            ("\"12\"", "[1,2,3]", 8, SIMD3(repeating: 1)),
            (#"{"value":3}"#, #"{"value":"1 2 3"}"#, 8, SIMD3(repeating: 1)),
            ("3.9", "0.25", 3, SIMD3(repeating: 0.25)),
            ("-3.9", "\"0.25 0.5\"", -3, SIMD3(0.25, 0.5, 0)),
            ("0", "\"\"", 0, .zero),
            ("1e100", "1", Int32.min, SIMD3(repeating: 1)),
        ]
        for seed in seeds {
            let parsed = try document(seed.iterations, seed.tint)
            var state = WPEParitySceneState(document: parsed, hdr: true)
            let engine = try WPEParityScriptEngine.prepare(document: parsed, state: &state, configuration: .init(
                assets: assets, canvasSize: SIMD2(32, 32), screenResolution: SIMD2(32, 32), fieldDefaults: untrusted
            ), volume: { _, _ in XCTFail("No sound object") }, command: { _, _, _ in false })
            XCTAssertEqual(engine.bindings.map(\.path), ["bloomhdriterations", "bloomtint"])
            XCTAssertTrue(engine.bindings.allSatisfy(\.compiled))
            XCTAssertEqual(state.scriptField("bloomhdriterations", of: ""), .integer(seed.expectedInt))
            XCTAssertEqual(state.scriptField("bloomtint", of: ""), .vector(SIMD4(seed.expectedTint, 0)))
            XCTAssertNil(engine.start(state: &state))
            XCTAssertEqual(state.scriptField("bloomhdriterations", of: ""), .integer(seed.expectedInt + 2))
            XCTAssertEqual(state.scriptField("bloomtint", of: ""), .vector(SIMD4(seed.expectedTint + SIMD3(repeating: 2), 0)))
            XCTAssertEqual(engine.exceptionCount, 0, engine.exceptions.joined(separator: "\n"))
        }

        let before = try document("false", "false")
        var state = WPEParitySceneState(document: before, hdr: true)
        let engine = try WPEParityScriptEngine.prepare(document: before, state: &state, configuration: .init(
            assets: assets, canvasSize: SIMD2(32, 32), screenResolution: SIMD2(32, 32)
        ), volume: { _, _ in XCTFail("No sound object") }, command: { _, _, _ in false })
        XCTAssertNil(engine.start(state: &state))
        let changed = try document("4.9", "\"0.25 0.5 0.75\"")
        let accepted = try XCTUnwrap(WPEParityUserPropertyUpdate(from: before, to: changed))
        XCTAssertEqual(accepted.sceneBloomIterations, 4)
        XCTAssertEqual(accepted.sceneBloomTint, SIMD3(0.25, 0.5, 0.75))
        let initialGeneration = state.generation(.bloom)
        accepted.apply(to: &state)
        XCTAssertGreaterThan(state.generation(.bloom), initialGeneration)
        XCTAssertEqual(state.scriptField("bloomhdriterations", of: ""), .integer(4))
        XCTAssertEqual(state.scriptField("bloomtint", of: ""), .vector(SIMD4(0.25, 0.5, 0.75, 0)))
        engine.tick(dt: 0, state: &state)
        let scriptGeneration = state.generation(.bloom)
        let unchangedSeed = try document("4.1", "\"0.25 0.5 0.75\"", alpha: 0.25)
        let invalidSeed = try document("\"6\"", "[0,0,0]", alpha: 0.25)
        for newDocument in [unchangedSeed, invalidSeed] {
            let preserved = try XCTUnwrap(WPEParityUserPropertyUpdate(from: changed, to: newDocument))
            XCTAssertNil(preserved.sceneBloomIterations)
            XCTAssertNil(preserved.sceneBloomTint)
            preserved.apply(to: &state)
            XCTAssertEqual(state.scriptField("bloomhdriterations", of: ""), .integer(5))
            XCTAssertEqual(state.scriptField("bloomtint", of: ""), .vector(SIMD4(1.25, 1.5, 1.75, 0)))
            XCTAssertEqual(state.generation(.bloom), scriptGeneration)
            XCTAssertEqual(state.object("1")?.alpha, 0.25)
        }
        let recovered = try XCTUnwrap(WPEParityUserPropertyUpdate(from: invalidSeed, to: unchangedSeed))
        XCTAssertEqual(recovered.sceneBloomIterations, 4)
        XCTAssertEqual(recovered.sceneBloomTint, SIMD3(0.25, 0.5, 0.75))
        recovered.apply(to: &state)
        XCTAssertEqual(state.scriptField("bloomhdriterations", of: ""), .integer(4))
        XCTAssertEqual(state.scriptField("bloomtint", of: ""), .vector(SIMD4(0.25, 0.5, 0.75, 0)))
        XCTAssertEqual(engine.exceptionCount, 0, engine.exceptions.joined(separator: "\n"))
    }

    func testHDRBloomFloatBindingsAndDocumentDeltasPreserveCanonicalValues() throws {
        // Existing LDR strength/threshold use the same native Float reader as these four HDR fields.
        let fields: [(name: String, bits: UInt32)] = [
            ("bloomstrength", 0x4000_0000), ("bloomthreshold", 0x3F26_6666),
            ("bloomhdrstrength", 0x4000_0000), ("bloomhdrthreshold", 0x3F80_0000),
            ("bloomhdrfeather", 0x3DCC_CCCD), ("bloomhdrscatter", 0x3FCF_3B64),
        ]
        let invalidSeeds: [Any] = [["value": 0.5], ["value": 0.5], false, "0.5", ["value": 0.5], [0.5]]
        var general: [String: Any] = ["orthogonalprojection": ["width": 32, "height": 32]]
        for (field, seed) in zip(fields, invalidSeeds) {
            general[field.name] = ["value": seed, "user": field.name, "script": """
            export function init(v) {
              if (typeof v !== 'number') throw new Error('Bloom Float binding type');
              thisScene.\(field.name) = v + 10;
              return v + 20;
            }
            export function update(v) { return v + 1; }
            """]
        }
        let source = try JSONSerialization.data(withJSONObject: [
            "camera": ["eye": "0 0 0", "center": "0 0 -1", "up": "0 1 0"],
            "general": general,
            "objects": [["id": 1, "image": "models/surface.json", "alpha": ["value": 1, "user": "fade"]]],
        ])
        func document(_ values: [String: WallpaperEngineProjectPropertyValue] = [:], alpha: Double = 1) throws
            -> WPESceneDocument {
            try WPESceneDocumentParser.parse(data: source, userValues: values.merging(["fade": .number(alpha)]) { _, new in new },
                                             makeTransformScriptResolver: { _, _ in NoScripts() })
        }
        let before = try document()
        for field in fields {
            XCTAssertNil(WPEParityScriptProperty.sceneFloatValue(fromJSON: before.resolvedGeneralJSON[field.name]), field.name)
        }
        var state = WPEParitySceneState(document: before, hdr: true)
        let untrusted: [WPEParitySceneState.ScriptFieldKey: WPEParitySceneState.ScriptValue] =
            Dictionary(uniqueKeysWithValues: fields.map { (.init(objectID: "", name: $0.name), .vector(SIMD4(999, 0, 0, 0))) })
        let engine = try WPEParityScriptEngine.prepare(document: before, state: &state, configuration: .init(
            assets: Self.fixedAssets(), canvasSize: SIMD2(32, 32), screenResolution: SIMD2(32, 32), fieldDefaults: untrusted
        ), volume: { _, _ in XCTFail("No sound object") }, command: { _, _, _ in false })
        XCTAssertEqual(engine.bindings.map(\.path), fields.map(\.name))
        XCTAssertTrue(engine.bindings.allSatisfy(\.compiled))
        for field in fields {
            guard case let .vector(value)? = state.scriptField(field.name, of: "") else {
                XCTFail("Missing canonical bloom field \(field.name)"); continue
            }
            XCTAssertEqual(value.x.bitPattern, field.bits, field.name)
        }
        XCTAssertNil(engine.start(state: &state))
        for field in fields {
            XCTAssertEqual(state.scriptField(field.name, of: ""), .vector(SIMD4(Float(bitPattern: field.bits) + 20, 0, 0, 0)))
        }

        // The real document resolver replaces the invalid seeds; accepted deltas reach those same State fields.
        let values: [Float] = [-3, 4, -5, 6, -0.25, 2]
        let validUsers = Dictionary(uniqueKeysWithValues: zip(fields, values).map {
            ($0.0.name, WallpaperEngineProjectPropertyValue.number(Double($0.1)))
        })
        let changed = try document(validUsers)
        let accepted = try XCTUnwrap(WPEParityUserPropertyUpdate(from: before, to: changed))
        XCTAssertEqual(accepted.sceneBloomFloats.map(\.name), fields.map(\.name))
        let previousGeneration = state.generation(.bloom)
        accepted.apply(to: &state)
        XCTAssertGreaterThan(state.generation(.bloom), previousGeneration)
        for (field, value) in zip(fields, values) {
            XCTAssertEqual(state.scriptField(field.name, of: ""), .vector(SIMD4(value, 0, 0, 0)))
        }

        // A later script return wins over the authored seed. An unrelated alpha change cannot restore that seed.
        engine.tick(dt: 0, state: &state)
        let scriptGeneration = state.generation(.bloom)
        let faded = try document(validUsers, alpha: 0.25)
        let unrelated = try XCTUnwrap(WPEParityUserPropertyUpdate(from: changed, to: faded))
        XCTAssertTrue(unrelated.sceneBloomFloats.isEmpty)
        unrelated.apply(to: &state)
        XCTAssertEqual(state.object("1")?.alpha, 0.25)
        XCTAssertEqual(state.generation(.bloom), scriptGeneration)
        var previousDocument = faded
        for invalidValue: WallpaperEngineProjectPropertyValue in [.bool(false), .string("0.5")] {
            let invalid = try document(Dictionary(uniqueKeysWithValues: fields.map { ($0.name, invalidValue) }), alpha: 0.25)
            let rejected = try XCTUnwrap(WPEParityUserPropertyUpdate(from: previousDocument, to: invalid))
            XCTAssertTrue(rejected.sceneBloomFloats.isEmpty)
            rejected.apply(to: &state)
            XCTAssertEqual(state.generation(.bloom), scriptGeneration)
            for (field, value) in zip(fields, values) {
                XCTAssertEqual(state.scriptField(field.name, of: ""), .vector(SIMD4(value + 1, 0, 0, 0)))
            }
            previousDocument = invalid
        }
        let recovered = try XCTUnwrap(WPEParityUserPropertyUpdate(from: previousDocument, to: faded))
        XCTAssertEqual(recovered.sceneBloomFloats.count, fields.count, "Old invalid is not substituted with a constructor default")
        recovered.apply(to: &state)
        for (field, value) in zip(fields, values) {
            XCTAssertEqual(state.scriptField(field.name, of: ""), .vector(SIMD4(value, 0, 0, 0)))
        }
        XCTAssertEqual(engine.exceptionCount, 0, engine.exceptions.joined(separator: "\n"))
    }

    func testGeneralBloomStrictJSONSeedsAndBindingsReachCanonicalState() throws {
        let assets = try Self.fixedAssets()
        func document(_ general: [String: Any]) throws -> WPESceneDocument {
            var generalJSON: [String: Any] = ["orthogonalprojection": ["width": 200, "height": 100]]
            generalJSON.merge(general) { _, new in new }
            let json: [String: Any] = [
                "camera": ["eye": "0 0 0", "center": "0 0 -1", "up": "0 1 0"],
                "general": generalJSON,
                "objects": [],
            ]
            return try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: json), userValues: [:],
                                                    makeTransformScriptResolver: { _, _ in NoScripts() })
        }
        // 14019b4e0 preserves constructor mask2 for invalid seeds; only immediate JSON Bool can replace it.
        let seeds: [(String, Any?, Bool)] = [
            ("absent", nil, true), ("false", false, false), ("true", true, true),
            ("value false", ["value": false], false), ("value true", ["value": true], true),
            ("number zero", 0, true), ("number one", 1, true), ("numeric string", "0", true),
            ("string", "false", true), ("null", NSNull(), true), ("array", [false], true),
            ("value number", ["value": 0], true), ("nested value", ["value": ["value": false]], true),
        ]
        for (name, seed, expected) in seeds {
            let witness = """
            if (typeof thisScene.bloom !== 'boolean' || thisScene.bloom !== \(expected)) throw new Error('global bloom seed');
            export function init(v) {
              if (thisScene.bloom !== \(expected)) throw new Error('init bloom seed');
              return v;
            }
            """
            var general: [String: Any] = ["bloomstrength": ["value": 2, "script": witness]]
            if let seed {
                general["bloom"] = seed
            }
            let scene = try document(general)
            var state = WPEParitySceneState(document: scene, hdr: false)
            let engine = try WPEParityScriptEngine.prepare(document: scene, state: &state, configuration: .init(
                assets: assets, canvasSize: SIMD2(200, 100), screenResolution: SIMD2(200, 100),
                fieldDefaults: [.init(objectID: "", name: "bloom"): .vector(.zero)]
            ), volume: { _, _ in XCTFail("No sound object") }, command: { _, _, _ in false })
            XCTAssertNil(engine.start(state: &state), name)
            XCTAssertEqual(state.scriptField("bloom", of: ""), .vector(SIMD4(expected ? 1 : 0, 0, 0, 0)), name)
            XCTAssertEqual(engine.exceptionCount, 0, name + ": " + engine.exceptions.joined(separator: "\n"))
        }

        // The invalid seed still registers its real Bool property script. Existing canonical false survives it.
        let script = """
        if (thisScene.bloom !== false) throw new Error('retained canonical bloom');
        let frame = 0;
        export function init(v) {
          if (typeof v !== 'boolean' || v !== false) throw new Error('typed binding input');
          thisScene.bloom = true;
          thisScene.bloom = 0;
          if (thisScene.bloom !== true) throw new Error('invalid direct setter');
          return false;
        }
        export function update(v) {
          if (typeof v !== 'boolean') throw new Error('typed update input');
          frame += 1;
          if (frame === 1) { thisScene.bloom = true; return 0; }
          if (frame === 2) return false;
          return true;
        }
        """
        let scene = try document(["bloom": ["value": ["value": true], "script": script]])
        var state = WPEParitySceneState(document: scene, hdr: false)
        state.setScriptField("bloom", of: "", to: .vector(.zero), invalidating: .none)
        let engine = try WPEParityScriptEngine.prepare(document: scene, state: &state, configuration: .init(
            assets: assets, canvasSize: SIMD2(200, 100), screenResolution: SIMD2(200, 100)
        ), volume: { _, _ in XCTFail("No sound object") }, command: { _, _, _ in false })
        XCTAssertEqual(engine.bindings.map(\.path), ["bloom"])
        XCTAssertTrue(engine.bindings.allSatisfy(\.compiled))
        let bloomConstantsGeneration = state.generation(.bloom)
        XCTAssertNil(engine.start(state: &state))
        XCTAssertEqual(state.scriptField("bloom", of: ""), .vector(.zero))
        for expected: Float in [1, 0, 1] {
            engine.tick(dt: 0, state: &state)
            XCTAssertEqual(state.scriptField("bloom", of: ""), .vector(SIMD4(expected, 0, 0, 0)))
        }
        XCTAssertEqual(state.generation(.bloom), bloomConstantsGeneration, "Bool has no native Float-constant hook")
        XCTAssertEqual(engine.exceptionCount, 0, engine.exceptions.joined(separator: "\n"))
    }

    func testLookAtMethodsUseLocalTypedSlotsAndNativeCameraSign() throws {
        let imageScript = """
        const globalReturn = thisObject.lookAt(new Vec3(11, 20, 30));
        if (globalReturn !== undefined || Math.abs(thisObject.angles.y - 90) > 0.001) throw new Error('global local lookAt');
        export function init(v) {
          thisObject.origin = new Vec3(20, 30, 40);
          thisObject.lookAtYaw(new Vec3(21, 31, 40), new Vec3(0, 2, 0));
          if (Math.abs(thisObject.angles.x - Math.atan2(3, 1) * 180 / Math.PI) > 0.001) throw new Error('raw up yaw');
          const saved = thisObject.angles;
          thisObject.lookAtYaw(new Vec3(20, 31, 40));
          thisObject.lookAt(thisObject.origin);
          thisObject.lookAt({ x: 21, y: 30, z: 40 });
          if (thisObject.angles.x !== saved.x || thisObject.angles.y !== saved.y) throw new Error('degenerate target');
          thisObject.lookAt(new Vec3(20, 30, 41), { x: 1, y: 0, z: 0 });
          if (thisObject.angles.x !== 0 || thisObject.angles.y !== 0 || thisObject.angles.z !== 0) throw new Error('default up');
          thisObject.lookAt.call({ __index: thisObject.__index, __base: thisObject.__base }, new Vec3(1, 2, 3));
          if (thisObject.angles.y !== 0) throw new Error('forged receiver');
        }
        """
        let cameraScript = """
        thisObject.lookAt(new Vec3(11, 20, 30));
        if (Math.abs(thisObject.angles.y + 90) > 0.001) throw new Error('global camera sign');
        export function init(v) {
          const result = thisObject.lookAtYaw(new Vec3(11, 21, 30));
          if (result !== undefined || Math.abs(thisObject.angles.y + 90) > 0.001) throw new Error('camera yaw sign');
        }
        """
        let json: [String: Any] = [
            "camera": ["eye": "0 0 0", "center": "0 0 -1", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": 200, "height": 100]],
            "objects": [
                ["id": 1, "image": "models/test.json", "parent": 3, "origin": "10 20 30",
                 "angles": ["value": "0 0 0", "script": imageScript]],
                ["id": 2, "camera": "default", "origin": "10 20 30", "fov": ["script": cameraScript]],
                ["id": 3, "image": "models/test.json", "origin": "100 200 300"],
            ],
        ]
        let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: json),
                                                        userValues: [:], makeTransformScriptResolver: { _, _ in NoScripts() })
        var state = WPEParitySceneState(document: document, hdr: false)
        var logs: [String] = []
        let engine = try WPEParityScriptEngine(document: document, state: state, configuration: .init(
            assets: Self.fixedAssets(), canvasSize: SIMD2(200, 100), screenResolution: SIMD2(200, 100),
            log: { _, message in logs.append(message) }
        ))
        engine.start(state: &state)
        XCTAssertEqual(state.object("1")?.origin, SIMD3(20, 30, 40))
        XCTAssertEqual(state.object("1")?.angles, .zero)
        let angles = try XCTUnwrap(state.object("2")?.angles)
        XCTAssertEqual(angles.x, 0, accuracy: 0.000001)
        XCTAssertEqual(angles.y, -.pi / 2, accuracy: 0.000001)
        XCTAssertEqual(angles.z, 0, accuracy: 0.000001)
        XCTAssertEqual(logs.filter { $0.contains("native Vec3 target") }.count, 1,
                       "unqualified target conversion must be explicit rather than guessed")
        XCTAssertEqual(engine.exceptionCount, 0, engine.exceptions.joined(separator: "\n"))
    }

    func testCameraQueueEnumCanonicalizesImmediatelyWithoutChangingOrdinaryStrings() throws {
        let json = #"""
        {"camera":{"eye":"0 0 0","center":"0 0 -1","up":"0 1 0"},
         "general":{"orthogonalprojection":{"width":200,"height":100}},
         "objects":[
          {"id":1,"camera":"default","queuemode":{"value":"sequential\u0000suffix","script":"if (thisObject.queuemode !== 'random') throw new Error('initial enum'); export function init(v) { thisObject.queuemode = 'sequential\\u0000suffix'; if (thisObject.queuemode !== 'sequential') throw new Error('runtime cstring'); thisObject.queuemode = 'sequential'; if (thisObject.queuemode !== 'sequential') throw new Error('setter enum'); thisObject.queuemode = 'Sequential'; if (thisObject.queuemode !== 'random') throw new Error('case enum'); thisObject.queuemode = null; if (thisObject.queuemode !== 'random') throw new Error('nil enum'); return 'sequential'; } export function update(v) { thisObject.queuemode = 'unknown'; if (thisObject.queuemode !== 'random') throw new Error('unknown enum'); return 'SEQUENTIAL'; }"}},
          {"id":2,"text":{"value":"seed","script":"export function init(v) { thisObject.text = 'Sequential'; if (thisObject.text !== 'Sequential') throw new Error('ordinary string'); thisObject.text = null; if (thisObject.text !== 'Sequential') throw new Error('ordinary nil'); return 'SEQUENTIAL'; }"}}]}
        """#
        let document = try WPESceneDocumentParser.parse(data: Data(json.utf8), userValues: [:],
                                                        makeTransformScriptResolver: { _, _ in NoScripts() })
        var state = WPEParitySceneState(document: document, hdr: false)
        let engine = try WPEParityScriptEngine(document: document, state: state, configuration: .init(
            assets: Self.fixedAssets(), canvasSize: SIMD2(200, 100), screenResolution: SIMD2(200, 100)
        ))
        engine.start(state: &state)
        XCTAssertEqual(state.scriptField("queuemode", of: "1"), .string("sequential"))
        XCTAssertEqual(state.scriptField("text", of: "2"), .string("SEQUENTIAL"))
        engine.tick(dt: 0.1, state: &state)
        XCTAssertEqual(state.scriptField("queuemode", of: "1"), .string("random"))
        XCTAssertEqual(state.scriptField("text", of: "2"), .string("SEQUENTIAL"))
        XCTAssertEqual(engine.exceptionCount, 0, engine.exceptions.joined(separator: "\n"))
    }

    func testTubeControlPointDescriptorUpdatesRealLightConstants() throws {
        let json = #"""
        {"camera":{"eye":"0 0 0","center":"0 0 -1","up":"0 1 0"},
         "general":{"orthogonalprojection":{"width":200,"height":100},"lightconfig":{"tube":1}},
         "objects":[{"id":1,"light":"ltube","origin":"10 20 30","scale":"2 3 4",
          "controlpoint":{"script":"const cp = thisObject.controlpoint; if (cp.x !== 2 || cp.y !== 0 || cp.z !== 0) throw new Error('controlpoint default'); export function init(v) { return new Vec3(4, 5, 6); } export function update(v) { thisObject.controlpoint = new Vec3(7, 8, 9); return thisObject.controlpoint; }"}}]}
        """#
        let document = try WPESceneDocumentParser.parse(data: Data(json.utf8), userValues: [:],
                                                        makeTransformScriptResolver: { _, _ in NoScripts() })
        var state = WPEParitySceneState(document: document, hdr: false)
        let transforms = WPEParityLayerTransformSet(document: document, renderTargetSize: SIMD2(200, 100))
        let engine = try WPEParityScriptEngine(document: document, state: state, configuration: .init(
            assets: Self.fixedAssets(), canvasSize: SIMD2(200, 100), screenResolution: SIMD2(200, 100)
        ))
        engine.start(state: &state)
        XCTAssertEqual(state.scriptField("controlpoint", of: "1"), .vector(SIMD4(4, 5, 6, 0)))
        var lights = WPEParityUniformLights(document: document, transforms: transforms, state: state)
        XCTAssertEqual(lights.tubeOriginB, [SIMD4(18, 35, 54, 0)])
        let generation = state.generation(.lighting)
        engine.tick(dt: 0.25, state: &state)
        XCTAssertGreaterThan(state.generation(.lighting), generation)
        lights = WPEParityUniformLights(document: document, transforms: transforms, state: state)
        guard case let .array(packed)? = lights.values["g_LTube_OriginB"], packed.count == 1,
              case let .vector(actual) = packed[0] else { return XCTFail("malformed tube endpoint array") }
        XCTAssertEqual(actual, [24, 44, 66])
        XCTAssertEqual(engine.exceptionCount, 0, engine.exceptions.joined(separator: "\n"))
    }

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
        let engine = try WPEParityScriptEngine(document: document, state: state, configuration: .init(
            assets: Self.fixedAssets(),
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

    private static func fixedAssets(files: [String: Any] = [:]) throws -> WPEParityProgramAssets {
        // Fixed shipped helper, SHA256 708e6636167f0456eebf3ba05274d7b7763d17dfbd44c2711dc3d6d98f0cb294.
        // Kept outside the test target's source directory; these guards need no installed Steam assets.
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/ParityScript/baseclasses.js")
        let baseClasses = try Data(contentsOf: fixture)
        let resources = try files.mapValues { try JSONSerialization.data(withJSONObject: $0) }
        return WPEParityProgramAssets(sources: [.lookup(fixture.deletingLastPathComponent()) { path in
            path == "scripts/jsclasses/baseclasses.js" ? baseClasses : resources[path]
        }])
    }

    private static func scene(_ objects: [[String: Any]],
                              constants: [WPEParityMaterialPassKey: [String: [Double]]] = [:],
                              angleConstants: Set<WPEParityScriptEngine.ConstantKey> = [],
                              general: [String: Any] = [:],
                              assets: WPEParityProgramAssets? = nil,
                              resolveEffectResources: Bool = false,
                              configure: (inout WPEParityScriptEngine.Configuration) -> Void = { _ in }) throws -> Scene {
        guard assets != nil || FileManager.default.fileExists(atPath: install.appendingPathComponent("scripts").path) else {
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
            assets: assets ?? WPEParityProgramAssets(sceneDirectory: FileManager.default.temporaryDirectory,
                                                     assetRoots: [install]),
            canvasSize: SIMD2(1920, 1080), screenResolution: SIMD2(1920, 1080), angleConstants: angleConstants
        )
        if resolveEffectResources {
            configuration.resolvedEffectRecords = WPEParityProgramScene(
                document: document, assets: configuration.assets, settings: .init()
            ).resolvedEffectRecords
        }
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
            let requested = false;
            export function update(value) {
                if (requested) return value;
                requested = true;
                const before = thisScene.getLayerCount();
                if (thisScene.getLayerIndex('B') !== 1) throw Error('live name index before request');
                thisScene.destroyLayer(thisScene.getLayer('B'));
                if (thisScene.getLayer('B') !== null || thisScene.getInitialLayerConfig('B') !== null)
                    throw Error('pending name must miss before flush');
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
            configuration.destroyLayer = { id, state in state.removeObject(id) }
        })
        scene.engine.start(state: &scene.state)
        scene.engine.tick(dt: 0.01, state: &scene.state)
        XCTAssertEqual(scene.state.object("1")?.color, SIMD3(3, 2, -1))
        XCTAssertEqual(scene.state.object("1")?.brightness, -1)
        XCTAssertEqual(scene.state.object("3")?.alpha, 2)
        XCTAssertNil(scene.state.object("2"))
        XCTAssertEqual(scene.engine.destroyedObjectIDs, ["2"])
        scene.engine.tick(dt: 0.01, state: &scene.state)
        XCTAssertEqual(scene.state.object("3")?.alpha, 2)
        XCTAssertEqual(scene.engine.exceptionCount, 0, scene.engine.exceptions.joined(separator: "\n"))
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

    /// Host failures must not publish their candidate value-state or manufacture a wrapper/constant owner.
    /// This is package failure atomicity, not proof of product resource rollback or native failure returns.
    func testInvalidCreateCandidatesPreserveLiveStateAndExistingScriptWrites() throws {
        let valid: [String: Any] = ["id": 3, "name": "created", "image": "models/created.json", "size": "100 100"]
        let missingBase = valid.merging(["instance": ["constantshadervalues": ["amount": 1]]]) { _, new in new }
        let missingEffect = valid.merging(["effects": [["id": 5, "file": "effects/missing.json",
                                                        "passes": [["constantshadervalues": ["amount": 1]]]]]]) { _, new in new }
        var missingID = valid
        missingID["id"] = nil
        missingID["name"] = "3"
        let cases: [(String, String?, [String: Any], String?, Bool)] = [
            ("nil result", nil, valid, nil, true),
            ("invalid JSON", "3", valid, "{", true),
            ("nonobject JSON", "3", valid, "[]", true),
            ("duplicate identity", "2", valid.merging(["id": 2]) { _, new in new }, nil, true),
            ("mismatched config identity", "3", valid.merging(["id": 4]) { _, new in new }, nil, true),
            ("missing assigned identity", "3", missingID, nil, true),
            ("out-of-range numeric identity", "3", valid.merging(["id": 1e100]) { _, new in new }, nil, true),
            ("fractional numeric identity", "3", valid.merging(["id": 3.5]) { _, new in new }, nil, true),
            ("missing candidate object", "3", valid, nil, false),
            ("missing base consumer", "3", missingBase, nil, true),
            ("missing effect consumer", "3", missingEffect, nil, true),
        ]
        for (label, returnedID, config, rawJSON, append) in cases {
            let objects = [
                Self.layer(1, "A", ["alpha": Self.scripted(1, """
                export function init(value) {
                    const witness = thisScene.getLayer('B');
                    witness.brightness = 17;
                    const created = thisScene.createLayer({ image: 'models/created.json', name: 'created' });
                    thisLayer.color = new Vec3(created === null ? 1 : 99, thisScene.getLayerCount(), witness.brightness);
                    return value;
                }
                """)]),
                Self.layer(2, "B"),
            ]
            // The host prepares a complete value-state candidate; malformed returned identity/config must still
            // discard it. No renderer, GPU resource or product transaction is simulated by this fixture.
            let candidateJSON: [String: Any] = [
                "camera": ["center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"],
                "general": ["orthogonalprojection": ["width": 1920, "height": 1080]],
                "objects": objects + [config.merging(["id": 3]) { _, new in new }],
            ]
            let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: candidateJSON),
                                                            userValues: [:], makeTransformScriptResolver: { _, _ in NoScripts() })
            let prepared = WPEParitySceneState(document: document, hdr: false)
            let encoded = try JSONSerialization.data(withJSONObject: config)
            let configJSON = try rawJSON ?? XCTUnwrap(String(bytes: encoded, encoding: .utf8))
            var attempts = 0
            var diagnostics: [String] = []
            var scene = try Self.scene(objects, assets: Self.fixedAssets(), configure: { configuration in
                configuration.createLayer = { _, candidate in
                    attempts += 1
                    if append {
                        candidate = prepared
                    }
                    candidate.set(.brightness, of: "2", to: SIMD4(99, 0, 0, 0))
                    return returnedID.map { .init(id: $0, configJSON: configJSON) }
                }
                configuration.log = { _, message in diagnostics.append(message) }
            })
            scene.engine.start(state: &scene.state)
            XCTAssertEqual(attempts, 1, label)
            XCTAssertEqual(scene.state.object("1")?.color, SIMD3(1, 2, 17), label)
            XCTAssertEqual(scene.state.object("2")?.brightness, 17, label)
            XCTAssertEqual(scene.state.ids, ["1", "2"], label)
            XCTAssertNil(scene.state.index(of: "3"), label)
            XCTAssertTrue(scene.engine.createdLayers.isEmpty, label)
            XCTAssertEqual(scene.engine.bindings.count, 1, label)
            XCTAssertEqual(diagnostics.filter { $0.contains("no state was committed") }.count, 1, label)
            XCTAssertEqual(scene.engine.exceptionCount, 0, label + scene.engine.exceptions.joined(separator: "\n"))
        }
    }

    /// The public state input may contain an object without an engine wrapper. Returning that existing ID while
    /// appending a different object must not satisfy a single-object create transaction.
    func testCreateRejectsAnExistingStateIDWithoutAnEngineWrapper() throws {
        let objects = [Self.layer(1, "A", ["alpha": Self.scripted(1, """
        export function init(value) {
            thisLayer.brightness = 17;
            const created = thisScene.createLayer({ image: 'models/created.json', name: 'created' });
            thisLayer.color = new Vec3(created === null ? 1 : 99, thisScene.getLayerCount(), thisLayer.brightness);
            return thisScene.getLayer('state-only') === null ? 1 : 99;
        }
        """)])]
        let stateOnly = Self.layer(2, "state-only")
        func makeState(_ objects: [[String: Any]]) throws -> WPEParitySceneState {
            let json: [String: Any] = [
                "camera": ["center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"],
                "general": ["orthogonalprojection": ["width": 1920, "height": 1080]],
                "objects": objects,
            ]
            let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: json),
                                                            userValues: [:], makeTransformScriptResolver: { _, _ in NoScripts() })
            return WPEParitySceneState(document: document, hdr: false)
        }
        let current = try makeState(objects + [stateOnly])
        let prepared = try makeState(objects + [stateOnly, Self.layer(3, "unrelated")])
        let configData = try JSONSerialization.data(withJSONObject: stateOnly)
        let configJSON = try XCTUnwrap(String(bytes: configData, encoding: .utf8))
        var attempts = 0
        var diagnostics: [String] = []
        var scene = try Self.scene(objects, assets: Self.fixedAssets(), configure: { configuration in
            configuration.createLayer = { _, candidate in
                attempts += 1
                candidate = prepared
                candidate.set(.brightness, of: "1", to: SIMD4(99, 0, 0, 0))
                return .init(id: "2", configJSON: configJSON)
            }
            configuration.log = { _, message in diagnostics.append(message) }
        })
        scene.state = current
        scene.engine.start(state: &scene.state)
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(scene.state.object("1")?.color, SIMD3(1, 1, 17))
        XCTAssertEqual(scene.state.object("1")?.alpha, 1)
        XCTAssertEqual(scene.state.object("1")?.brightness, 17)
        XCTAssertEqual(scene.state.ids, ["1", "2"])
        XCTAssertNil(scene.state.index(of: "3"))
        XCTAssertTrue(scene.engine.createdLayers.isEmpty)
        XCTAssertEqual(scene.engine.bindings.count, 1)
        XCTAssertEqual(diagnostics.filter { $0.contains("no state was committed") }.count, 1)
        XCTAssertEqual(scene.engine.exceptionCount, 0, scene.engine.exceptions.joined(separator: "\n"))
    }

    func testVideoPauseUsesTheCachedWrapperAndRejectsBorrowedReceivers() throws {
        var paused: [String] = []
        var diagnostics: [String] = []
        var scene = try Self.scene([
            Self.layer(1, "A", ["alpha": Self.scripted(1, """
            export function init(value) {
                const video = thisLayer.getVideoTexture();
                const result = video.pause();
                video.pause.call({});
                video.pause.call(thisLayer);
                video.pause.call(Object.create(video));
                thisLayer.color = new Vec3(result === undefined ? 1 : 99,
                    video === thisLayer.getVideoTexture() ? 1 : 99,
                    thisScene.getLayer('static').getVideoTexture() === null ? 1 : 99);
                return value;
            }
            """)]),
            Self.layer(2, "static"),
        ], assets: Self.fixedAssets(), configure: { configuration in
            configuration.fieldDefaults[.init(objectID: "1", name: "video.duration")] = .vector(SIMD4(1, 0, 0, 0))
            configuration.pauseVideoTexture = { paused.append($0); return true }
            configuration.log = { _, message in diagnostics.append(message) }
        })
        scene.engine.start(state: &scene.state)
        XCTAssertEqual(paused, ["1"])
        XCTAssertEqual(scene.state.object("1")?.color, .one)
        XCTAssertEqual(diagnostics.filter { $0.contains("invalid video wrapper") }.count, 3)
        XCTAssertEqual(scene.engine.exceptionCount, 0, scene.engine.exceptions.joined(separator: "\n"))
    }

    func testVideoPauseWithoutAConsumerStaysExplicitlyUnsupported() throws {
        for accepted: Bool? in [nil, false] {
            var attempts = 0
            var diagnostics: [String] = []
            var scene = try Self.scene([
                Self.layer(1, "A", ["alpha": Self.scripted(1, """
                export function init() { return thisLayer.getVideoTexture().pause() === undefined ? 1 : 99; }
                """)]),
            ], assets: Self.fixedAssets(), configure: { configuration in
                configuration.fieldDefaults[.init(objectID: "1", name: "video.duration")] = .vector(SIMD4(1, 0, 0, 0))
                if let accepted {
                    configuration.pauseVideoTexture = { _ in attempts += 1; return accepted }
                }
                configuration.log = { _, message in diagnostics.append(message) }
            })
            scene.engine.start(state: &scene.state)
            XCTAssertEqual(attempts, accepted == nil ? 0 : 1)
            XCTAssertEqual(scene.state.object("1")?.alpha, 1)
            XCTAssertEqual(diagnostics.filter { $0.contains("existing product video consumer") }.count, 1)
            XCTAssertEqual(scene.engine.exceptionCount, 0, scene.engine.exceptions.joined(separator: "\n"))
        }
    }

    func testLayerHostIndicesRejectNonIntegralAndOutOfBoundsValuesWithoutTrapping() throws {
        for value in [Double.nan, .infinity, -.infinity, 1e100, Double(Int.max), -1, 0.5, 3] {
            XCTAssertNil(WPEParityScriptEngine.checkedLayerIndex(value, count: 3))
        }
        for value in 0 ..< 3 {
            XCTAssertEqual(WPEParityScriptEngine.checkedLayerIndex(Double(value), count: 3), value)
        }
        XCTAssertNil(WPEParityScriptEngine.checkedLayerIndex(0, count: 0))

        var scene = try Self.scene([
            Self.layer(1, "A", ["alpha": Self.scripted(1, """
            export function init(value) {
                let rejected = 0;
                for (const index of [Infinity, NaN, -1, 99, 0.5, 1e100]) {
                    try { thisLayer.__index = index; } catch (error) { rejected += 1; }
                }
                thisLayer.color = new Vec3(rejected,
                    thisScene.getInitialLayerConfig(thisLayer).name === 'A' ? 1 : 99,
                    thisScene.getLayerIndex(thisLayer));
                return value;
            }
            """)]),
            Self.layer(2, "B"),
        ], assets: Self.fixedAssets())
        scene.engine.start(state: &scene.state)
        XCTAssertEqual(scene.state.object("1")?.color, SIMD3(6, 1, 0))
        XCTAssertEqual(scene.engine.exceptionCount, 0, scene.engine.exceptions.joined(separator: "\n"))
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
                                 export function init() {
                                     const effect = thisLayer.getEffect(0);
                                     const material = effect.getMaterial(0);
                                     if (material !== thisObject || material !== effect.getMaterial(0)) throw Error('material identity');
                                     const empty = effect.getMaterial(1);
                                     if (empty === material || empty !== effect.getMaterial(1) || Object.keys(empty).length !== 0)
                                         throw Error('empty pass identity');
                                     shared.material = thisObject;
                                     return new Vec2(90, 180);
                                 }
                                 """),
                                 "v4": Self.scripted("0 0 0 0", """
                                 export function init() {
                                     thisLayer.alpha = thisObject === shared.material && thisObject.extra === 7 ? 0.5 : 99;
                                     thisObject.extra = 8;
                                     return new Vec4(90, 180, 270, 360);
                                 }
                                 """),
                             ]], [:]]]],
            ]),
        ], constants: [pass: ["v2": [0, 0], "v4": [0, 0, 0, 0], "extra": [7]],
                       .init(objectID: "1", effectID: "5", pass: 1): [:]], assets: Self.fixedAssets(files: [
            "effects/x.json": ["passes": [["material": "materials/first.json"], ["material": "materials/empty.json"]]],
            "materials/first.json": ["passes": [["shader": "probe"]]],
            "materials/empty.json": ["passes": [["shader": "empty"]]],
        ]), resolveEffectResources: true,
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
        XCTAssertEqual(scene.state.object("1")?.color, SIMD3(1, 1, 2))
        XCTAssertEqual(scene.state.object("1")?.alpha, 0.5)
        XCTAssertNotNil(scene.state.passIndex(of: .init(objectID: "1", effectID: "5", pass: 1)),
                        "the empty wrapper belongs to a real empty material pass")
        XCTAssertEqual(scene.state.constant("extra", of: pass)?.value.x, 8)
        XCTAssertEqual(scene.state.constant("v2", of: pass)?.value, SIMD4(90, 180, 0, 0))
        XCTAssertEqual(scene.state.constant("v4", of: pass)?.value, SIMD4(90, 180, 270, 360))
        scene.engine.tick(dt: 0.01, state: &scene.state)
        XCTAssertEqual(scene.state.object("1")?.angles, SIMD3(90, 90, 90), "scalar vec3 angle branch skips conversion")
        XCTAssertEqual(scene.engine.exceptionCount, 0, scene.engine.exceptions.joined(separator: "\n"))
    }

    /// H09c: count includes condition-accepted command/missing records. Pure commands and out-of-range indices
    /// return null; missing-material null remains an explicit Mac limitation until its fallback consumer exists.
    func testResolvedEffectRecordsOwnOnlyRealMaterialsAndRejectAuthoredPhantoms() throws {
        var diagnostics: [String] = []
        let first = WPEParityMaterialPassKey(objectID: "1", effectID: "5", pass: 0)
        let later = WPEParityMaterialPassKey(objectID: "1", effectID: "5", pass: 3)
        var scene = try Self.scene([
            Self.layer(1, "A", ["alpha": Self.scripted(1, """
            export function init() {
                const effect = thisLayer.getEffect(0);
                const empty = effect.getMaterial(0), later = effect.getMaterial(2);
                if (empty !== effect.getMaterial(0) || Object.keys(empty).length !== 0) throw Error('empty material');
                thisLayer.color = new Vec3(effect.getMaterialCount(), later.Color, effect.visible ? 99 : 1);
                later.Color = 8;
                const rejected = effect.getMaterial(1) === null && effect.getMaterial(3) === null
                    && effect.getMaterial(4) === null && effect.getMaterial(5) === null && effect.getMaterial('0') === null;
                thisLayer.brightness = rejected ? 7 : 99;
            }
            """), "effects": [["id": 5, "name": "effect", "file": "effects/records.json", "visible": false,
                               "passes": [[:], ["constantshadervalues": ["phantom": Self.scripted(2, "export function init() { return 99; }")]],
                                          [:], ["constantshadervalues": ["Color": 3]], [:], [:],
                                          ["constantshadervalues": ["beyond": 4]]]]]]),
        ], constants: [first: [:], later: ["Color": [3]]], assets: Self.fixedAssets(files: [
            "effects/records.json": ["passes": [
                ["material": "materials/empty.json"], ["command": "copy"],
                ["material": "materials/skipped.json", "conditions": [["ON": 1]]],
                ["material": "materials/later.json"], ["command": "swap"],
                ["material": "materials/missing.json"],
            ]],
            "materials/empty.json": ["passes": [["shader": "empty"]]],
            "materials/later.json": ["passes": [["shader": "later"]]],
        ]), resolveEffectResources: true, configure: { configuration in
            configuration.log = { _, message in diagnostics.append(message) }
        })
        scene.engine.start(state: &scene.state)
        XCTAssertEqual(scene.state.object("1")?.color, SIMD3(5, 3, 1))
        XCTAssertEqual(scene.state.object("1")?.brightness, 7)
        XCTAssertEqual(scene.state.constant("Color", of: later)?.value.x, 8)
        XCTAssertNil(scene.state.constant("phantom", of: .init(objectID: "1", effectID: "5", pass: 1)))
        XCTAssertNil(scene.state.constant("beyond", of: .init(objectID: "1", effectID: "5", pass: 6)))
        XCTAssertFalse(scene.engine.bindings.contains { $0.path.contains("phantom") })
        XCTAssertEqual(diagnostics.filter { $0.contains("getMaterial") }.count, 1,
                       "only the declared missing material is unsupported; command/out-of-range/path misses are known nulls")
        XCTAssertEqual(scene.engine.exceptionCount, 0, scene.engine.exceptions.joined(separator: "\n"))
    }

    /// H09b/c: strict signed-int32 selects a compact record; other measured inputs use the empty path default.
    /// Path matching folds ASCII only and chooses the last duplicate, without merging pass wrappers/state.
    func testMaterialPathAndDefaultQueriesReuseLastMatchingRealPass() throws {
        var diagnostics: [String] = []
        let first = WPEParityMaterialPassKey(objectID: "1", effectID: "5", pass: 0)
        let second = WPEParityMaterialPassKey(objectID: "1", effectID: "5", pass: 3)
        let last = WPEParityMaterialPassKey(objectID: "1", effectID: "5", pass: 4)
        var scene = try Self.scene([
            Self.layer(1, "A", ["alpha": Self.scripted(1, """
            export function init() {
                const effect = thisLayer.getEffect(0);
                const first = effect.getMaterial(0), second = effect.getMaterial(2), last = effect.getMaterial(3);
                if (!first || !second || !last || first === second || second === last) throw Error('separate material owners');
                if (effect.getMaterial('materials/shared.json') !== second
                    || effect.getMaterial('MATERIALS/SHARED.JSON') !== second
                    || effect.getMaterial('materials/shared.json') !== effect.getMaterial(2)) throw Error('last duplicate path');
                const defaults = [undefined, null, false, true, 1.5, -0.5, 2.5, NaN, Infinity, -Infinity,
                    2147483648, -2147483649, 4294967296, 4294967297, -4294967295,
                    {}, [], new Number(1), {toString(){throw Error('must not coerce');}}];
                if (!defaults.every(input => effect.getMaterial(input) === last)
                    || effect.getMaterial() !== last || effect.getMaterial('') !== last) throw Error('empty default path');
                if (effect.getMaterial(-0) !== first || effect.getMaterial(-1) !== null
                    || effect.getMaterial(-2147483648) !== null || effect.getMaterial(2147483647) !== null
                    || effect.getMaterial(1) !== null || effect.getMaterial(4) !== null) throw Error('strict compact index');
                const misses = ['0', 'materials/missing.json', './materials/shared.json',
                    'materials/./shared.json', 'materials\\\\shared.json'];
                if (!misses.every(path => effect.getMaterial(path) === null)) throw Error('path must not normalize');
                shared.selectedMaterial = second;
                second.Value = 8;
                last.Value = 9;
                thisLayer.color = new Vec3(effect.getMaterialCount(), first.Value, second.Value);
                thisLayer.brightness = 7;
            }
            """), "effects": [["id": 5, "file": "effects/query.json", "passes": [
                ["constantshadervalues": ["Value": 1]], [:], [:],
                ["constantshadervalues": ["Value": Self.scripted(3, """
                export function init(value) {
                    if (thisObject !== shared.selectedMaterial || thisObject !== thisLayer.getEffect(0).getMaterial(2))
                        throw Error('query must retain actual script owner identity');
                    return value;
                }
                """)]], ["constantshadervalues": ["Value": 5]],
            ]]]]),
        ], constants: [first: ["Value": [1]], second: ["Value": [3]], last: ["Value": [5]]],
        assets: Self.fixedAssets(files: [
            "effects/query.json": ["passes": [
                ["material": "materials/shared.json"], ["command": "copy"],
                ["material": "materials/skipped.json", "conditions": [["ON": 1]]],
                ["material": "materials/shared.json"], ["material": "materials/last.json"],
            ]],
            "materials/shared.json": ["passes": [["shader": "probe"]]],
            "materials/last.json": ["passes": [["shader": "probe"]]],
        ]), resolveEffectResources: true, configure: { configuration in
            configuration.log = { _, message in diagnostics.append(message) }
        })
        scene.engine.start(state: &scene.state)
        XCTAssertEqual(scene.state.object("1")?.color, SIMD3(4, 1, 8))
        XCTAssertEqual(scene.state.object("1")?.brightness, 7)
        XCTAssertEqual(scene.state.constant("Value", of: first)?.value.x, 1)
        XCTAssertEqual(scene.state.constant("Value", of: second)?.value.x, 8)
        XCTAssertEqual(scene.state.constant("Value", of: last)?.value.x, 9)
        XCTAssertTrue(diagnostics.isEmpty, diagnostics.joined(separator: "\n"))
        XCTAssertEqual(scene.engine.exceptionCount, 0, scene.engine.exceptions.joined(separator: "\n"))
    }

    /// Windows H09d returned a real fallback wrapper. These nulls deliberately report missing consumers;
    /// they must not be treated as native success or replaced by an earlier ready duplicate/default candidate.
    func testUnresolvedAndMaterialBearingCommandQueriesDoNotSkipToEarlierPass() throws {
        var diagnostics: [String] = []
        let first = WPEParityMaterialPassKey(objectID: "1", effectID: "5", pass: 0)
        var scene = try Self.scene([
            Self.layer(1, "A", ["alpha": Self.scripted(1, """
            export function init() {
                const effect = thisLayer.getEffect(0), first = effect.getMaterial(0);
                if (!first || first.Value !== 1) throw Error('real first material');
                const unsupported = effect.getMaterial(1) === null
                    && effect.getMaterial('materials/missing.json') === null
                    && effect.getMaterial('materials/first.json') === null
                    && effect.getMaterial() === null && effect.getMaterial(2) === null;
                thisLayer.color = new Vec3(effect.getMaterialCount(), first.Value, unsupported ? 1 : 99);
                first.Value = 7;
            }
            """), "effects": [["id": 5, "file": "effects/unresolved.json", "passes": [
                ["constantshadervalues": ["Value": 1]], [:], [:],
            ]]]]),
        ], constants: [first: ["Value": [1]]], assets: Self.fixedAssets(files: [
            "effects/unresolved.json": ["passes": [
                ["material": "materials/first.json"], ["material": "materials/missing.json"],
                ["command": "copy", "material": "materials/first.json"],
            ]],
            "materials/first.json": ["passes": [["shader": "probe"]]],
        ]), resolveEffectResources: true, configure: { configuration in
            configuration.log = { _, message in diagnostics.append(message) }
        })
        scene.engine.start(state: &scene.state)
        XCTAssertEqual(scene.state.object("1")?.color, SIMD3(3, 1, 1))
        XCTAssertEqual(scene.state.constant("Value", of: first)?.value.x, 7)
        XCTAssertNil(scene.state.passIndex(of: .init(objectID: "1", effectID: "5", pass: 1)))
        XCTAssertNil(scene.state.passIndex(of: .init(objectID: "1", effectID: "5", pass: 2)))
        XCTAssertEqual(diagnostics.filter { $0.contains("material state consumer; this candidate is unsupported") }.count, 5)
        XCTAssertEqual(scene.engine.exceptionCount, 0, scene.engine.exceptions.joined(separator: "\n"))
    }

    func testResolvedMetadataCannotManufactureAWrapperWithoutMaterialState() throws {
        // A legacy resolved key may also lack path metadata; it must still block the last default candidate.
        for preserveLastPath in [true, false] {
            var diagnostics: [String] = []
            let first = WPEParityMaterialPassKey(objectID: "1", effectID: "5", pass: 0)
            let absent = WPEParityMaterialPassKey(objectID: "1", effectID: "5", pass: 1)
            var scene = try Self.scene([
                Self.layer(1, "A", ["alpha": Self.scripted(1, """
                export function init() {
                    const effect = thisLayer.getEffect(0), first = effect.getMaterial(0);
                    const unsupported = effect.getMaterial(1) === null
                        && effect.getMaterial('materials/second.json') === null && effect.getMaterial() === null;
                    effect.setMaterialProperty('phantom', 99);
                    first.Value = 7;
                    thisLayer.color = new Vec3(effect.getMaterialCount(), first.Value, unsupported ? 1 : 99);
                }
                """), "effects": [["id": 5, "file": "effects/malformed.json", "passes": [
                    ["constantshadervalues": ["Value": 1]],
                    ["constantshadervalues": ["phantom": Self.scripted(2, "export function init() { return 99; }")]],
                ]]]]),
            ], constants: [first: ["Value": [1]]], assets: Self.fixedAssets(files: [
                // The real asset resolves both keys, but the caller's supplied state contains only the first.
                "effects/malformed.json": ["passes": [
                    ["material": "materials/first.json"], ["material": "materials/second.json"],
                ]],
                "materials/first.json": ["passes": [["shader": "probe"]]],
                "materials/second.json": ["passes": [["shader": "probe"]]],
            ]), resolveEffectResources: true, configure: { configuration in
                if !preserveLastPath,
                   let records = configuration.resolvedEffectRecords[.init(objectID: "1", effectID: "5")] {
                    configuration.resolvedEffectRecords[.init(objectID: "1", effectID: "5")] = records.map { record in
                        record.filePassIndex == 1
                            ? .init(filePassIndex: record.filePassIndex, materialPass: record.materialPass)
                            : record
                    }
                }
                configuration.log = { _, message in diagnostics.append(message) }
            })
            scene.engine.start(state: &scene.state)
            XCTAssertEqual(scene.state.object("1")?.color, SIMD3(2, 7, 1))
            XCTAssertNil(scene.state.passIndex(of: absent))
            XCTAssertNil(scene.state.constant("phantom", of: absent))
            XCTAssertFalse(scene.engine.bindings.contains { $0.path.contains("phantom") })
            XCTAssertEqual(diagnostics.filter { $0.contains("material state consumer; this candidate is unsupported") }.count, preserveLastPath ? 3 : 2)
            XCTAssertEqual(diagnostics.filter { $0.contains("without verified material path metadata") }.count, preserveLastPath ? 0 : 1)
            XCTAssertEqual(scene.engine.exceptionCount, 0, scene.engine.exceptions.joined(separator: "\n"))
        }
    }

    /// A pass belonging to another layer, or the wrong raw file index, is not this record's consumer even
    /// when that key exists in state. Rejected metadata must block the final candidate, never alias a wrapper.
    func testMaterialMetadataCannotAliasAnotherOwnerOrRawFileIndex() throws {
        let first = WPEParityMaterialPassKey(objectID: "1", effectID: "5", pass: 0)
        let second = WPEParityMaterialPassKey(objectID: "1", effectID: "5", pass: 1)
        let foreign = WPEParityMaterialPassKey(objectID: "2", effectID: "5", pass: 1)
        for useForeignOwner in [true, false] {
            var diagnostics: [String] = []
            var scene = try Self.scene([
                Self.layer(1, "A", ["alpha": Self.scripted(1, """
                export function init() {
                    const effect = thisLayer.getEffect(0), first = effect.getMaterial(0), wrong = effect.getMaterial(1);
                    if (wrong) wrong.Value = 99;
                    const blocked = wrong === null && effect.getMaterial('materials/shared.json') === null
                        && effect.getMaterial() === null;
                    first.Value = 7;
                    thisLayer.color = new Vec3(effect.getMaterialCount(), first.Value, blocked ? 1 : 99);
                }
                """), "effects": [["id": 5, "file": "effects/owners.json", "passes": [
                    ["constantshadervalues": ["Value": 1]], ["constantshadervalues": ["Value": 2]],
                ]]]]),
                Self.layer(2, "B", ["effects": [["id": 5, "file": "effects/owners.json", "passes": [
                    [:], ["constantshadervalues": ["Value": 33]],
                ]]]]),
            ], constants: [first: ["Value": [1]], second: ["Value": [2]], foreign: ["Value": [33]]],
            assets: Self.fixedAssets(files: [
                "effects/owners.json": ["passes": [
                    ["material": "materials/shared.json"], ["material": "materials/shared.json"],
                ]],
                "materials/shared.json": ["passes": [["shader": "probe"]]],
            ]), resolveEffectResources: true, configure: { configuration in
                if let records = configuration.resolvedEffectRecords[.init(objectID: "1", effectID: "5")] {
                    configuration.resolvedEffectRecords[.init(objectID: "1", effectID: "5")] = records.map { record in
                        record.filePassIndex == 1
                            ? .init(filePassIndex: 1, materialPass: useForeignOwner ? foreign : first,
                                    materialPath: record.materialPath)
                            : record
                    }
                }
                configuration.log = { _, message in diagnostics.append(message) }
            })
            scene.engine.start(state: &scene.state)
            XCTAssertEqual(scene.state.object("1")?.color, SIMD3(2, 7, 1))
            XCTAssertEqual(scene.state.constant("Value", of: first)?.value.x, 7)
            XCTAssertEqual(scene.state.constant("Value", of: second)?.value.x, 2)
            XCTAssertEqual(scene.state.constant("Value", of: foreign)?.value.x, 33)
            XCTAssertEqual(diagnostics.filter { $0.contains("material state consumer; this candidate is unsupported") }.count, 3)
            XCTAssertEqual(scene.engine.exceptionCount, 0, scene.engine.exceptions.joined(separator: "\n"))
        }
    }

    /// Legacy injected records can retain real pass identity without paths, but cannot promise string lookup.
    /// The empty final pass below is present in real state; its wrapper is not a fallback DTO.
    func testLegacyMaterialMetadataKeepsRealEmptyIdentityAndReportsUnknownPathProtocol() throws {
        var diagnostics: [String] = []
        let first = WPEParityMaterialPassKey(objectID: "1", effectID: "5", pass: 0)
        let empty = WPEParityMaterialPassKey(objectID: "1", effectID: "5", pass: 1)
        var scene = try Self.scene([
            Self.layer(1, "A", ["alpha": Self.scripted(1, """
            export function init() {
                const effect = thisLayer.getEffect(0), first = effect.getMaterial(0), empty = effect.getMaterial(1);
                if (!first || !empty || first === empty || Object.keys(empty).length !== 0
                    || empty !== effect.getMaterial(1) || empty !== effect.getMaterial()) throw Error('real empty identity');
                const partial = effect.getMaterial('materials/first.json') === null
                    && effect.getMaterial('materials/é.json') === null
                    && effect.getMaterial('materials/' + String.fromCharCode(0) + 'first.json') === null;
                first.Value = 7;
                thisLayer.color = new Vec3(effect.getMaterialCount(), first.Value, partial ? 1 : 99);
            }
            """), "effects": [["id": 5, "file": "effects/legacy.json", "passes": [
                ["constantshadervalues": ["Value": 1]], [:],
            ]]]]),
        ], constants: [first: ["Value": [1]], empty: [:]], assets: Self.fixedAssets(files: [
            "effects/legacy.json": ["passes": [
                ["material": "materials/first.json"], ["material": "materials/empty.json"],
            ]],
            "materials/first.json": ["passes": [["shader": "probe"]]],
            "materials/empty.json": ["passes": [["shader": "empty"]]],
        ]), resolveEffectResources: true, configure: { configuration in
            configuration.resolvedEffectRecords = configuration.resolvedEffectRecords.mapValues { records in
                records.map { .init(filePassIndex: $0.filePassIndex, materialPass: $0.materialPass) }
            }
            configuration.log = { _, message in diagnostics.append(message) }
        })
        scene.engine.start(state: &scene.state)
        XCTAssertEqual(scene.state.object("1")?.color, SIMD3(2, 7, 1))
        XCTAssertNotNil(scene.state.passIndex(of: empty))
        XCTAssertEqual(diagnostics.filter { $0.contains("without verified material path metadata") }.count, 1)
        XCTAssertEqual(diagnostics.filter { $0.contains("NUL or non-ASCII material paths") }.count, 2)
        XCTAssertEqual(scene.engine.exceptionCount, 0, scene.engine.exceptions.joined(separator: "\n"))
    }

    func testMissingBaseMaterialDoesNotCreateTypedConstantBindings() throws {
        var diagnostics: [String] = []
        let base = WPEParityMaterialPassKey(objectID: "1")
        var scene = try Self.scene([
            Self.layer(1, "A", [
                "alpha": Self.scripted(1, """
                export function init(value) {
                    // H09d has a real native fallback wrapper. This null remains an explicit Mac limitation
                    // until the fallback material state/render consumer is implemented.
                    thisLayer.brightness = thisLayer.getEffect(0).getMaterial(0) === null ? 7 : 99;
                    return value;
                }
                """),
                "instance": ["constantshadervalues": ["phantom": Self.scripted(2, """
                export function init() { thisObject.phantom = 99; thisLayer.brightness = 99; return 99; }
                """)]],
                "effects": [["id": 5, "file": "effects/missing-material.json", "passes": [
                    ["constantshadervalues": ["absent": Self.scripted(3, "export function init() { return 99; }")]],
                ]]],
            ]),
        ], assets: Self.fixedAssets(files: [
            "models/A.json": ["material": "materials/missing.json"],
            "effects/missing-material.json": ["passes": [["material": "materials/missing.json"]]],
        ]), resolveEffectResources: true, configure: { configuration in
            configuration.materialConstants = [.init(pass: base, name: "phantom"): .init(value: SIMD4(2, 0, 0, 0), components: 1)]
            configuration.log = { _, message in diagnostics.append(message) }
        })
        scene.engine.start(state: &scene.state)
        XCTAssertEqual(scene.state.object("1")?.brightness, 7)
        XCTAssertNil(scene.state.passIndex(of: base))
        XCTAssertNil(scene.state.constant("phantom", of: base))
        XCTAssertNil(scene.state.passIndex(of: .init(objectID: "1", effectID: "5")))
        XCTAssertEqual(scene.engine.bindings.count, 1, "only the real layer alpha script is compiled; no material typed setter exists")
        XCTAssertEqual(diagnostics.filter { $0.contains("getMaterial has no resolved material") }.count, 1)
        XCTAssertEqual(scene.engine.exceptionCount, 0, scene.engine.exceptions.joined(separator: "\n"))
    }

    func testLayerQueriesReuseSceneWrappersAndReadLiveNames() throws {
        var diagnostics: [String] = []
        var scene = try Self.scene([
            Self.layer(1, "Shared", ["alpha": Self.scripted(1, """
            export function init() {
                const second = thisScene.getLayer(1), third = thisScene.getLayer(2);
                const byID = thisScene.getLayerByID('2');
                thisLayer.color = new Vec3(byID === second ? 1 : 99,
                    thisScene.getLayerIndex('Shared'), thisScene.getLayerIndex(byID));
                third.name = 'Renamed';
                thisLayer.origin = new Vec3(thisScene.getLayerIndex('Renamed'),
                    thisScene.getLayerIndex('Other'), thisScene.getLayerIndex(second));
                const numeric = thisScene.getLayerIndex(0) === 0;
                const invalid = thisScene.getLayerIndex({__index: 0}) === -1
                    && thisScene.getLayerIndex(thisScene) === -1;
                // These rejected branches are an explicit bounded product policy, not native failure expectations.
                const unsupported = thisScene.getLayerByID(2) === null && thisScene.getLayerByID('missing') === null;
                thisLayer.brightness = numeric && invalid && unsupported ? 7 : 99;
            }
            """)]),
            Self.layer(2, "Shared"),
            Self.layer(3, "Other"),
        ], assets: Self.fixedAssets(), configure: { configuration in
            configuration.log = { _, message in diagnostics.append(message) }
        })
        scene.engine.start(state: &scene.state)
        XCTAssertEqual(scene.state.object("1")?.color, SIMD3(1, 0, 1))
        XCTAssertEqual(scene.state.object("1")?.origin, SIMD3(2, -1, 1))
        XCTAssertEqual(scene.state.object("1")?.brightness, 7)
        XCTAssertEqual(diagnostics.filter { $0.contains("scene layer ID parsing is unsupported") }.count, 1)
        XCTAssertEqual(diagnostics.filter { $0.contains("getLayerByID is unsupported for a non-string ID") }.count, 1)
        XCTAssertEqual(diagnostics.filter { $0.contains("getLayerByID found no exact ID") }.count, 1)
        XCTAssertFalse(diagnostics.contains { $0.contains("getLayerIndex") },
                       "invalid wrapper misses use the shared resolver; they are not unverified ID parsing")
        XCTAssertEqual(scene.engine.exceptionCount, 0, scene.engine.exceptions.joined(separator: "\n"))
    }

    /// Literal expected pairs are the 42 actual H10 Windows rows (ss-3e240afac388431f), not output from
    /// the product's converter. Small decimals rule out Float32 rounding; +/-2^32 rule out reject/clamp.
    func testLayerIndexNumericProtocolMatchesWindowsH10WithoutChangingMaterialCoercion() throws {
        var diagnostics: [String] = []
        var scene = try Self.scene([
            Self.layer(1, "Witness"),
            Self.layer(2, "Driver", ["alpha": Self.scripted(1, """
            export function init() {
                const cases = [
                    [0, 0],
                    [1, 1],
                    [2, -1],
                    [0.99999999, 0],
                    [1.00000001, 1],
                    [1.99999999, 1],
                    [2.00000001, -1],
                    [0.999999940395355224609375, 0],
                    [1.00000011920928955078125, 1],
                    [1.99999988079071044921875, 1],
                    [2.0000002384185791015625, -1],
                    [2147483647, -1],
                    [2147483648, -1],
                    [2147483649, -1],
                    [4294967295, -1],
                    [4294967296, 0],
                    [4294967297, 1],
                    [-2147483649, -1],
                    [-2147483648, -1],
                    [-2147483647, -1],
                    [-4294967297, -1],
                    [-4294967296, 0],
                    [-4294967295, 1],
                    [-0, 0],
                    [-0.5, 0],
                    [-1, -1],
                    [-1.5, -1],
                    [-0.99999999, 0],
                    [-1.00000001, -1],
                    [-1.99999999, -1],
                    [-2.00000001, -1],
                    [NaN, 0],
                    [Infinity, 0],
                    [-Infinity, 0],
                    [2147483520, -1],
                    [2147483904, -1],
                    [4294967040, -1],
                    [4294967808, -1],
                    [-2147483904, -1],
                    [-2147483520, -1],
                    [-4294967808, -1],
                    [-4294967040, -1],
                ];
                for (const pair of cases) {
                    const actual = thisScene.getLayerIndex(pair[0]);
                    if (actual !== pair[1]) throw Error('H10 numeric ' + String(pair[0]) + ': ' + actual + ' vs ' + pair[1]);
                }
                if (![undefined, null, false, true].every(input => thisScene.getLayerIndex(input) === -1)
                    || thisScene.getLayerIndex() !== -1) throw Error('non-number must not use numeric conversion');
                thisLayer.color = new Vec3(cases.length, thisScene.getLayerIndex(thisLayer),
                    thisScene.getLayerIndex(thisScene.getLayer('Witness')));
                thisLayer.brightness = 7;
            }
            """)]),
        ], assets: Self.fixedAssets(), configure: { configuration in
            configuration.log = { _, message in diagnostics.append(message) }
        })
        scene.engine.start(state: &scene.state)
        XCTAssertEqual(scene.state.object("2")?.color, SIMD3(42, 1, 0))
        XCTAssertEqual(scene.state.object("2")?.brightness, 7)
        XCTAssertTrue(diagnostics.isEmpty,
                      "non-number misses follow the shared resolver without numeric conversion or unsupported warnings")
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

    /// Native block-align is strict Bool with a layout hook; background brightness is Float without that hook.
    func testTextBlockAlignAndBackgroundBrightnessDefaultsTypedWritesAndDirtyBoundary() throws {
        var scene = try Self.scene([
            ["id": 1, "name": "Default text", "text": "Audit", "alpha": Self.scripted(1, """
            if (thisLayer.blockalign !== false || thisLayer.backgroundbrightness !== 1)
                throw Error('text factory defaults');
            let frame = 0;
            export function update(value) {
                frame += 1;
                if (frame === 1) {
                    thisLayer.blockalign = 1;
                    thisLayer.backgroundbrightness = '9';
                } else {
                    thisLayer.blockalign = true;
                    thisLayer.backgroundbrightness = frame === 2 ? 2.5 : 3.5;
                }
                return value;
            }
            """)],
            ["id": 2, "name": "Authored text", "text": "Seed", "blockalign": true, "backgroundbrightness": 0.25,
             "alpha": Self.scripted(1, """
             export function init(value) {
                 if (thisLayer.blockalign !== true || thisLayer.backgroundbrightness !== 0.25)
                     throw Error('authored text fields');
                 return value;
             }
             """)],
        ], assets: Self.fixedAssets())
        scene.engine.start(state: &scene.state)
        let initialLayout = scene.state.generation(.textLayout)
        let initialFields = scene.state.scriptFieldsGeneration
        scene.engine.tick(dt: 0.01, state: &scene.state)
        XCTAssertEqual(scene.state.scriptField("blockalign", of: "1"), .vector(.zero))
        XCTAssertEqual(scene.state.scriptField("backgroundbrightness", of: "1"), .vector(SIMD4(1, 0, 0, 0)))
        XCTAssertEqual(scene.state.generation(.textLayout), initialLayout, "wrong typed writes cannot dirty layout")
        XCTAssertEqual(scene.state.scriptFieldsGeneration, initialFields)
        scene.engine.tick(dt: 0.01, state: &scene.state)
        XCTAssertEqual(scene.state.scriptField("blockalign", of: "1"), .vector(SIMD4(1, 0, 0, 0)))
        XCTAssertEqual(scene.state.scriptField("backgroundbrightness", of: "1"), .vector(SIMD4(2.5, 0, 0, 0)))
        XCTAssertEqual(scene.state.generation(.textLayout), initialLayout + 1)
        let changedFields = scene.state.scriptFieldsGeneration
        scene.engine.tick(dt: 0.01, state: &scene.state)
        XCTAssertEqual(scene.state.scriptField("backgroundbrightness", of: "1"), .vector(SIMD4(3.5, 0, 0, 0)))
        XCTAssertEqual(scene.state.generation(.textLayout), initialLayout + 1, "background scale has no native layout hook")
        XCTAssertEqual(scene.state.scriptFieldsGeneration, changedFields + 1)
        let sameFields = scene.state.scriptFieldsGeneration
        scene.engine.tick(dt: 0.01, state: &scene.state)
        XCTAssertEqual(scene.state.scriptFieldsGeneration, sameFields, "same values do not schedule new work")
        XCTAssertEqual(scene.state.generation(.textLayout), initialLayout + 1)
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
