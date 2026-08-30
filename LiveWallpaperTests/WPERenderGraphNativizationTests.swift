import CoreGraphics
import Foundation
import LiveWallpaperProWPE
import Testing
@testable import LiveWallpaper

/// Load-time `nativized()` must localize hot strings without changing values.
@Suite("WPE render graph string nativization")
struct WPERenderGraphNativizationTests {
    /// Same JSONSerialization path the scene parser uses.
    private func parsedString(_ jsonScalar: String) throws -> String {
        let data = try #require("{\"value\": \"\(jsonScalar)\"}".data(using: .utf8))
        let object = try JSONSerialization.jsonObject(with: data)
        let dictionary = try #require(object as? [String: Any])
        return try #require(dictionary["value"] as? String)
    }

    @Test("Control: escaped/non-ASCII JSONSerialization scalars bridge as non-contiguous strings")
    func jsonScalarsBridgeAsForeignStrings() throws {
        // If this fails, Foundation now bridges natively and nativization is a no-op.
        let escaped = try parsedString(#"models\/util\/composelayer_long_enough.json"#)
        #expect(!escaped.isContiguousUTF8)
        let nonASCII = try parsedString("materials/背景图层_很长的非ASCII路径名.tex")
        #expect(!nonASCII.isContiguousUTF8)
    }

    @Test("nativized() localizes every hot string field and changes no values")
    func nativizedLocalizesAllFieldsAndPreservesEquality() throws {
        // `\uXXXX` forces JSONSerialization's escape path (foreign NSString), value unchanged.
        func foreign(_ plain: String) throws -> String {
            let first = try #require(plain.unicodeScalars.first)
            let scalar: String
            if first.isASCII {
                scalar = String(format: "\\u%04X", first.value) + String(plain.unicodeScalars.dropFirst())
            } else {
                scalar = plain
            }
            let value = try parsedString(scalar)
            #expect(value == plain)
            #expect(!value.isContiguousUTF8, "fixture string must start foreign for the guard to have teeth")
            return value
        }

        let geometry = WPERenderLayerGeometry(
            origin: SIMD3(1, 2, 3),
            scale: SIMD3(2, 2, 1),
            angles: SIMD3(0, 0, 0.5),
            alignment: .topLeft,
            size: CGSize(width: 640, height: 480),
            puppetMeshCenter: SIMD2(3, 4),
            alpha: 0.75,
            color: SIMD3(0.5, 0.25, 1),
            brightness: 1.5,
            shapePoints: [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)]
        )
        let pass = WPERenderPass(
            id: try foreign("object/7/pass/0_long_enough_id"),
            phase: .effect(file: "effects/custom/effect.json"),
            shader: try foreign("effects/custom_shader_long_enough"),
            source: .image(try foreign("materials/source_image_long_enough.tex")),
            target: .fbo(name: try foreign("_rt_CustomBuffer_long_enough_name")),
            textures: [1: .asset(try foreign("materials/mask_texture_long_enough.tex"))],
            binds: [2: .fbo(try foreign("_rt_BoundBuffer_long_enough_name"))],
            constants: [try foreign("g_CustomStrengthUniform_long_enough"): .number(0.5)],
            combos: [try foreign("CUSTOM_COMBO_NAME_LONG_ENOUGH"): 2],
            userTextureBindings: WPERenderUserTextureBindings(
                material: [WPESceneUserTextureBinding(name: "$materialSource", type: "system")]
            ),
            authoredJSON: WPERenderPassAuthoredJSON(
                materialDocument: .object([
                    "passes": .array([.object(["future": .bool(true)])]),
                    "nullable": .null
                ]),
                materialPass: .object(["future": .number(2.5)]),
                effectDocument: .object(["future": .string("effect-root")]),
                effectPass: .object(["future": .array([.number(1), .null])]),
                effectIdentity: WPERenderEffectPassIdentity(
                    objectID: "object/7",
                    authoredEffectID: "effect-3",
                    authoredEffectPath: "effects/custom/effect.json",
                    effectPassIndex: 2,
                    authoredOverrideID: 17
                )
            ),
            blending: try foreign("translucent_blend_mode_long_enough"),
            cullMode: try foreign("nocull_mode_value_long_enough_here"),
            depthTest: try foreign("disabled_depth_test_long_enough"),
            depthWrite: try foreign("disabled_depth_write_long_enough"),
            constantScripts: [
                try foreign("g_ScriptedUniformName_long_enough"): WPESceneTransformScript(
                    script: "return value;",
                    seed: SIMD3(1, 2, 3)
                )
            ],
            visibilityGate: WPEPassVisibilityGate(
                script: WPESceneTransformScript(script: "return true;", seed: SIMD3(0, 0, 0)),
                initialVisible: false
            )
        )
        let layer = WPERenderLayer(
            objectID: try foreign("object_identifier_7_long_enough"),
            objectName: try foreign("图层名称_非ASCII_对象名_长长长"),
            visible: false,
            imagePath: try foreign("models/util/composelayer.json_x"),
            materialPath: try foreign("materials/layer_material_long.json"),
            puppetPath: try foreign("models/puppet_model_long_enough.mdl"),
            parentObjectID: try foreign("parent_object_identifier_long"),
            attachment: try foreign("anchor_attachment_name_long_x"),
            animationLayers: [WPESceneAnimationLayer(id: 1, rate: 2, visible: true, blend: 0.5, animation: 3)],
            authoredJSON: WPERenderLayerAuthoredJSON(
                sceneObjects: [
                    .object(["id": .string("parent"), "future": .bool(true)]),
                    .object(["id": .number(7), "ordered": .array([.number(2), .null, .bool(false)])])
                ],
                imageDescriptor: .object([
                    "material": .string("materials/layer.json"),
                    "future": .array([.bool(true), .number(4.5), .null])
                ])
            ),
            geometry: geometry,
            localGeometry: geometry,
            compositeA: try foreign("_rt_imageLayerComposite_7_a_long"),
            compositeB: try foreign("_rt_imageLayerComposite_7_b_long"),
            localFBOs: [
                WPERenderFBO(
                    name: try foreign("_rt_DeclaredBuffer_long_enough"),
                    scale: 2,
                    fit: 512,
                    format: try foreign("rgba8888_format_string_long_x"),
                    unique: true,
                    pixelSize: CGSize(width: 128, height: 64)
                )
            ],
            passes: [pass],
            groupRenderTarget: try foreign("_rt_GroupTarget_long_enough_x"),
            groupLocalGeometry: geometry,
            groupCompositeSource: try foreign("_rt_GroupComposite_long_enough"),
            parallaxDepth: SIMD2(0.3, 0.6),
            sortIndex: 42
        )
        let graph = WPERenderGraph(layers: [layer])

        let nativized = graph.nativized()

        // Equatable over the FULL memberwise field set: a hand-written copy
        // that drops any field to its default fails here.
        #expect(nativized == graph)

        let nativizedLayer = try #require(nativized.layers.first)
        #expect(nativizedLayer.authoredJSON == layer.authoredJSON)
        #expect(nativizedLayer.passes.first?.authoredJSON.effectIdentity
            == pass.authoredJSON.effectIdentity)
        assertAllStringsContiguous(in: nativizedLayer)
    }

    @Test("Graph builder output arrives fully contiguous end-to-end")
    func builderOutputIsContiguous() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPERenderGraphNativizationTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        try writeJSON(["material": "materials/layer.json"], to: root.appendingPathComponent("models/layer.json"))
        try writeJSON([
            "passes": [[
                "shader": "genericimage2",
                "blending": "translucent",
                "combos": ["VERSION": 2],
                "textures": ["materials/layer_albedo"]
            ]]
        ], to: root.appendingPathComponent("materials/layer.json"))

        let scenePayload: [String: Any] = [
            "camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 1920, "height": 1080, "auto": true]],
            "objects": [[
                "id": 7,
                "name": "Layer",
                "type": "image",
                "image": "models/layer.json"
            ]]
        ]
        // JSONSerialization.data escapes "/" as "\/", so the parsed document's
        // path strings start out foreign — same shape as real workshop scenes.
        let sceneData = try JSONSerialization.data(withJSONObject: scenePayload)
        let document = try WPESceneDocumentParser.parse(data: sceneData)

        let graph = try WPERenderGraphBuilder(cacheRootURL: root).build(document: document)

        let layer = try #require(graph.layers.first)
        #expect(layer.materialPath == "materials/layer.json")
        for graphLayer in graph.layers {
            assertAllStringsContiguous(in: graphLayer)
        }
    }

    /// Walks every string field `nativized()` covers; keep in sync with
    /// `WPERenderGraphNativization.swift`.
    private func assertAllStringsContiguous(
        in layer: WPERenderLayer,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        func check(_ value: String?, _ field: String) {
            guard let value else { return }
            #expect(
                value.isContiguousUTF8,
                "\(field) '\(value)' is not contiguous",
                sourceLocation: sourceLocation
            )
        }
        func check(_ reference: WPETextureReference?, _ field: String) {
            switch reference {
            case .image(let path), .asset(let path): check(path, field)
            case .fbo(let name): check(name, field)
            case .previous, nil: break
            }
        }

        check(layer.objectID, "objectID")
        check(layer.objectName, "objectName")
        check(layer.imagePath, "imagePath")
        check(layer.materialPath, "materialPath")
        check(layer.puppetPath, "puppetPath")
        check(layer.parentObjectID, "parentObjectID")
        check(layer.attachment, "attachment")
        check(layer.compositeA, "compositeA")
        check(layer.compositeB, "compositeB")
        check(layer.groupRenderTarget, "groupRenderTarget")
        check(layer.groupCompositeSource, "groupCompositeSource")
        for fbo in layer.localFBOs {
            check(fbo.name, "localFBO.name")
            check(fbo.format, "localFBO.format")
        }
        for pass in layer.passes {
            check(pass.id, "pass.id")
            check(pass.shader, "pass.shader")
            check(pass.source, "pass.source")
            if case .layerComposite(let name) = pass.target { check(name, "pass.target") }
            if case .fbo(let name) = pass.target { check(name, "pass.target") }
            for texture in pass.textures.values { check(texture, "pass.textures") }
            for bind in pass.binds.values { check(bind, "pass.binds") }
            for key in pass.constants.keys { check(key, "pass.constants key") }
            for key in pass.combos.keys { check(key, "pass.combos key") }
            for key in pass.constantScripts.keys { check(key, "pass.constantScripts key") }
            check(pass.blending, "pass.blending")
            check(pass.cullMode, "pass.cullMode")
            check(pass.depthTest, "pass.depthTest")
            check(pass.depthWrite, "pass.depthWrite")
        }
    }

    private func writeJSON(_ object: Any, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
        try data.write(to: url)
    }
}
