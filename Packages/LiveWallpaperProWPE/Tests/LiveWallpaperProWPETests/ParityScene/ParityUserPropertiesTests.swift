import Foundation
import LiveWallpaperCore
@testable import LiveWallpaperProWPE
import XCTest

final class ParityUserPropertiesTests: XCTestCase {
    func testBloomDocumentDeltaAppliesOnlyChangedValidBoolAndPreservesLiveScriptValue() throws {
        let source = #"""
        {"camera":{"eye":"0 0 0","center":"0 0 -1","up":"0 1 0"},
         "general":{"orthogonalprojection":{"width":32,"height":32},"bloom":{"user":"toggle","value":true}},
         "objects":[{"id":1,"image":"models/surface.json","alpha":{"user":"fade","value":1}}]}
        """#
        func document(_ bloom: WallpaperEngineProjectPropertyValue, alpha: Double = 1) throws -> WPESceneDocument {
            try WPESceneDocumentParser.parse(data: Data(source.utf8),
                                             userValues: ["toggle": bloom, "fade": .number(alpha)],
                                             makeTransformScriptResolver: { _, _ in UserPropertiesNoScripts() })
        }
        let before = try document(.bool(false))
        let enabled = try document(.bool(true))
        XCTAssertEqual(WPEParityUserProperties.bindings(document: before)["toggle"]?.first?.action, .incremental)
        var state = WPEParitySceneState(document: before, hdr: false)
        state.setScriptField("bloom", of: "", to: .vector(.zero), invalidating: .none)
        let constantsGeneration = state.generation(.bloom)
        let enable = try XCTUnwrap(WPEParityUserPropertyUpdate(from: before, to: enabled))
        XCTAssertEqual(enable.sceneBloom, true)
        enable.apply(to: &state)
        XCTAssertEqual(state.scriptField("bloom", of: ""), .vector(SIMD4(1, 0, 0, 0)))

        // A script changed the running field after the document seed. An unrelated fade must not reset it.
        state.setScriptField("bloom", of: "", to: .vector(.zero), invalidating: .none)
        let fieldsGeneration = state.scriptFieldsGeneration
        let faded = try document(.bool(true), alpha: 0.25)
        let unrelated = try XCTUnwrap(WPEParityUserPropertyUpdate(from: enabled, to: faded))
        XCTAssertNil(unrelated.sceneBloom)
        unrelated.apply(to: &state)
        XCTAssertEqual(state.object("1")?.alpha, 0.25)
        XCTAssertEqual(state.scriptField("bloom", of: ""), .vector(.zero))
        XCTAssertEqual(state.scriptFieldsGeneration, fieldsGeneration)

        let invalid = try document(.number(0), alpha: 0.25)
        let reject = try XCTUnwrap(WPEParityUserPropertyUpdate(from: faded, to: invalid))
        XCTAssertNil(reject.sceneBloom)
        reject.apply(to: &state)
        XCTAssertEqual(state.scriptField("bloom", of: ""), .vector(.zero), "Invalid new input must not become defaulttrue")

        // Old invalid is not defaulttrue when comparing: a newly accepted true must still reach the live field.
        let recover = try XCTUnwrap(WPEParityUserPropertyUpdate(from: invalid, to: faded))
        XCTAssertEqual(recover.sceneBloom, true)
        recover.apply(to: &state)
        XCTAssertEqual(state.scriptField("bloom", of: ""), .vector(SIMD4(1, 0, 0, 0)))
        let same = try XCTUnwrap(WPEParityUserPropertyUpdate(from: faded, to: faded))
        XCTAssertNil(same.sceneBloom)
        let recoveredGeneration = state.scriptFieldsGeneration
        same.apply(to: &state)
        XCTAssertEqual(state.scriptFieldsGeneration, recoveredGeneration)
        let string = try document(.string("0"), alpha: 0.25)
        let rejectString = try XCTUnwrap(WPEParityUserPropertyUpdate(from: faded, to: string))
        XCTAssertNil(rejectString.sceneBloom)
        rejectString.apply(to: &state)
        XCTAssertEqual(state.scriptField("bloom", of: ""), .vector(SIMD4(1, 0, 0, 0)))
        XCTAssertEqual(state.generation(.bloom), constantsGeneration, "No Float bloom-constant hook is synthesized")
    }

    func testUserGeneralZoomBindsLiveAndWritesTheSceneZoom() throws {
        let source = #"""
        {"camera":{"eye":"0 0 0","center":"0 0 -1","up":"0 1 0"},
         "general":{"orthogonalprojection":{"width":32,"height":32},"zoom":{"user":"lens","value":1}},
         "objects":[{"id":1,"image":"models/surface.json"}]}
        """#
        func document(_ zoom: Double) throws -> WPESceneDocument {
            try WPESceneDocumentParser.parse(data: Data(source.utf8), userValues: ["lens": .number(zoom)],
                                             makeTransformScriptResolver: { _, _ in UserPropertiesNoScripts() })
        }
        let before = try document(1)
        XCTAssertEqual(WPEParityUserProperties.bindings(document: before)["lens"]?.first?.action, .incremental)
        let update = try XCTUnwrap(WPEParityUserPropertyUpdate(from: before, to: document(1.5)))
        XCTAssertEqual(update.sceneFloats.filter { $0.name == "zoom" }.map(\.value), [1.5])
        var state = WPEParitySceneState(document: before, hdr: false)
        update.apply(to: &state)
        XCTAssertEqual(state.scriptField("zoom", of: ""), .vector(SIMD4(1.5, 0, 0, 0)))
    }

    func testCameraObjectZoomFovAndParallaxDepthBindLiveAndWriteScriptFields() throws {
        let source = #"""
        {"camera":{"eye":"0 0 0","center":"0 0 -1","up":"0 1 0"},
         "general":{"orthogonalprojection":{"width":32,"height":32}},
         "objects":[
          {"id":1,"image":"models/surface.json","parallaxDepth":{"user":"depth","value":"1 1"}},
          {"id":3,"text":"Hi","parallaxDepth":{"user":"flag","value":true}},
          {"id":4,"camera":"default","zoom":{"user":"lens","value":1},"fov":{"user":"angle","value":50}}
         ]}
        """#
        func document(lens: Double = 1, angle: Double = 50, depth: WallpaperEngineProjectPropertyValue = .string("1 1"),
                      flag: Bool = true) throws -> WPESceneDocument {
            try WPESceneDocumentParser.parse(data: Data(source.utf8),
                                             userValues: ["lens": .number(lens), "angle": .number(angle),
                                                          "depth": depth, "flag": .bool(flag)],
                                             makeTransformScriptResolver: { _, _ in UserPropertiesNoScripts() })
        }
        let before = try document()
        let bindings = WPEParityUserProperties.bindings(document: before)
        for key in ["depth", "flag", "lens", "angle"] {
            XCTAssertEqual(bindings[key]?.map(\.action), [.incremental], key)
        }
        var state = WPEParitySceneState(document: before, hdr: false)
        let changed = try document(lens: 1.5, angle: 70, depth: .string("0.25 0.5"), flag: false)
        try XCTUnwrap(WPEParityUserPropertyUpdate(from: before, to: changed)).apply(to: &state)
        XCTAssertEqual(state.scriptField("zoom", of: "4"), .vector(SIMD4(1.5, 0, 0, 0)))
        XCTAssertEqual(state.scriptField("fov", of: "4"), .vector(SIMD4(70, 0, 0, 0)))
        XCTAssertEqual(state.scriptField("parallaxDepth", of: "1"), .vector(SIMD4(0.25, 0.5, 0, 0)))
        XCTAssertNil(state.scriptField("parallaxDepth", of: "3"), "a Bool keeps the running value")

        let number = try document(lens: 1.5, angle: 70, depth: .number(0.5), flag: false)
        try XCTUnwrap(WPEParityUserPropertyUpdate(from: changed, to: number)).apply(to: &state)
        XCTAssertEqual(state.scriptField("parallaxDepth", of: "1"), .vector(SIMD4(0.5, 0.5, 0, 0)))
        let single = try document(lens: 1.5, angle: 70, depth: .string("0.5"), flag: false)
        try XCTUnwrap(WPEParityUserPropertyUpdate(from: number, to: single)).apply(to: &state)
        XCTAssertEqual(state.scriptField("parallaxDepth", of: "1"), .vector(SIMD4(0.5, 0, 0, 0)))
    }

    func testBoolUserValueKeepsAuthoredParallaxDepthAndOneTokenLeavesYZero() throws {
        let source = #"""
        {"camera":{"eye":"0 0 0","center":"0 0 -1","up":"0 1 0"},
         "general":{"orthogonalprojection":{"width":32,"height":32}},
         "objects":[
          {"id":1,"image":"models/surface.json","parallaxDepth":{"user":"flag","value":"0.25 0.5"}},
          {"id":2,"image":"models/surface.json","parallaxDepth":{"user":"depth","value":"1 1"}}
         ]}
        """#
        let document = try WPESceneDocumentParser.parse(data: Data(source.utf8),
                                                        userValues: ["flag": .bool(true), "depth": .string("0.5")],
                                                        makeTransformScriptResolver: { _, _ in UserPropertiesNoScripts() })
        let images = Dictionary(uniqueKeysWithValues: document.imageObjects.map { ($0.id, $0.parallaxDepth) })
        XCTAssertEqual(images["1"], SIMD2(0.25, 0.5))
        XCTAssertEqual(images["2"], SIMD2(0.5, 0))
    }

    func testBoolUserValueKeepsAuthoredNumericFieldsAndConstants() throws {
        let source = #"""
        {"camera":{"eye":"0 0 0","center":"0 0 -1","up":"0 1 0"},
         "general":{"orthogonalprojection":{"width":32,"height":32}},
         "objects":[
          {"id":1,"image":"models/surface.json","alpha":{"user":"flag","value":0.5},
           "effects":[{"id":2,"file":"effects/opacity/effect.json","visible":{"user":"flag","value":false},
                       "passes":[{"constantshadervalues":{"alpha":{"user":"flag","value":0}}}]}]},
          {"id":4,"text":"Hi","pointsize":{"user":"flag","value":10}},
          {"id":5,"image":"models/surface.json",
           "brightness":{"user":"flag","value":2,"script":"export function update(v){return v;}"}}
         ]}
        """#
        func document(_ flag: Bool) throws -> WPESceneDocument {
            try WPESceneDocumentParser.parse(data: Data(source.utf8), userValues: ["flag": .bool(flag)],
                                             makeTransformScriptResolver: { _, _ in UserPropertiesNoScripts() })
        }
        let on = try document(true)
        let image = try XCTUnwrap(on.imageObjects.first { $0.id == "1" })
        XCTAssertEqual(image.alpha, 0.5)
        let effect = try XCTUnwrap(image.effects.first)
        XCTAssertEqual(effect.passOverrides.first?.constants["alpha"], .number(0))
        XCTAssertTrue(effect.visible, "a Bool field still takes the Bool user value")
        XCTAssertEqual(WPEParityTextObject.textObjects(in: on).first { $0.id == "4" }?.pointSize, 10)
        XCTAssertEqual(on.textObjects.first { $0.id == "4" }?.pointSize, 10)
        let scripted = on.resolvedObjectsJSON.first { $0["id"] == .number(5) }
        XCTAssertEqual(scripted?["brightness"]?["value"], .number(2))

        let update = try XCTUnwrap(WPEParityUserPropertyUpdate(from: on, to: document(false)))
        XCTAssertEqual(update.objects.filter { $0.id == "1" && $0.property == .alpha }, [])
        XCTAssertEqual(update.constants, [])
        XCTAssertTrue(update.effects.contains {
            $0.effect == .init(objectID: "1", effectID: "2") && !$0.visible
        }, "\(update.effects)")
    }

    func testMaterialConstantKeepsAuthoredNumberForBoolUserValue() {
        XCTAssertEqual(WPEParityProgramConstants.components(.object(["user": .string("k"), "value": .number(0.5)]),
                                                            userValues: ["k": .bool(true)]), [0.5])
    }

    func testMaterialFileUserConstantsBindLiveAndFollowAChange() throws {
        let objects: [[String: Any]] = [
            ["id": 7, "image": "models/7.json", "size": "400 200", "alpha": ["user": "k", "value": 1]],
            ["id": 8, "image": "models/8.json", "size": "400 200"],
            ["id": 9, "image": "models/9.json", "size": "400 200",
             "instance": ["constantshadervalues": ["emissivebrightness": 3]]],
        ]
        let old: [String: WallpaperEngineProjectPropertyValue] = ["k": .number(1), "m": .number(0.5)]
        let new: [String: WallpaperEngineProjectPropertyValue] = ["k": .number(0.25), "m": .number(0.5)]
        let (before, scene) = try Self.materialScene(objects: objects, userValues: old)
        let (after, _) = try Self.materialScene(objects: objects, userValues: new)

        let bindings = WPEParityUserProperties.bindings(scene: scene)
        XCTAssertEqual(bindings["k"], [WPEScenePropertyBinding(
            propertyKey: "k", target: .shaderUniform(objectID: "7", effectID: nil, passID: nil, name: "emissivebrightness"),
            kind: .uniform, action: .incremental
        )], "object 9's instance override replaces the material entry, so it has no watch")
        XCTAssertEqual(bindings["m"], [WPEScenePropertyBinding(
            propertyKey: "m", target: .shaderUniform(objectID: "8", effectID: nil, passID: nil, name: "emissivebrightness"),
            kind: .uniform, action: .incremental
        )])

        var state = WPEParitySceneState(scene: scene, document: before)
        var update = try XCTUnwrap(WPEParityUserPropertyUpdate(from: before, to: after))
        update.resolveMaterialFiles(of: scene, values: new, changed: ["k"])
        update.apply(to: &state)
        func constant(_ id: String) -> WPEParitySceneState.Constant? {
            state.constant("emissivebrightness", of: WPEParityMaterialPassKey(objectID: id))
        }
        XCTAssertEqual(constant("7"), WPEParitySceneState.Constant(components: [0.25]))
        XCTAssertEqual(state.object("7")?.alpha, 0.25)
        XCTAssertEqual(constant("8"), WPEParitySceneState.Constant(components: [0.5]))
        let unchanged = try XCTUnwrap(state.passIndex(of: WPEParityMaterialPassKey(objectID: "8")))
        XCTAssertEqual(state.constantGeneration(pass: unchanged), 0)
        XCTAssertEqual(constant("9"), WPEParitySceneState.Constant(components: [3]))
    }

    func testModelWithSeveralMaterialsKeepsItsMaterialFileBindingsOnReload() throws {
        let objects: [[String: Any]] = [["id": 5, "image": "models/m.mdl", "size": "400 200"]]
        let model = SeveralMaterialModelFixture.data(materials: ["materials/k.json", "materials/m.json"])
        let old: [String: WallpaperEngineProjectPropertyValue] = ["k": .number(1), "m": .number(0.5)]
        let new: [String: WallpaperEngineProjectPropertyValue] = ["k": .number(0.25), "m": .number(0.75)]
        let (before, scene) = try Self.materialScene(objects: objects, binaries: ["models/m.mdl": model], userValues: old)
        let (after, _) = try Self.materialScene(objects: objects, binaries: ["models/m.mdl": model], userValues: new)

        let bindings = WPEParityUserProperties.bindings(scene: scene)
        for key in ["k", "m"] {
            XCTAssertEqual(bindings[key], [WPEScenePropertyBinding(
                propertyKey: key, target: .shaderUniform(objectID: "5", effectID: nil, passID: nil,
                                                         name: "emissivebrightness"),
                kind: .uniform, action: .reload
            )], "both meshes share one state pass")
        }
        var update = try XCTUnwrap(WPEParityUserPropertyUpdate(from: before, to: after))
        update.resolveMaterialFiles(of: scene, values: new, changed: ["k", "m"])
        XCTAssertEqual(update.constants, [])
    }

    func testTextSoundParticleScriptedAndScriptPropertyEnvelopesBindLive() throws {
        let bindings = try WPEParityUserProperties.bindings(document: Self.liveTargetsDocument())
        func live(_ key: String, _ target: WPEScenePropertyBindingTarget,
                  _ kind: WPEScenePropertyBindingKind) -> [WPEScenePropertyBinding] {
            [WPEScenePropertyBinding(propertyKey: key, target: target, kind: kind, action: .incremental)]
        }
        XCTAssertEqual(Set(bindings.keys), ["tint", "show", "tinted", "gate", "music", "rain", "hue", "level"])
        XCTAssertEqual(bindings["tint"], live("tint", .textObject(id: "5"), .color))
        XCTAssertEqual(bindings["show"], live("show", .textObject(id: "5"), .visible))
        XCTAssertEqual(bindings["tinted"], live("tinted", .imageEffect(objectID: "5", effectID: "7"), .visible))
        XCTAssertEqual(bindings["gate"], live("gate", .imageObject(id: "6"), .visible),
                       "a scripted field keeps its user watch")
        XCTAssertEqual(bindings["music"], live("music", .soundObject(id: "8"), .volume))
        XCTAssertEqual(bindings["rain"], live("rain", .particleObject(id: "9"), .resource))
        XCTAssertEqual(bindings["hue"], live("hue", .particleObject(id: "9"), .resource))
        XCTAssertEqual(bindings["level"], live("level", .objectResource(objectID: "10", field: "alpha.scriptproperties.level"),
                                               .scriptProperty))
    }

    func testColourChangesWriteStateWithoutReLayingText() throws {
        let before = try Self.liveTargetsDocument(["tint": .string("1 1 1"), "music": .number(1), "rain": .number(1),
                                                   "hue": .string("1 1 1")])
        let after = try Self.liveTargetsDocument(["tint": .string("1 0 0"), "music": .number(0.25), "rain": .number(3),
                                                  "hue": .string("1 0 0")])
        let update = try XCTUnwrap(WPEParityUserPropertyUpdate(from: before, to: after))
        XCTAssertEqual(update.texts, [], "a colour change alone does not re-lay the text")
        XCTAssertTrue(update.objects.contains {
            $0.id == "5" && $0.property == .color && SIMD3($0.value.x, $0.value.y, $0.value.z) == SIMD3(1, 0, 0)
        }, "\(update.objects)")
        XCTAssertEqual(update.sounds, [.init(id: "8", volume: 0.25)])

        var state = WPEParitySceneState(document: before, hdr: false)
        update.apply(to: &state)
        XCTAssertEqual(state.scriptField("instance.count", of: "9"), .vector(SIMD4(3, 0, 0, 0)))
        XCTAssertEqual(state.scriptField("instance.colorn", of: "9"), .vector(SIMD4(1, 0, 0, 0)))
    }

    /// Text 5 (with tint effect 7), scripted image 6, sound 8, particle 9 and image 10 whose alpha script binds a
    /// scriptproperty, every envelope user-bound.
    private static func liveTargetsDocument(_ userValues: [String: WallpaperEngineProjectPropertyValue] = [:]) throws
        -> WPESceneDocument {
        let source = #"""
        {"camera":{"eye":"0 0 0","center":"0 0 -1","up":"0 1 0"},
         "general":{"orthogonalprojection":{"width":32,"height":32}},
         "objects":[
          {"id":5,"text":"Hi","color":{"user":"tint","value":"1 1 1"},"visible":{"user":"show","value":true},
           "effects":[{"id":7,"file":"effects/tint/effect.json","visible":{"user":"tinted","value":true}}]},
          {"id":6,"image":"models/a.json",
           "visible":{"user":"gate","value":true,"script":"export function update(v){return v;}"}},
          {"id":8,"sound":["sounds/a.flac"],"volume":{"user":"music","value":1}},
          {"id":9,"particle":"particles/p.json",
           "instanceoverride":{"count":{"user":"rain","value":1},"colorn":{"user":"hue","value":"1 1 1"}}},
          {"id":10,"image":"models/b.json",
           "alpha":{"value":1,"script":"export var scriptProperties = createScriptProperties().addSlider({name:'level',value:1}).finish(); export function update(v){return v;}",
                    "scriptproperties":{"level":{"user":"level","value":1}}}}
         ]}
        """#
        return try WPESceneDocumentParser.parse(data: Data(source.utf8), userValues: userValues,
                                                makeTransformScriptResolver: { _, _ in UserPropertiesNoScripts() })
    }

    /// Image layers drawing `shaders/probe` through `materials/k.json` (user `k`, value 2.3) or `materials/m.json`
    /// (user `m`, value 0.5), parsed and loaded with `userValues`.
    private static func materialScene(objects: [[String: Any]], binaries: [String: Data] = [:],
                                      userValues: [String: WallpaperEngineProjectPropertyValue]) throws
        -> (WPESceneDocument, WPEParityProgramScene) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("parity-user-material-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func material(_ key: String, _ value: Double) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["passes": [[
                "shader": "probe", "blending": "translucent",
                "constantshadervalues": ["emissivebrightness": ["user": key, "value": value]],
            ]]])
        }
        var files: [String: Data] = try [
            "shaders/probe.vert": Data("void main() {}\n".utf8),
            "shaders/probe.frag": Data("""
            uniform float g_EmissiveBrightness; // {"material":"emissivebrightness","default":1.0}
            void main() {}
            """.utf8),
            "materials/k.json": material("k", 2.3),
            "materials/m.json": material("m", 0.5),
            "models/7.json": JSONSerialization.data(withJSONObject: ["material": "materials/k.json"]),
            "models/8.json": JSONSerialization.data(withJSONObject: ["material": "materials/m.json"]),
            "models/9.json": JSONSerialization.data(withJSONObject: ["material": "materials/k.json"]),
        ]
        files.merge(binaries) { _, new in new }
        for (path, data) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        let sceneJSON = try JSONSerialization.data(withJSONObject: [
            "camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 1920, "height": 1080]],
            "objects": objects,
        ])
        let document = try WPESceneDocumentParser.parse(data: sceneJSON, userValues: userValues,
                                                        makeTransformScriptResolver: { _, _ in UserPropertiesNoScripts() })
        var assets = WPEParityProgramAssets(sceneDirectory: root, assetRoots: [])
        assets.userValues = userValues
        return (document, WPEParityProgramScene(document: document, assets: assets, settings: WPEParityProgramSettings()))
    }
}

/// MDLV0016 static scene model with one quad submesh per material path.
private enum SeveralMaterialModelFixture {
    static func data(materials: [String]) -> Data {
        var data = Data()
        data.append(contentsOf: Array("MDLV0016".utf8))
        data.appendLittleEndian(UInt32(0x0000_0F00))
        data.append(UInt8(0))
        data.appendLittleEndian(UInt32(1))
        data.appendLittleEndian(UInt32(materials.count))
        for (index, material) in materials.enumerated() {
            data.appendNullTerminated(material)
            data.appendLittleEndian(UInt32(0))
            data.appendLittleEndian(UInt32(0x0000_000F))
            let minX = Float(index * 2)
            var vertices = Data()
            vertices.appendQuadVertex(position: SIMD3<Float>(minX, 0, 0), uv: SIMD2<Float>(0, 1))
            vertices.appendQuadVertex(position: SIMD3<Float>(minX + 1, 0, 0), uv: SIMD2<Float>(1, 1))
            vertices.appendQuadVertex(position: SIMD3<Float>(minX, 1, 0), uv: SIMD2<Float>(0, 0))
            data.appendLittleEndian(UInt32(vertices.count))
            data.append(vertices)
            data.appendLittleEndian(UInt32(3 * MemoryLayout<UInt16>.size))
            for vertexIndex: UInt16 in [0, 1, 2] {
                data.appendLittleEndian(vertexIndex)
            }
        }
        return data
    }
}

private extension Data {
    mutating func appendLittleEndian(_ value: UInt16) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendLittleEndian(_ value: UInt32) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendLittleEndian(_ value: Float) {
        appendLittleEndian(value.bitPattern)
    }

    mutating func appendNullTerminated(_ string: String) {
        append(contentsOf: Array(string.utf8))
        append(UInt8(0))
    }

    /// Position, normal, tangent (vec4), UV: the 0x0F vertex layout.
    mutating func appendQuadVertex(position: SIMD3<Float>, uv: SIMD2<Float>) {
        for value in [position.x, position.y, position.z, 0, 0, 1, 1, 0, 0, 1, uv.x, uv.y] {
            appendLittleEndian(value)
        }
    }
}

private struct UserPropertiesNoScripts: WPESceneTransformScriptResolving {
    func resolveVec3(script _: String, properties _: [String: WPESceneScriptPropertyValue],
                     seed _: SIMD3<Double>) -> SIMD3<Double>? {
        nil
    }
}
