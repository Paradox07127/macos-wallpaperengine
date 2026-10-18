import Foundation
import LiveWallpaperCore
@testable import LiveWallpaperProWPE
import XCTest

final class ParityProgramBindingTests: XCTestCase {
    func testFrameReadCandidatesListOnlySamplerDefaultsDeclaredUnderTheMaterialCombos() {
        let files = [
            "shaders/reflective.vert": Data("void main() {}".utf8),
            "shaders/reflective.frag": Data("""
            // [COMBO] {"combo":"REFLECTION","default":1}
            uniform sampler2D g_Texture0; // {"default":"util/white"}
            #if REFLECTION
            uniform sampler2D g_Texture3; // {"default":"_rt_MipMappedFrameBuffer"}
            #endif
            void main() {}
            """.utf8),
        ]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("frame-reads-\(UUID().uuidString)")
        let assets = WPEParityProgramAssets(sources: [.lookup(root) { files[$0] }])
        var material = WPEParityProgramMaterial(shader: "reflective", combos: ["REFLECTION": 0], textures: [0: "albedo"])
        func reads() -> [String] {
            WPEParityProgramBuilder.resolvedFrameTextureNames(material, engineFlags: .init(), assets: assets)
        }
        XCTAssertEqual(reads(), ["albedo"])
        material.combos = [:]
        XCTAssertEqual(reads(), ["albedo", "_rt_MipMappedFrameBuffer"], "the shader's combo default enables the declaration")
    }

    /// Material and annotation names reach the same real RT binding/read; compiled activity is the app's separate
    /// request fact. An RT name no frame resource declares binds as a texture asset.
    func testMipSnapshotDefaultsAndExplicitSlotsKeepTheSameDeclaredHistoryRead() throws {
        for effectPass in [false, true] {
            for explicit in [false, true] {
                let name = "_rt_MipMappedFrameBuffer"
                let material: [String: Any] = ["passes": [[
                    "shader": "mip-reader", "blending": "normal",
                    "textures": explicit ? ["previous", name, "_rt_Unknown"] : ["previous"],
                ]]]
                var layer = ParitySceneDocuments.layer(effects: effectPass ? [
                    .init(id: "1", passes: [ParitySceneDocuments.pass("mip-reader")]),
                ] : [])
                if !effectPass {
                    layer.model = ["material": "materials/mip-reader.json"]
                }
                var object = layer.json
                object["effects"] = effectPass ? [["id": 1, "file": "effects/mip-reader.json"]] : []
                var files = try [
                    "models/7.json": JSONSerialization.data(withJSONObject: layer.model),
                    "materials/genericimage2.json": JSONSerialization.data(withJSONObject: [
                        "passes": [["shader": "genericimage2", "blending": "translucent"]],
                    ]),
                    "materials/mip-reader.json": JSONSerialization.data(withJSONObject: material),
                    "effects/mip-reader.json": JSONSerialization.data(withJSONObject: [
                        "passes": [ParitySceneDocuments.pass("mip-reader")],
                    ]),
                ]
                files["shaders/mip-reader.vert"] = Data("void main() {}".utf8)
                files["shaders/mip-reader.frag"] = Data("""
                uniform sampler2D g_Texture1; // {"default":"_rt_MipMappedFrameBuffer"}
                uniform sampler2D g_Texture2; // {"default":"_rt_Unknown"}
                void main() {}
                """.utf8)
                let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: [
                    "camera": ["center": "0 0 0"],
                    "general": ["orthogonalprojection": ["width": 1920, "height": 1080]],
                    "objects": [object],
                ]), userValues: [:], makeTransformScriptResolver: { _, _ in NoScripts() })
                // Binding resolves annotations after scene conversion; retain the same shader bytes for both.
                let snapshot = files
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("mip-binding-\(UUID().uuidString)")
                let scene = WPEParityProgramScene(document: document,
                                                  assets: WPEParityProgramAssets(sources: [.lookup(root) { snapshot[$0] }]),
                                                  settings: .init(mipMappedFrameBufferEnabled: false))
                var post = scene.postProcess
                post.sceneMipMappedFrameBufferEnabled = true // A supplied preparation fact, not annotation inference.
                let frame = try WPEParityFrameComposer.compose(scene: scene.scene, post: post)
                let operation = try XCTUnwrap(frame.draws.first { _, draw in
                    guard case let .scene(draw) = draw else { return false }
                    return draw.shader == "mip-reader"
                }?.key)
                guard case let .scene(draw)? = frame.draws[operation] else { return XCTFail("missing scene draw") }
                let label = "effect=\(effectPass), explicit=\(explicit)"
                XCTAssertTrue(draw.reads.contains(WPEResourceID(name)), label)
                XCTAssertFalse(draw.reads.contains("_rt_Unknown"), "unknown producer stays unsupported: \(label)")
                let binding = try XCTUnwrap(WPEParityProgramBuilder.bindings(frame: frame, scene: scene)[operation])
                XCTAssertEqual(binding.textures[1], .resource(WPEResourceID(name)), label)
                XCTAssertEqual(binding.textures[2], .asset("_rt_Unknown"), label)
                let graph = try WPERenderGraphCompiler.compile(resources: frame.resources, operations: frame.operations)
                let read = try XCTUnwrap(graph.accesses[operation].reads.first {
                    $0.subresource.resource == WPEResourceID(name)
                })
                XCTAssertEqual(read.revision, 0, "before tail copy, this is frame-entry history: \(label)")
                XCTAssertNil(read.producer, label)
                XCTAssertEqual(graph.storage[WPEResourceID(name)], .dedicated, label)
                XCTAssertFalse(frame.operations.contains {
                    if case .generateMips = $0.kind {
                        true
                    } else {
                        false
                    }
                }, label)
            }
        }
    }

    /// 1401ebf60.c:135-141: a layer effect pass without a bind table samples the layer's current input in slot 0,
    /// whatever name its material authors there; a shape layer passes no layer index (14025faf0.c:160) and keeps it.
    func testUnboundEffectPassSamplesLayerInputInSlotZeroOverAuthoredName() throws {
        let authored = "_rt_imageLayerComposite_7_b"
        let layer = ParitySceneDocuments.layer(effects: [
            ParitySceneDocuments.effect(passes: [ParitySceneDocuments.pass("fx")]),
        ])
        let shape: [String: Any] = ["id": 9, "name": "9", "shape": "quad",
                                    "effects": [["id": 1, "file": "effects/shape.json", "visible": true]]]
        let scene = try ParitySceneDocuments.programScene([layer], objects: [shape], files: [
            "materials/fx.json": #"{"passes":[{"shader":"fx","blending":"translucent","textures":["\#(authored)"]}]}"#,
            "materials/shapefx.json": #"""
            {"passes":[{"shader":"shapefx","blending":"translucent","textures":["util/authored"]}]}
            """#,
            "effects/shape.json": #"{"passes":[{"material":"materials/shapefx.json"}]}"#,
        ])
        let frame = try WPEParityFrameComposer.compose(scene: scene.scene, post: scene.postProcess)
        let bindings = WPEParityProgramBuilder.bindings(frame: frame, scene: scene)
        func effectDraw(_ objectID: String) throws -> (operation: Int, draw: WPEParitySceneDraw) {
            let found = frame.draws.compactMap { operation, draw -> (Int, WPEParitySceneDraw)? in
                guard case let .scene(scene) = draw, scene.objectID == objectID, scene.effectID != nil else { return nil }
                return (operation, scene)
            }
            return try XCTUnwrap(found.first, "object \(objectID) plans no effect pass")
        }
        let (operation, draw) = try effectDraw("7")
        let input = try XCTUnwrap(draw.reads.first)
        XCTAssertNotEqual(input, WPEResourceID(authored))
        XCTAssertEqual(bindings[operation]?.textures[0], .resource(input),
                       "slot 0 samples the authored name, which the frame never declares")
        let shapeOperation = try effectDraw("9").operation
        XCTAssertEqual(bindings[shapeOperation]?.textures[0], .asset("util/authored"))
    }

    private static func floats(_ value: WPECBufferValue?) -> [Float]? {
        switch value {
        case let .float(number)?: [number]
        case let .vector(vector)?: vector
        default: nil
        }
    }

    func testAnnotationDefaultsFillOnlyKeysTheMaterialLacks() {
        let uniforms = WPEParityProgramConstants.uniforms("""
        uniform mat4 g_ModelViewProjectionMatrix;
        uniform float g_Speed; // {"material":"speeduv","default":5}
        \tuniform vec2 g_Bounds; // {"material":"bounds","default":"0 1"}
        uniform vec4 g_Tint; // {"material":"tint","type":"color","default":"1 0.5 0.25"}
        uniform float g_Ratio; // {"material":"ratio","default":0.3}
        uniform vec3 g_NoDefault; // {"material":"nodefault"}
        uniform float g_Engine;
        uniform sampler2D g_Texture0; // {"default":"util/noise"}
        """)
        XCTAssertEqual(Set(uniforms.keys), ["g_Speed", "g_Bounds", "g_Tint", "g_Ratio", "g_NoDefault"])

        let constants = WPEParityProgramConstants.resolve(uniforms, values: ["ratio": [0.7], "bounds": [0.2, 0.8]])
        XCTAssertEqual(Self.floats(constants["g_Speed"]), [5])
        XCTAssertEqual(Self.floats(constants["g_Ratio"]), [0.7])
        XCTAssertEqual(Self.floats(constants["g_Bounds"]), [0.2, 0.8])
        // A colour default with fewer numbers than the vector pads with zero.
        XCTAssertEqual(Self.floats(constants["g_Tint"]), [1, 0.5, 0.25, 0])
        XCTAssertNil(constants["g_NoDefault"])
    }

    /// foliagesway maps `g_Speed` to `speed` in the vertex stage and `speeduv` in the fragment stage.
    func testEachStageResolvesItsOwnAnnotationsAndInstanceConstantsOverrideTheMaterial() throws {
        let binding = try Self.probeBinding(
            vertex: """
            uniform float g_Speed; // {"material":"speed","default":1}
            uniform float g_Direction; // {"material":"direction","default":3.14159265358,"conversion":"rad2deg"}
            uniform float g_Phase; // {"material":"phase","default":0.5}
            """,
            fragment: """
            uniform float g_Speed; // {"material":"speeduv","default":2}
            uniform vec2 g_Bounds; // {"material":"bounds","default":"0 1"}
            uniform float g_Ratio; // {"material":"ratio","default":0.3}
            """,
            material: ["speeduv": 5, "bounds": "0.1 0.9", "direction": -1.5707963, "ratio": 0.6],
            instance: ["bounds": "0.25 0.75", "phase": 0.125]
        )
        let vertex = try XCTUnwrap(binding.constants[.vertex])
        let fragment = try XCTUnwrap(binding.constants[.fragment])
        XCTAssertNil(binding.constants[.geometry])
        XCTAssertEqual(Self.floats(vertex["g_Speed"]), [1])
        XCTAssertEqual(Self.floats(fragment["g_Speed"]), [5])
        XCTAssertNil(vertex["g_Bounds"])
        // Material and scene angles are already radians; rad2deg only scales SceneScript input.
        XCTAssertEqual(Self.floats(vertex["g_Direction"]), [-1.5707963])
        XCTAssertEqual(binding.materialConstants[.vertex]?.first { $0.name == "g_Direction" }?.angle, true)
        XCTAssertEqual(binding.materialConstants[.vertex]?.first { $0.name == "g_Speed" }?.angle, false)
        // Instance values replace material values, and both win over annotation defaults.
        XCTAssertEqual(Self.floats(fragment["g_Bounds"]), [0.25, 0.75])
        XCTAssertEqual(Self.floats(vertex["g_Phase"]), [0.125])
        XCTAssertEqual(Self.floats(fragment["g_Ratio"]), [0.6])
        for stage in [vertex, fragment] {
            XCTAssertEqual(Self.floats(stage["g_Color4"]), [1, 1, 1, 1])
            XCTAssertEqual(Self.floats(stage["g_Alpha"]), [1])
        }
    }

    func testInstanceConstantsTakeTheUserPropertyValue() throws {
        func speed(_ userValues: [String: WallpaperEngineProjectPropertyValue]) throws -> [Float]? {
            let binding = try Self.probeBinding(vertex: "", fragment: """
                                                uniform float g_Speed; // {"material":"speed","default":2}
                                                """,
                                                material: ["speed": 5],
                                                instance: ["speed": ["user": "speed", "value": 1]],
                                                userValues: userValues)
            return Self.floats(binding.constants[.fragment]?["g_Speed"])
        }
        XCTAssertEqual(try speed(["speed": .number(5)]), [5])
        XCTAssertEqual(try speed([:]), [1])
    }

    func testMaterialFileConstantsTakeTheUserPropertyValue() throws {
        func brightness(_ userValues: [String: WallpaperEngineProjectPropertyValue]) throws -> [Float]? {
            let binding = try Self.probeBinding(vertex: "", fragment: """
                                                uniform float g_EmissiveBrightness; // {"material":"emissivebrightness","default":1.0}
                                                """,
                                                material: ["emissivebrightness": ["user": "constellations", "value": 2.3]],
                                                instance: [:], userValues: userValues)
            return Self.floats(binding.constants[.fragment]?["g_EmissiveBrightness"])
        }
        XCTAssertEqual(try brightness(["constellations": .number(1)]), [1])
        XCTAssertEqual(try brightness([:]), [2.3])
    }

    func testMaterialFileColourConstantsTakeTheUserColourProperty() throws {
        let binding = try Self.probeBinding(vertex: "", fragment: """
                                            uniform vec3 g_TintColor; // {"material":"color","default":"1 1 1"}
                                            """,
                                            material: ["color": ["user": "datacolor", "value": "0.85490 0 0"]],
                                            instance: [:],
                                            userValues: ["datacolor": .string("0.592157 0.764706 1")])
        XCTAssertEqual(Self.floats(binding.constants[.fragment]?["g_TintColor"]), [0.592157, 0.764706, 1])
    }

    /// The original ordinal, ordinary declarations and aspect flag survive the actual material→draw binding path.
    func testUserTextureDeclarationsKeepSlotsTypesAspectAndAuthoredFallback() throws {
        let declarations: [Any] = [NSNull(), "ordinary",
                                   ["name": "$mediaThumbnail", "type": "system", "keepaspect": true],
                                   ["name": "$mediaPreviousThumbnail", "type": "system"]]
        for locus in ["material", "pass", "instance"] {
            var pass: [String: Any] = ["shader": "probe", "textures": ["util/base", "util/ordinary", "util/current", "previous"],
                                       "usertexturereference": ["width": 6, "height": 2]]
            var material: [String: Any] = [:]
            var instance: [String: Any] = [:]
            switch locus {
            case "material": material["usertextures"] = declarations
            case "pass": pass["usertextures"] = declarations
            default: instance["usertextures"] = declarations
            }
            material["passes"] = [pass]
            let binding = try Self.userTextureBinding(material: material, instance: instance)
            let typed = locus == "material" ? binding.userTextures.bindings.material
                : locus == "pass" ? binding.userTextures.bindings.pass : binding.userTextures.bindings.override
            XCTAssertEqual(typed, [.init(name: "ordinary", slot: 1),
                                   .init(name: "$mediaThumbnail", type: "system", slot: 2),
                                   .init(name: "$mediaPreviousThumbnail", type: "system", slot: 3)], locus)
            XCTAssertEqual(binding.userTextures.keepAspectSlots, [2], locus)
            XCTAssertEqual(binding.userTextures.diagnostics.filter { $0.contains("keepaspect") }, [], locus)
            XCTAssertEqual(binding.userTextures.reference, SIMD2(6, 2), locus)
            XCTAssertEqual(binding.userTextureSlots.keys.sorted(), [1, 2], "previous is producer-owned: \(locus)")
            XCTAssertEqual(binding.userTextureSlots[1]?.name, "ordinary", "ordinary must not be removed: \(locus)")
            XCTAssertEqual(binding.textures[1], .asset("util/ordinary"), locus)
            XCTAssertEqual(binding.textures[2], .asset("util/current"), locus)
            if case .resource? = binding.textures[3] {
                // The graph supplies the source; a global media name cannot replace it.
            } else {
                XCTFail("previous lost its graph identity: \(locus)")
            }
            if case let .imported(_, asset)? = binding.textures[0] {
                XCTAssertEqual(asset, "util/base", locus)
            } else {
                XCTFail("albedo fallback changed: \(locus)")
            }
        }
    }

    func testSelectedPassAndInstanceRecursivelyMergeUserTexturesWithoutLosingSlotsOrMetadata() throws {
        let base: [Any] = [["name": "$mediaThumbnail", "type": "system", "keepaspect": false],
                           "ordinary", "tail"]
        let overrides: [Any] = [["name": "$mediaPreviousThumbnail", "type": NSNull()], NSNull()]
        let binding = try Self.userTextureBinding(material: ["passes": [[
            "shader": "probe", "textures": ["util/base", "util/ordinary", "util/tail"], "usertextures": base,
        ]]], instance: ["usertextures": overrides])
        XCTAssertEqual(binding.userTextures.pass, WPESceneJSONValue(jsonValue: base))
        XCTAssertEqual(binding.userTextures.bindings.override, [.init(name: "$mediaPreviousThumbnail", slot: 0)])
        XCTAssertEqual(binding.userTextureSlots, [
            0: .init(name: "$mediaPreviousThumbnail", type: "system", slot: 0),
            1: .init(name: "ordinary", slot: 1), 2: .init(name: "tail", slot: 2),
        ])
        XCTAssertTrue(binding.userTextures.diagnostics.isEmpty)
        XCTAssertEqual(binding.textures[1], .asset("util/ordinary"))
        XCTAssertEqual(binding.textures[2], .asset("util/tail"))

        let nullOverride = try Self.userTextureBinding(material: ["passes": [[
            "shader": "probe", "textures": ["util/base"], "usertextures": [base[0]],
        ]]], instance: ["usertextures": NSNull()])
        XCTAssertEqual(nullOverride.userTextureSlots[0]?.name, "$mediaThumbnail")
        XCTAssertTrue(nullOverride.userTextures.diagnostics.isEmpty)

        let grown = try Self.userTextureBinding(material: ["passes": [[
            "shader": "probe", "textures": ["util/base", "util/ordinary"], "usertextures": [base[0]],
        ]]], instance: ["usertextures": [NSNull(), "ordinary", NSNull(), NSNull()]])
        XCTAssertEqual(grown.userTextureSlots, [
            0: .init(name: "$mediaThumbnail", type: "system", slot: 0), 1: .init(name: "ordinary", slot: 1),
        ])
        XCTAssertTrue(grown.userTextures.diagnostics.isEmpty)

        let holes = try Self.userTextureBinding(material: ["passes": [[
            "shader": "probe", "textures": ["util/base", "util/ordinary"], "usertextures": [],
        ]]], instance: ["usertextures": [NSNull(), "ordinary", NSNull()]])
        XCTAssertEqual(holes.userTextureSlots, [1: .init(name: "ordinary", slot: 1)])
        XCTAssertTrue(holes.userTextures.diagnostics.isEmpty)

        let changedType = try Self.userTextureBinding(material: ["passes": [[
            "shader": "probe", "textures": ["util/base", "util/ordinary"], "usertextures": "old-invalid-type",
        ]]], instance: ["usertextures": [NSNull(), "ordinary", NSNull()]])
        XCTAssertEqual(changedType.userTextureSlots, [1: .init(name: "ordinary", slot: 1)])
        XCTAssertTrue(changedType.userTextures.diagnostics.isEmpty, "The instance replaces the invalid base type before use")
    }

    /// This guard protects explicit unsupported merge behavior, not a claim about native conflict precedence.
    func testUserTextureMergeUnknownRetainsAllLociAndFallback() throws {
        let media: [Any] = [NSNull(), ["name": "$mediaThumbnail", "type": "system"]]
        let cases: [(pass: Any, accepted: Bool)] = [
            (media, true), ([NSNull(), "ordinary"], false), (NSNull(), false), ([Any](), false),
        ]
        for input in cases {
            let material: [String: Any] = ["usertextures": media, "passes": [[
                "shader": "probe", "textures": ["util/base", "util/fallback"], "usertextures": input.pass,
            ]]]
            let binding = try Self.userTextureBinding(material: material)
            XCTAssertEqual(binding.userTextures.material, WPESceneJSONValue(jsonValue: media))
            XCTAssertEqual(binding.userTextures.pass, WPESceneJSONValue(jsonValue: input.pass))
            XCTAssertEqual(binding.userTextures.bindings.override, [])
            XCTAssertEqual(binding.userTextures.bindings.material, [.init(name: "$mediaThumbnail", type: "system", slot: 1)])
            XCTAssertEqual(binding.textures[1], .asset("util/fallback"))
            if input.accepted {
                XCTAssertEqual(binding.userTextureSlots[1]?.name, "$mediaThumbnail")
                XCTAssertTrue(binding.userTextures.diagnostics.isEmpty)
            } else {
                XCTAssertTrue(binding.userTextureSlots.isEmpty)
                XCTAssertTrue(binding.userTextures.diagnostics.contains { $0.contains("array merge") })
            }
        }
    }

    private static func userTextureBinding(material: [String: Any], instance: [String: Any] = [:]) throws
        -> WPEParityProgramBinding {
        let resources: [String: Any] = [
            "models/probe.json": ["material": "materials/probe.json"],
            "materials/probe.json": material,
        ]
        var bytes = try resources.mapValues { try JSONSerialization.data(withJSONObject: $0) }
        bytes["shaders/probe.vert"] = Data("void main() {}".utf8)
        bytes["shaders/probe.frag"] = Data("void main() {}".utf8)
        let files = bytes
        let assets = WPEParityProgramAssets(sources: [.lookup(FileManager.default.temporaryDirectory) { files[$0] }])
        let json: [String: Any] = [
            "camera": ["center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": 200, "height": 100]],
            "objects": [["id": 7, "image": "models/probe.json", "size": "200 100", "instance": instance]],
        ]
        let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: json),
                                                        userValues: [:], makeTransformScriptResolver: { _, _ in NoScripts() })
        let scene = WPEParityProgramScene(document: document, assets: assets, settings: .init())
        let frame = try WPEParityFrameComposer.compose(scene: scene.scene, post: scene.postProcess)
        return try XCTUnwrap(WPEParityProgramBuilder.bindings(frame: frame, scene: scene).values.first {
            $0.materialPass == .init(objectID: "7", effectID: nil, pass: 0)
        })
    }

    /// 140181f30 binds the LUT in slot 1 independently of COL. A material/default texture is not a graph read.
    func testPostColorCorrectionBindsItsLUTAndPreservesFreeAnnotationAssets() throws {
        let (scene, frame) = try Self.postFixture(
            bloom: false, correction: .init(wccV: "warm", wccAmt: 50),
            correctionTextures: ["util/material-slot-zero", "lut/material-default"]
        )
        let operation = try XCTUnwrap(frame.draws.first { _, draw in
            if case let .post(post) = draw {
                post.shader == "ccsimple"
            } else {
                false
            }
        }?.key)
        let binding = try XCTUnwrap(WPEParityProgramBuilder.bindings(frame: frame, scene: scene)[operation])
        XCTAssertEqual(binding.textures, [0: .resource("_rt_FullFrameBuffer"),
                                          1: .asset("lut/warm"), 2: .asset("util/annotation")])
        XCTAssertEqual(Self.floats(binding.constants[.fragment]?["g_LutParams"]), [0.5])
        XCTAssertFalse(binding.depthTest)
        XCTAssertFalse(binding.depthWrite)
    }

    /// The post graph owns FFB/bloom slots; an RT name no frame resource declares binds as a texture asset.
    func testPostGraphReadsOverrideMaterialAssetsAndRetainResourceIdentity() throws {
        let (scene, frame) = try Self.postFixture(
            bloom: true, combineTextures: ["util/stale-scene", "lut/stale-bloom", "_rt_NotDeclared",
                                           "backbuffer", "previous", "util/free"]
        )
        let operation = try XCTUnwrap(frame.draws.first { _, draw in
            if case let .post(post) = draw {
                post.shader == "combine"
            } else {
                false
            }
        }?.key)
        let binding = try XCTUnwrap(WPEParityProgramBuilder.bindings(frame: frame, scene: scene)[operation])
        XCTAssertEqual(binding.textures, [0: .resource("_rt_FullFrameBuffer"), 1: .resource("_rt_Bloom"),
                                          2: .asset("_rt_NotDeclared"), 3: .resource("backbuffer"),
                                          4: .resource("_rt_FullFrameBuffer"), 5: .asset("util/free")])
        guard case let .draw(draw) = frame.operations[operation].kind else { return XCTFail("missing combine draw") }
        XCTAssertEqual(draw.reads.map(\.resource), ["_rt_FullFrameBuffer", "_rt_Bloom"])
        XCTAssertFalse(frame.resources.contains { $0.id == "_rt_NotDeclared" })
    }

    /// 1400ec220.c:223-234: a name the render-target cache misses loads as a texture file, so a missing one samples
    /// the checker; only a name the frame declares stays a resource.
    func testRenderTargetNameWithoutAFrameResourceBindsAsATextureAsset() throws {
        let missing = "_rt_NotARenderTarget"
        let declared: WPEResourceID = "_rt_FullFrameBuffer"
        let (postScene, postFrame) = try Self.postFixture(bloom: true, combineTextures: ["", "", missing, "_rt_FullFrameBuffer"])
        let combine = try XCTUnwrap(postFrame.draws.first { _, draw in
            if case let .post(post) = draw {
                post.shader == "combine"
            } else {
                false
            }
        }?.key)
        let post = try XCTUnwrap(WPEParityProgramBuilder.bindings(frame: postFrame, scene: postScene)[combine])
        XCTAssertEqual(post.textures[2], .asset(missing))
        XCTAssertEqual(post.textures[3], .resource(declared))

        let layer = ParitySceneDocuments.layer(effects: [
            ParitySceneDocuments.effect(passes: [ParitySceneDocuments.pass("fx")]),
        ])
        let scene = try ParitySceneDocuments.programScene([layer], files: [
            "materials/fx.json": #"""
            {"passes":[{"shader":"fx","blending":"translucent","textures":[null,"\#(missing)","_rt_FullFrameBuffer"]}]}
            """#,
        ])
        let frame = try WPEParityFrameComposer.compose(scene: scene.scene, post: scene.postProcess)
        XCTAssertTrue(frame.resources.contains { $0.id == declared })
        XCTAssertFalse(frame.resources.contains { $0.id == WPEResourceID(missing) })
        let effect = try XCTUnwrap(frame.draws.first { _, draw in
            guard case let .scene(draw) = draw else { return false }
            return draw.objectID == "7" && draw.effectID != nil
        }?.key)
        let binding = try XCTUnwrap(WPEParityProgramBuilder.bindings(frame: frame, scene: scene)[effect])
        XCTAssertEqual(binding.textures[1], .asset(missing))
        XCTAssertEqual(binding.textures[2], .resource(declared))
    }

    private static func postFixture(bloom: Bool, correction: WPEParityColorCorrection = .init(),
                                    correctionTextures: [String] = [], combineTextures: [String] = []) throws
        -> (WPEParityProgramScene, WPEParityFrame) {
        let materials: [String: Any] = [
            "materials/util/ccsimple.json": ["passes": [["shader": "ccsimple", "textures": correctionTextures]]],
            "materials/util/combine_ldr.json": ["passes": [["shader": "combine", "textures": combineTextures]]],
        ]
        var bytes = try materials.mapValues { try JSONSerialization.data(withJSONObject: $0) }
        bytes["shaders/ccsimple.vert"] = Data("void main() {}".utf8)
        bytes["shaders/ccsimple.frag"] = Data("""
        uniform sampler2D g_Texture0;
        uniform sampler3D g_Texture1;
        uniform sampler2D g_Texture2; // {"default":"util/annotation"}
        uniform float g_LutParams; // {"material":"lutparams","default":1}
        void main() {}
        """.utf8)
        bytes["shaders/combine.vert"] = Data("void main() {}".utf8)
        bytes["shaders/combine.frag"] = Data("void main() {}".utf8)
        let files = bytes
        let assets = WPEParityProgramAssets(sources: [.lookup(FileManager.default.temporaryDirectory) { files[$0] }])
        let json: [String: Any] = [
            "camera": ["center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": 32, "height": 16], "bloom": bloom],
            "objects": [["id": 1, "name": "layer"]],
        ]
        let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: json),
                                                        userValues: [:], makeTransformScriptResolver: { _, _ in NoScripts() })
        let scene = WPEParityProgramScene(document: document, assets: assets,
                                          settings: .init(colorCorrection: correction))
        return try (scene, WPEParityFrameComposer.compose(scene: scene.scene, post: scene.postProcess))
    }

    /// One image layer `7` whose material runs `shaders/probe.{vert,frag}`; returns its albedo draw's binding.
    private static func probeBinding(vertex: String, fragment: String, material: [String: Any],
                                     instance: [String: Any],
                                     userValues: [String: WallpaperEngineProjectPropertyValue] = [:]) throws
        -> WPEParityProgramBinding {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("parity-binding-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let object: [String: Any] = ["id": 7, "name": "7", "image": "models/7.json", "size": "400 200",
                                     "instance": ["constantshadervalues": instance]]
        let files: [String: Any] = [
            "shaders/probe.vert": vertex + "\nvoid main() {}\n",
            "shaders/probe.frag": fragment + "\nvoid main() {}\n",
            "models/7.json": ["material": "materials/probe.json"],
            "materials/probe.json": ["passes": [["shader": "probe", "blending": "translucent",
                                                 "constantshadervalues": material]]],
            "scene.json": ["camera": ["center": "0 0 0"],
                           "general": ["orthogonalprojection": ["width": 1920, "height": 1080]],
                           "objects": [object]],
        ]
        for (path, content) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try (content as? String).map { Data($0.utf8) } ?? JSONSerialization.data(withJSONObject: content)
            try data.write(to: url)
        }
        let document = try WPESceneDocumentParser.parse(data: Data(contentsOf: root.appendingPathComponent("scene.json")),
                                                        userValues: userValues,
                                                        makeTransformScriptResolver: { _, _ in NoScripts() })
        var assets = WPEParityProgramAssets(sceneDirectory: root, assetRoots: [])
        assets.userValues = userValues
        let scene = WPEParityProgramScene(document: document, assets: assets, settings: WPEParityProgramSettings())
        let frame = try WPEParityFrameComposer.compose(scene: scene.scene, post: scene.postProcess)
        let bindings = WPEParityProgramBuilder.bindings(frame: frame, scene: scene)
        let index = try XCTUnwrap(frame.draws.first { _, draw in
            guard case let .scene(draw) = draw else { return false }
            return draw.objectID == "7" && draw.effectID == nil && draw.source != nil
        }?.key)
        return try XCTUnwrap(bindings[index])
    }

    func testConstantShapesReadAsComponents() {
        XCTAssertEqual(WPEParityProgramConstants.components(WPESceneJSONValue.string("0.05, 0.00")), [0.05, 0])
        XCTAssertEqual(WPEParityProgramConstants.components(WPESceneJSONValue.array([.number(1), .number(2)])), [1, 2])
        XCTAssertEqual(WPEParityProgramConstants.components(WPESceneJSONValue.object(["value": .number(3)])), [3])
        XCTAssertEqual(WPEParityProgramConstants.components(WPESceneJSONValue.bool(true)), [1])
        XCTAssertEqual(WPEParityProgramConstants.components(WPESceneShaderConstantValue.string("1 1 1")), [1, 1, 1])
        XCTAssertEqual(WPEParityProgramConstants.components(WPESceneShaderConstantValue.vector([0, 0.58])), [0, 0.58])
        XCTAssertNil(WPEParityProgramConstants.components(WPESceneShaderConstantValue.string("util/noise")))
    }

    /// 1401ee1a0 counts accepted 0x30-byte records, including commands and a failed material. 1401e7170 uses the
    /// original resource index for overrides even after a copy command and a rejected conditional pass.
    func testEffectRecordsPreserveNativeCountAndRawOverrideIndices() throws {
        let resources: [String: Any] = [
            "models/probe.json": ["material": "materials/base.json"],
            "materials/base.json": ["passes": [["shader": "probe"]]],
            "materials/empty.json": ["passes": [["shader": "empty"]]],
            "materials/later.json": ["passes": [["shader": "probe", "constantshadervalues": ["value": 1],
                                                 "textures": ["previous", "util/authored-fallback"]]]],
            "effects/records.json": ["passes": [
                ["material": "materials/empty.json"], ["command": "copy"],
                ["material": "materials/skipped.json", "conditions": [["ON": 1]]],
                ["material": "materials/later.json"], ["command": "swap"],
                ["material": "materials/missing.json"], [:],
                ["command": "copy", "material": "materials/later.json"],
            ]],
            "effects/empty.json": ["passes": []],
        ]
        var bytes = try resources.mapValues { try JSONSerialization.data(withJSONObject: $0) }
        bytes["shaders/probe.vert"] = Data("void main() {}".utf8)
        bytes["shaders/probe.frag"] = Data("""
        uniform float g_Value; // {"material":"value","default":1}
        void main() {}
        """.utf8)
        bytes["shaders/empty.vert"] = Data("void main() {}".utf8)
        bytes["shaders/empty.frag"] = Data("void main() {}".utf8)
        let files = bytes
        let assets = WPEParityProgramAssets(sources: [.lookup(FileManager.default.temporaryDirectory) { files[$0] }])
        let json: [String: Any] = [
            "camera": ["center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": 200, "height": 100]],
            "objects": [["id": 7, "image": "models/probe.json", "size": "200 100", "effects": [
                ["id": 9, "file": "effects/records.json", "visible": false,
                 "passes": [[:], NSNull(), ["constantshadervalues": ["value": 22]],
                            ["constantshadervalues": ["value": 33], "usertextures": [
                                ["name": "$mediaThumbnail", "type": "system"],
                                ["name": "$mediaPreviousThumbnail", "type": "system"],
                            ]], [:], [:],
                            ["constantshadervalues": ["phantom": 99]]]],
                ["id": 10, "file": "effects/absent.json"],
                ["id": 11, "file": "effects/empty.json"],
            ]]],
        ]
        let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: json),
                                                        userValues: [:], makeTransformScriptResolver: { _, _ in NoScripts() })
        let scene = WPEParityProgramScene(document: document, assets: assets, settings: .init())
        let later = WPEParityMaterialPassKey(objectID: "7", effectID: "9", pass: 3)
        let records = try XCTUnwrap(scene.resolvedEffectRecords[.init(objectID: "7", effectID: "9")])
        XCTAssertEqual(records.map(\.filePassIndex), [0, 1, 3, 4, 5, 6, 7])
        XCTAssertEqual(records.map(\.materialPass), [.init(objectID: "7", effectID: "9", pass: 0), nil, later, nil, nil, nil, nil])
        XCTAssertEqual(records.map(\.materialPath), ["materials/empty.json", nil, "materials/later.json", nil,
                                                     "materials/missing.json", nil, "materials/later.json"])
        XCTAssertNil(scene.resolvedEffectRecords[.init(objectID: "7", effectID: "10")], "failed effect load is not known zero")
        XCTAssertEqual(scene.resolvedEffectRecords[.init(objectID: "7", effectID: "11")], [], "empty resource is known zero")
        let state = WPEParitySceneState(scene: scene, document: document)
        XCTAssertNotNil(state.passIndex(of: .init(objectID: "7", effectID: "9", pass: 0)), "empty material keeps its identity")
        XCTAssertEqual(state.constant("value", of: later)?.value.x, 33)
        XCTAssertNil(state.passIndex(of: .init(objectID: "7", effectID: "9", pass: 1)))
        XCTAssertNil(state.passIndex(of: .init(objectID: "7", effectID: "9", pass: 6)))
        XCTAssertNil(state.passIndex(of: .init(objectID: "7", effectID: "9", pass: 7)),
                     "a material-bearing command keeps its declared path without inventing a draw consumer")
        let frame = try WPEParityFrameComposer.compose(scene: scene.scene(effectVisible: { _, _ in true }),
                                                       post: scene.postProcess)
        let binding = try XCTUnwrap(WPEParityProgramBuilder.bindings(frame: frame, scene: scene).values.first {
            $0.materialPass == later
        })
        XCTAssertEqual(Self.floats(binding.constants[.fragment]?["g_Value"]), [33])
        XCTAssertEqual(binding.userTextures.bindings.override, [
            .init(name: "$mediaThumbnail", type: "system", slot: 0),
            .init(name: "$mediaPreviousThumbnail", type: "system", slot: 1),
        ], "usertextures use the original override index after commands and rejected conditions")
        XCTAssertEqual(binding.userTextureSlots, [1: .init(name: "$mediaPreviousThumbnail", type: "system", slot: 1)],
                       "effect previous is producer-owned even when a usertexture declares its slot")
        XCTAssertEqual(binding.textures[1], .asset("util/authored-fallback"))
        XCTAssertEqual(scene.resolvedEffectRecords[.init(objectID: "7", effectID: "9")]?.count, 7,
                       "disabled effects retain native records; enabling draws must not redefine the count")
    }

    /// constantshadervalues keys are byte-exact UTF-8 (140154480.c:555-563).
    func testNonASCIIMaterialKeysReachEffectPassConstants() throws {
        let resources: [String: Any] = [
            "models/probe.json": ["material": "materials/base.json"],
            "materials/base.json": ["passes": [["shader": "probe"]]],
            "materials/line.json": ["passes": [["shader": "line"]]],
            "effects/line.json": ["passes": [["material": "materials/line.json"]]],
        ]
        var bytes = try resources.mapValues { try JSONSerialization.data(withJSONObject: $0) }
        bytes["shaders/probe.vert"] = Data("void main() {}".utf8)
        bytes["shaders/probe.frag"] = Data("void main() {}".utf8)
        bytes["shaders/line.vert"] = Data("void main() {}".utf8)
        bytes["shaders/line.frag"] = Data("""
        uniform vec3 u_curveColor; // {"default":"1.0 1.0 1.0","material":"曲线颜色","type":"color"}
        uniform float u_amplitude; // {"material":"整体振幅","default":0.4}
        uniform float u_curveOpacity; // {"material":"曲线透明度","default":1.0}
        uniform float u_curveThickness; // {"material":"曲线粗细","default":0.003}
        // [COMBO] {"material":"包络","combo":"TRANSPARENCY","type":"options","default":1}
        void main() {}
        """.utf8)
        let files = bytes
        let assets = WPEParityProgramAssets(sources: [.lookup(FileManager.default.temporaryDirectory) { files[$0] }])
        let json: [String: Any] = [
            "camera": ["center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": 200, "height": 100]],
            "objects": [["id": 7, "image": "models/probe.json", "size": "200 100", "effects": [
                ["id": 9, "file": "effects/line.json", "passes": [["constantshadervalues": [
                    "曲线颜色": ["user": "newproperty", "value": "0.12941 0.89412 0.12941"],
                    "曲线透明度": 0.85, "曲线粗细": 0.001, "整体振幅": 0.1,
                ]]]],
            ]]],
        ]
        func fragment(_ userValues: [String: WallpaperEngineProjectPropertyValue]) throws
            -> (constants: [String: WPECBufferValue]?, materials: Set<String>) {
            let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: json),
                                                            userValues: userValues,
                                                            makeTransformScriptResolver: { _, _ in NoScripts() })
            let scene = WPEParityProgramScene(document: document, assets: assets, settings: .init())
            let frame = try WPEParityFrameComposer.compose(scene: scene.scene, post: scene.postProcess)
            let pass = WPEParityMaterialPassKey(objectID: "7", effectID: "9", pass: 0)
            let binding = try XCTUnwrap(WPEParityProgramBuilder.bindings(frame: frame, scene: scene).values.first {
                $0.materialPass == pass
            })
            return (binding.constants[.fragment], Set(binding.materialConstants[.fragment]?.map(\.material) ?? []))
        }
        let authored = try fragment([:])
        XCTAssertEqual(Self.floats(authored.constants?["u_curveColor"]), [0.12941, 0.89412, 0.12941])
        XCTAssertEqual(Self.floats(authored.constants?["u_curveOpacity"]), [0.85])
        XCTAssertEqual(Self.floats(authored.constants?["u_curveThickness"]), [0.001])
        XCTAssertEqual(Self.floats(authored.constants?["u_amplitude"]), [0.1])
        XCTAssertTrue(authored.materials.isSuperset(of: ["曲线颜色", "整体振幅"]))
        let user = try fragment(["newproperty": .string("1 0 0")])
        XCTAssertEqual(Self.floats(user.constants?["u_curveColor"]), [1, 0, 0])
    }

    func testEffectWithoutIDKeepsItsAuthoredCombos() throws {
        let resources: [String: Any] = [
            "models/probe.json": ["material": "materials/base.json"],
            "materials/base.json": ["passes": [["shader": "probe"]]],
            "effects/gated.json": ["passes": [["material": "materials/base.json", "conditions": [["ON": 1]]]]],
        ]
        var bytes = try resources.mapValues { try JSONSerialization.data(withJSONObject: $0) }
        bytes["shaders/probe.vert"] = Data("void main() {}".utf8)
        bytes["shaders/probe.frag"] = Data("void main() {}".utf8)
        let files = bytes
        let assets = WPEParityProgramAssets(sources: [.lookup(FileManager.default.temporaryDirectory) { files[$0] }])
        let json: [String: Any] = [
            "camera": ["center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": 200, "height": 100]],
            "objects": [["id": 7, "image": "models/probe.json", "size": "200 100", "effects": [
                ["file": "effects/gated.json", "combos": ["ON": 1]],
            ]]],
        ]
        let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: json),
                                                        userValues: [:], makeTransformScriptResolver: { _, _ in NoScripts() })
        let scene = WPEParityProgramScene(document: document, assets: assets, settings: .init())
        XCTAssertEqual(scene.resolvedEffectRecords[.init(objectID: "7", effectID: "0")]?.map(\.filePassIndex), [0])
    }

    /// Scene 3815666789's foliagesway pass: every material uniform gets the scene value or its default.
    func testRealSceneEffectPassBindsSceneConstantsAndTextures() throws {
        guard let directory = ProcessInfo.processInfo.environment["WPE_HLSL_CAPTURE_DIR"], !directory.isEmpty else {
            throw XCTSkip("Set WPE_HLSL_CAPTURE_DIR to the capture directory containing scene-sources/")
        }
        let install = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Steam/steamapps/common/wallpaper_engine/assets")
        let wpeAssets = ProcessInfo.processInfo.environment["WPE_ASSETS_DIR"].map { URL(fileURLWithPath: $0) } ?? install
        guard FileManager.default.fileExists(atPath: wpeAssets.appendingPathComponent("materials/util").path) else {
            throw XCTSkip("Set WPE_ASSETS_DIR to a WPE 2.8.42 assets directory (materials/util)")
        }
        let fixture = try ParityProgramCaptureFixture(root: URL(fileURLWithPath: directory), wpeAssets: wpeAssets)
        let assets = WPEParityProgramAssets(
            sceneDirectory: fixture.root.appendingPathComponent("scene-sources/3815666789"),
            assetRoots: fixture.assetRoots
        )
        let scene = try WPEParityProgramScene(document: fixture.document("3815666789"), assets: assets,
                                              settings: ParityProgramCaptureFixture.captureSettings)
        let frame = try WPEParityFrameComposer.compose(scene: scene.scene, post: scene.postProcess)
        let bindings = WPEParityProgramBuilder.bindings(frame: frame, scene: scene)
        func sceneDraw(_ shader: String) throws -> (WPEParitySceneDraw, WPEParityProgramBinding) {
            let draws = frame.draws.compactMap { index, draw -> (Int, WPEParitySceneDraw)? in
                guard case let .scene(draw) = draw, draw.shader == shader else { return nil }
                return (index, draw)
            }
            let (index, draw) = try XCTUnwrap(draws.first, shader)
            return try (draw, XCTUnwrap(bindings[index]))
        }

        let (foliage, binding) = try sceneDraw("effects/foliagesway")
        let expected: [String: [Float]] = [
            "g_Strength": [0.4], "g_Phase": [0.5], "g_Power": [1], "g_DirectionWeights": [1, 0.2],
            "g_CornerWeights": [1, 1, 0, 0], "g_Bounds": [0, 1], "g_NoiseScale": [0.05], "g_Ratio": [0.3],
            "g_Direction": [0], "g_Color4": [1, 1, 1, 1], "g_Alpha": [1],
        ]
        let vertex = binding.constants[.vertex] ?? [:], fragment = binding.constants[.fragment] ?? [:]
        for (name, value) in expected {
            XCTAssertEqual(Self.floats(fragment[name] ?? vertex[name]), value, name)
        }
        // The vertex stage reads `speed` (default 1), the fragment stage `speeduv` (scene 5).
        XCTAssertEqual(Self.floats(vertex["g_Speed"]), [1])
        XCTAssertEqual(Self.floats(fragment["g_Speed"]), [5])
        XCTAssertEqual(binding.textures, [0: .resource(foliage.reads[0]),
                                          1: .asset("masks/foliagesway_mask_74f285a7"), 2: .asset("util/noise")])
        XCTAssertFalse(binding.cullsBackFaces)

        let (ripple, rippleBinding) = try sceneDraw("effects/waterripple")
        XCTAssertEqual(rippleBinding.textures, [0: .resource(ripple.reads[0]),
                                                1: .asset("masks/waterripple_mask_886131ae"),
                                                2: .asset("effects/waterripplenormal")])
        XCTAssertEqual(Self.floats(rippleBinding.constants[.vertex]?["g_AnimationSpeed"]), [0.11])
        XCTAssertEqual(Self.floats(rippleBinding.constants[.fragment]?["g_SpecularColor"]), [1, 1, 1])

        let (albedo, albedoBinding) = try sceneDraw("genericimage4")
        XCTAssertEqual(albedoBinding.textures[0],
                       .imported(albedo.reads[0], asset: "AF3DD4AEF955193C9E71595ACC80BF57"))
    }
}

private struct NoScripts: WPESceneTransformScriptResolving {
    func resolveVec3(script _: String, properties _: [String: WPESceneScriptPropertyValue],
                     seed _: SIMD3<Double>) -> SIMD3<Double>? {
        nil
    }
}
