import CoreGraphics
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import simd
import Testing

@Suite("WPE scene-model submesh materials in the render graph")
struct WPESceneModelSubmeshMaterialGraphTests {
    @Test("Each MDLV submesh carries the textures its own material json names")
    func submeshesCarryTheirOwnMaterialTextures() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeMaterial("materials/mat0.json", texture: "red", root: root)
        try writeMaterial("materials/mat1.json", texture: "green", root: root)
        // mat2 authors mat0's texture; resolution must follow the json, not the material name.
        try writeMaterial("materials/mat2.json", texture: "red", root: root)
        try writeModel(materials: ["materials/mat0.json", "materials/mat1.json", "materials/mat2.json"], root: root)

        let layer = try buildLayer(root: root)

        #expect(layer.materialPath == "materials/mat0.json")
        #expect(layer.meshMaterialTextures == [1: [0: .asset("green")], 2: [0: .asset("red")]])
    }

    @Test("Submeshes sharing the layer material add no per-mesh textures")
    func sharedMaterialAddsNoPerMeshTextures() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeMaterial("materials/mat0.json", texture: "red", root: root)
        try writeModel(materials: Array(repeating: "materials/mat0.json", count: 3), root: root)

        let layer = try buildLayer(root: root)

        #expect(layer.meshMaterialTextures.isEmpty)
    }

    @Test("Each submesh carries its own authored blending, defaulting to normal")
    func submeshesCarryTheirOwnBlending() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeMaterial("materials/mat0.json", texture: "red", blending: "disabled", root: root)
        try writeMaterial("materials/mat1.json", texture: "green", blending: "translucent", root: root)
        try writeMaterial("materials/mat2.json", texture: "red", root: root)
        try writeModel(materials: ["materials/mat0.json", "materials/mat1.json", "materials/mat2.json"], root: root)

        let layer = try buildLayer(root: root)

        #expect(layer.meshMaterialBlending == [1: "translucent", 2: "normal"])
        #expect(Set(layer.meshMaterialBlending.keys) == Set(layer.meshMaterialConstants.keys))
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPESceneModelSubmeshMaterialTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("models"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("materials"), withIntermediateDirectories: true)
        return root
    }

    private func writeMaterial(_ path: String, texture: String, blending: String? = nil, root: URL) throws {
        var pass: [String: Any] = ["shader": "generic4", "textures": [texture]]
        pass["blending"] = blending
        let json: [String: Any] = ["passes": [pass]]
        try JSONSerialization.data(withJSONObject: json).write(to: root.appendingPathComponent(path))
    }

    private func writeModel(materials: [String], root: URL) throws {
        try SubmeshMDLVFixture.data(materials: materials).write(to: root.appendingPathComponent("models/multi.mdl"))
    }

    private func buildLayer(root: URL) throws -> WPERenderLayer {
        let scene: [String: Any] = [
            "camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 1920, "height": 1080, "auto": true]],
            "objects": [["id": "multi", "name": "Multi", "solid": true, "model": "models/multi.mdl"]],
        ]
        let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: scene))
        let graph = try WPERenderGraphBuilder(cacheRootURL: root).build(document: document)
        return try #require(graph.layers.first)
    }
}

@Suite("WPE scene-model submesh material binding")
struct WPESceneModelSubmeshMaterialRenderTests {
    private let size = CGSize(width: 24, height: 8)

    @Test("Each submesh draw samples its own material texture",
          arguments: ["genericimage2", "generic2", "generic4", "chroma4"])
    func eachSubmeshSamplesItsOwnTexture(shader: String) throws {
        try renderSubmeshes(shader: shader, componentMapOnFirstMesh: nil)
    }

    @Test("Component-map emissive enablement follows each submesh binding", arguments: [true, false])
    func eachSubmeshUsesItsOwnComponentPresence(firstMeshHasMap: Bool) throws {
        try renderSubmeshes(shader: "generic4", componentMapOnFirstMesh: firstMeshHasMap)
    }

    @Test("Loaded submesh tint, defaults, explicit zero and missing-material fallback", arguments: [0, 1, 2, 3])
    func eachSubmeshUsesItsOwnTint(caseIndex: Int) throws {
        try renderSubmeshes(shader: "generic4", componentMapOnFirstMesh: nil, tintCase: caseIndex)
    }

    @Test("MODEL normal retains straight RGB through zero and fractional source alpha",
          arguments: ["generic2", "chroma4", "genericimage2"])
    func modelNormalKeepsAuthoredColor(shader: String) throws {
        try renderSubmeshes(shader: shader, componentMapOnFirstMesh: nil, opaquePaddingColor: true, blending: "normal")
    }

    @Test("MODEL disabled retains straight RGB through zero and fractional source alpha",
          arguments: ["generic2", "chroma4", "genericimage2"])
    func modelDisabledKeepsAuthoredColor(shader: String) throws {
        try renderSubmeshes(shader: shader, componentMapOnFirstMesh: nil, opaquePaddingColor: true)
    }

    @Test("A translucent submesh composites source-over beside an opaque-class layer material",
          arguments: ["normal", "disabled", "premultiplieddisabled"])
    func translucentSubmeshBlendsOverBackground(layerBlending: String) throws {
        let fringe: [UInt8] = [192, 128, 64]
        let row = try renderBuiltModel(
            materials: [
                ["shader": "genericimage2", "textures": ["background"], "blending": layerBlending],
                ["shader": "genericimage2", "textures": ["fringe"], "blending": "translucent"],
            ],
            meshSpans: [(-12, 12), (0, 12)],
            textures: ["background": [[32, 64, 160, 255]],
                       "fringe": [fringe + [0], fringe + [0], fringe + [128], fringe + [128]]]
        )
        let alpha = 128.0 / 255.0
        let background = [32.0, 64.0, 160.0]
        let over = (0 ..< 3).map { Double(fringe[$0]) * alpha + background[$0] * (1 - alpha) }
        for channel in 0 ..< 3 {
            #expect(abs(Double(row[15][channel]) - background[channel]) <= 3,
                    "\(layerBlending): translucent A0 texel must leave the background: \(row[15])")
            #expect(abs(Double(row[21][channel]) - over[channel]) <= 3,
                    "\(layerBlending): translucent A128 texel must composite source-over \(over): \(row[21])")
            #expect(abs(Double(row[4][channel]) - background[channel]) <= 3,
                    "\(layerBlending): layer-material mesh must cover the canvas: \(row[4])")
        }
    }

    @Test("An opaque submesh keeps its A0 padding colour beside a translucent submesh",
          arguments: ["genericimage2", "generic2", "generic4", "chroma4"])
    func opaqueSubmeshKeepsPaddingBesideTranslucentSubmesh(shader: String) throws {
        let paint: [UInt8] = [192, 128, 64]
        func material(_ texture: String, _ blending: String) -> [String: Any] {
            ["shader": shader, "textures": [texture], "blending": blending, "combos": ["LIGHTING": 0, "REFLECTION": 0]]
        }
        let row = try renderBuiltModel(
            materials: [material("padding", "normal"), material("fringe", "translucent"), material("reference", "normal")],
            meshSpans: [(-12, -4), (-4, 4), (4, 12)],
            textures: ["padding": [paint + [0]], "fringe": [paint + [0]], "reference": [paint + [255]]]
        )
        let (padding, reference) = (row[4], row[20])
        try #require((0 ..< 3).contains { reference[$0] > 32 }, "\(shader): A255 reference mesh must draw: \(reference)")
        for channel in 0 ..< 3 {
            #expect(abs(Int(padding[channel]) - Int(reference[channel])) <= 2,
                    "\(shader): opaque A0 padding lost its RGB: \(padding), reference \(reference)")
        }
    }

    @Test("genericimage2 submesh rebuilds image uniforms from its own constants, fallback restores the layer's")
    func genericImageSubmeshUsesItsOwnConstants() throws {
        let row = try renderBuiltModel(
            materials: [
                ["shader": "genericimage2", "textures": ["gray"], "blending": "disabled"],
                ["shader": "genericimage2", "textures": ["gray"], "blending": "disabled", "constantshadervalues": ["color": "0.5 0.5 0.5"]],
            ],
            meshMaterialIndices: [0, 1, 0],
            materialUniformNames: ["color": "g_Color"],
            meshSpans: [(-12, -4), (-4, 4), (4, 12)],
            textures: ["gray": [[200, 200, 200, 255]]]
        )
        for (actual, expected) in zip([row[4], row[12], row[20]], [200, 100, 200]) {
            #expect(abs(Int(actual.x) - expected) <= 2, "regions (left, middle, right) = \([row[4], row[12], row[20]])")
        }
    }

    @Test("Scene-model PMA primary input unpremultiplies only for a submesh that samples it",
          arguments: [false, true])
    func modelInputConversionFollowsSubmeshAlbedo(submeshOwnsAlbedo: Bool) throws {
        let source = WPETextureReference.fbo("producer")
        let pass = WPERenderPass(
            id: "multi.material", phase: .material, shader: "generic4", source: source,
            target: .scene, textures: [:], binds: [:], constants: [:], combos: [:],
            blending: "premultiplied", cullMode: "nocull", depthTest: "disabled", depthWrite: "disabled"
        )
        let declared = WPEPassRenderContract.resolve(
            pass: pass, shader: nil, bindings: [:], alphaOverride: nil,
            inputDeclarations: [0: WPEPassInputContract(reference: source, semantics: .premultipliedColor, origin: .producer)]
        )
        let prepared = WPEPreparedRenderPass(
            pass: pass, shader: nil, textureBindings: [:], comboValues: [:], uniformValues: [:], renderContract: declared
        )
        try #require(prepared.renderContract.inputs[0]?.semantics.alpha == .premultiplied)

        let pipeline = WPEMetalRenderExecutor.sceneModelMeshPipeline(for: prepared, meshBlending: nil, meshOwnsAlbedo: submeshOwnsAlbedo)

        #expect(pipeline.nativeAlpha.input == (submeshOwnsAlbedo ? .none : .unpremultiply))
    }

    @Test("Each submesh's blending picks its own PSO blend and output representation")
    func submeshBlendingPicksItsOwnPipeline() {
        func pipeline(layerBlending: String, meshBlending: String?) -> WPEMetalRenderExecutor.SceneModelMeshPipeline {
            let pass = WPERenderPass(
                id: "multi.material", phase: .material, shader: "generic4", source: .asset("albedo"),
                target: .scene, textures: [:], binds: [:], constants: [:], combos: [:],
                blending: layerBlending, cullMode: "nocull", depthTest: "disabled", depthWrite: "disabled"
            )
            let prepared = WPEPreparedRenderPass(pass: pass, shader: nil, textureBindings: [:], comboValues: [:], uniformValues: [:])
            return WPEMetalRenderExecutor.sceneModelMeshPipeline(for: prepared, meshBlending: meshBlending, meshOwnsAlbedo: false)
        }

        let opaque = pipeline(layerBlending: "normal", meshBlending: nil)
        #expect(opaque.blendMode == "disabled" && opaque.nativeAlpha.straightOutput)
        let translucent = pipeline(layerBlending: "normal", meshBlending: "translucent")
        #expect(translucent.blendMode == "premultiplied" && !translucent.nativeAlpha.straightOutput)
        let opaqueBesideAdditive = pipeline(layerBlending: "premultipliedAdditive", meshBlending: "disabled")
        #expect(opaqueBesideAdditive.blendMode == "disabled" && opaqueBesideAdditive.nativeAlpha.straightOutput)
        let sharedAdditive = pipeline(layerBlending: "premultipliedAdditive", meshBlending: "premultipliedadditive")
        #expect(sharedAdditive.blendMode == "premultipliedAdditive")
    }

    private func renderSubmeshes(shader: String, componentMapOnFirstMesh: Bool?, tintCase: Int? = nil,
                                 opaquePaddingColor: Bool = false, blending: String = "disabled") throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let red = try solid(device: device, opaquePaddingColor ? [192, 128, 64, 0]
            : tintCase != nil ? [64, 64, 64, 255] : (componentMapOnFirstMesh == nil ? [255, 0, 0, 255] : [128, 32, 32, 255]))
        let green = try solid(device: device, opaquePaddingColor ? [192, 128, 64, 128]
            : tintCase != nil ? [64, 64, 64, 255] : (componentMapOnFirstMesh == nil ? [0, 255, 0, 255] : [32, 128, 32, 255]))
        let reference = opaquePaddingColor ? try solid(device: device, [192, 128, 64, 255]) : red
        let component = try solid(device: device, [0, 0, 0, 255])

        func quad(minX: Float, maxX: Float) -> WPEPuppetMesh {
            WPEPuppetMesh(
                materialPath: "unused",
                vertices: [
                    WPEPuppetVertex(position: SIMD3<Float>(minX, -4, 0), uv: SIMD2<Float>(0, 1)),
                    WPEPuppetVertex(position: SIMD3<Float>(maxX, -4, 0), uv: SIMD2<Float>(1, 1)),
                    WPEPuppetVertex(position: SIMD3<Float>(minX, 4, 0), uv: SIMD2<Float>(0, 0)),
                    WPEPuppetVertex(position: SIMD3<Float>(maxX, 4, 0), uv: SIMD2<Float>(1, 0)),
                ], indices: [0, 1, 2, 2, 1, 3], parts: []
            )
        }
        let model = WPEPuppetModel(version: 23, meshes: [
            quad(minX: -12, maxX: -4), quad(minX: -4, maxX: 4), quad(minX: 4, maxX: 12),
        ])
        var baseTextures: [Int: WPETextureReference] = [0: .asset("red")]
        var middleTextures: [Int: WPETextureReference] = [0: .asset("green")]
        if componentMapOnFirstMesh == true {
            baseTextures[2] = .asset("component")
        }
        if componentMapOnFirstMesh == false {
            middleTextures[2] = .asset("component")
        }
        let materialConstants: [String: WPESceneShaderConstantValue] = componentMapOnFirstMesh == nil ? [:]
            : ["emissivecolor": .vector([1, 1, 1]), "emissivebrightness": .number(1)]
        let pass = WPERenderPass(
            id: "multi.material", phase: .material, shader: shader, source: .asset("red"),
            target: .scene, textures: baseTextures, binds: [:], constants: materialConstants, combos: opaquePaddingColor ? ["LIGHTING": 0, "REFLECTION": 0] : [:],
            blending: blending, cullMode: "nocull", depthTest: "disabled", depthWrite: "disabled"
        )
        let geometry = WPERenderLayerGeometry(
            origin: SIMD3<Double>(12, 4, -1), scale: SIMD3<Double>(1, 1, 1), angles: .zero,
            alignment: .center, size: CGSize(width: 24, height: 8), alpha: 1,
            color: SIMD3<Double>(1, 1, 1), brightness: 1
        )
        var layer = WPERenderLayer(
            objectID: "multi", objectName: "Multi-material mesh", imagePath: "multi.mdl",
            materialPath: "materials/mat0.json", puppetPath: "multi.mdl", geometry: geometry,
            compositeA: "a", compositeB: "b", localFBOs: [], passes: [pass],
            meshMaterialTextures: [1: middleTextures, 2: [0: .asset(opaquePaddingColor ? "reference" : "red")]]
        )
        var materialPass = pass
        if let tintCase {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("SubmeshTint-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root.appendingPathComponent("materials"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("models"), withIntermediateDirectories: true)
            for index in 0 ..< 3 where !(tintCase == 3 && index == 1) {
                var constants: [String: String] = [:]
                if index == 0 {
                    constants["color"] = "1 0.25 0.25"
                }
                if index == 1, tintCase == 0 {
                    constants["color"] = "0.25 1 0.25"
                }
                if index == 1, tintCase == 2 {
                    constants["color"] = "0 0 0"
                }
                let json: [String: Any] = ["passes": [["shader": "generic4", "textures": ["red"],
                                                       "constantshadervalues": constants, "combos": ["LIGHTING": 0], "blending": blending, "cullmode": "nocull"]]]
                try JSONSerialization.data(withJSONObject: json).write(to: root.appendingPathComponent("materials/m\(index).json"))
            }
            try SubmeshMDLVFixture.data(materials: (0 ..< 3).map { "materials/m\($0).json" })
                .write(to: root.appendingPathComponent("models/multi.mdl"))
            let scene: [String: Any] = [
                "camera": ["center": "0 0 0"],
                "general": ["orthogonalprojection": ["width": 24, "height": 8, "auto": false]],
                "objects": [["id": "multi", "name": "Multi", "solid": true, "model": "models/multi.mdl", "origin": "12 4 -1"]],
            ]
            let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: scene))
            layer = try #require(WPERenderGraphBuilder(cacheRootURL: root).build(document: document).layers.first)
            materialPass = try #require(layer.passes.first)
        }
        let pipeline = WPEPreparedRenderPipeline(layers: [
            WPEPreparedRenderLayer(
                graphLayer: layer,
                puppetModel: model,
                passes: [WPEPreparedRenderPass(
                    pass: materialPass,
                    shader: WPEShaderProgram(name: shader, vertexSource: "", fragmentSource: "", isBuiltin: true),
                    textureBindings: [:], comboValues: [:], uniformValues: [:]
                )]
            ),
        ])
        let camera = WPEMetalCameraUniforms(
            orthogonalProjection: WPESceneOrthogonalProjection(width: 24, height: 8, auto: true),
            sceneCamera: .defaultCamera, perspectiveOverrideFOVDegrees: 0, perspectiveObjectIDs: []
        )

        let output = try executor.render(
            pipeline: pipeline, size: size, textures: ["red": red, "green": green, "reference": reference, "component": component], cameraUniforms: camera
        )
        let pixels = try readPixels(output)
        func pixel(x: Int) -> SIMD4<UInt8> {
            let offset = (4 * output.width + x) * 4
            return SIMD4(pixels[offset], pixels[offset + 1], pixels[offset + 2], pixels[offset + 3])
        }
        let regions = [pixel(x: 4), pixel(x: 12), pixel(x: 20)]
        if opaquePaddingColor {
            let expected = SIMD4<UInt8>(192, 128, 64, 255)
            for channel in 0 ..< 3 {
                try #require(abs(Int(regions[2][channel]) - Int(expected[channel])) <= 2,
                             "Independent A255 model reference must cover the probe: \(regions[2])")
                for sample in regions.prefix(2) {
                    #expect(abs(Int(sample[channel]) - Int(regions[2][channel])) <= 2,
                            "MODEL \(shader) \(blending) must retain RGB for A0/A128: \(sample), reference \(regions[2])")
                }
            }
            #expect(regions.allSatisfy { $0.w == 255 }, "Scene RGB-only writes must preserve canvas alpha: \(regions)")
        } else if let tintCase {
            let expectedMiddle: SIMD4<UInt8> = tintCase == 0 ? SIMD4(16, 64, 16, 255)
                : tintCase == 1 ? SIMD4(64, 64, 64, 255)
                : tintCase == 2 ? SIMD4(0, 0, 0, 255) : SIMD4(64, 16, 16, 255)
            for (actual, expected) in zip(regions, [SIMD4<UInt8>(64, 16, 16, 255), expectedMiddle, SIMD4<UInt8>(64, 64, 64, 255)]) {
                #expect(abs(Int(actual.x) - Int(expected.x)) <= 2 && abs(Int(actual.y) - Int(expected.y)) <= 2
                    && abs(Int(actual.z) - Int(expected.z)) <= 2 && actual.w == expected.w, "actual \(actual), expected \(expected)")
            }
        } else {
            #expect(regions.map { $0.x > $0.y } == [true, false, true], "regions (left, middle, right) = \(regions)")
            #expect(regions.map { $0.y > $0.x } == [false, true, false], "regions (left, middle, right) = \(regions)")
        }
        if let firstHasMap = componentMapOnFirstMesh {
            #expect(abs(Int(regions[0].z) - (firstHasMap ? 64 : 32)) <= 2, "first mesh emissive = \(regions[0])")
            #expect(abs(Int(regions[1].z) - (firstHasMap ? 32 : 64)) <= 2, "alternate mesh emissive = \(regions[1])")
            #expect(abs(Int(regions[2].z) - 32) <= 2, "alternate without component map must remain non-emissive: \(regions[2])")
        }
    }

    /// Builds the layer from material json through the graph builder, then draws one quad per span; returns row y=4.
    private func renderBuiltModel(materials: [[String: Any]], meshMaterialIndices: [Int]? = nil,
                                  materialUniformNames: [String: String] = [:],
                                  meshSpans: [(Float, Float)], textures: [String: [[UInt8]]]) throws -> [SIMD4<UInt8>] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SubmeshBlend-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("materials"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("models"), withIntermediateDirectories: true)
        for (index, material) in materials.enumerated() {
            var pass = material
            pass["cullmode"] = "nocull"
            try JSONSerialization.data(withJSONObject: ["passes": [pass]])
                .write(to: root.appendingPathComponent("materials/m\(index).json"))
        }
        let indices = meshMaterialIndices ?? Array(materials.indices)
        try SubmeshMDLVFixture.data(materials: indices.map { "materials/m\($0).json" })
            .write(to: root.appendingPathComponent("models/multi.mdl"))
        let scene: [String: Any] = [
            "camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 24, "height": 8, "auto": false]],
            "objects": [["id": "multi", "name": "Multi", "solid": true, "model": "models/multi.mdl", "origin": "12 4 -1"]],
        ]
        let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: scene))
        let layer = try #require(WPERenderGraphBuilder(cacheRootURL: root).build(document: document).layers.first)
        let materialPass = try #require(layer.passes.first)

        let model = WPEPuppetModel(version: 23, meshes: meshSpans.map { minX, maxX in
            WPEPuppetMesh(
                materialPath: "unused",
                vertices: [
                    WPEPuppetVertex(position: SIMD3<Float>(minX, -4, 0), uv: SIMD2<Float>(0, 1)),
                    WPEPuppetVertex(position: SIMD3<Float>(maxX, -4, 0), uv: SIMD2<Float>(1, 1)),
                    WPEPuppetVertex(position: SIMD3<Float>(minX, 4, 0), uv: SIMD2<Float>(0, 0)),
                    WPEPuppetVertex(position: SIMD3<Float>(maxX, 4, 0), uv: SIMD2<Float>(1, 0)),
                ], indices: [0, 1, 2, 2, 1, 3], parts: []
            )
        })
        let pipeline = WPEPreparedRenderPipeline(layers: [
            WPEPreparedRenderLayer(
                graphLayer: layer,
                puppetModel: model,
                passes: [WPEPreparedRenderPass(
                    pass: materialPass,
                    shader: WPEShaderProgram(name: materialPass.shader, vertexSource: "", fragmentSource: "", isBuiltin: true),
                    textureBindings: [:], comboValues: [:], uniformValues: [:], materialUniformNames: materialUniformNames
                )]
            ),
        ])
        let camera = WPEMetalCameraUniforms(
            orthogonalProjection: WPESceneOrthogonalProjection(width: 24, height: 8, auto: true),
            sceneCamera: .defaultCamera, perspectiveOverrideFOVDegrees: 0, perspectiveObjectIDs: []
        )
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let stripTextures = try textures.mapValues { try strip(device: device, $0) }
        let output = try executor.render(pipeline: pipeline, size: size, textures: stripTextures, cameraUniforms: camera)
        let pixels = try readPixels(output)
        return (0 ..< output.width).map { x in
            let offset = (4 * output.width + x) * 4
            return SIMD4(pixels[offset], pixels[offset + 1], pixels[offset + 2], pixels[offset + 3])
        }
    }

    private func strip(device: MTLDevice, _ texels: [[UInt8]]) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: texels.count, height: 1, mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        texture.replace(region: MTLRegionMake2D(0, 0, texels.count, 1), mipmapLevel: 0,
                        withBytes: Array(texels.joined()), bytesPerRow: 4 * texels.count)
        return texture
    }

    private func solid(device: MTLDevice, _ rgba: [UInt8]) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 2, height: 2, mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        let bytes = Array([[UInt8]](repeating: rgba, count: 4).joined())
        texture.replace(region: MTLRegionMake2D(0, 0, 2, 2), mipmapLevel: 0, withBytes: bytes, bytesPerRow: 8)
        return texture
    }

    private func readPixels(_ output: MTLTexture) throws -> [UInt8] {
        let staging = try #require(WPEMetalTextureSnapshotter.stagedForCPURead(output))
        var result = [UInt8](repeating: 0, count: output.width * output.height * 4)
        result.withUnsafeMutableBytes {
            staging.getBytes($0.baseAddress!, bytesPerRow: output.width * 4,
                             from: MTLRegionMake2D(0, 0, output.width, output.height), mipmapLevel: 0)
        }
        return result
    }
}

/// MDLV0016 static scene model with one quad submesh per material path.
private enum SubmeshMDLVFixture {
    static func data(materials: [String]) -> Data {
        var data = Data()
        data.append(contentsOf: Array("MDLV0016".utf8))
        data.appendLE(UInt32(0x0000_0F00))
        data.append(UInt8(0))
        data.appendLE(UInt32(1))
        data.appendLE(UInt32(materials.count))
        for (index, material) in materials.enumerated() {
            data.appendCString(material)
            data.appendLE(UInt32(0))
            data.appendLE(UInt32(0x0000_000F))
            let minX = Float(index * 2)
            var vertices = Data()
            vertices.appendVertex(position: SIMD3<Float>(minX, 0, 0), uv: SIMD2<Float>(0, 1))
            vertices.appendVertex(position: SIMD3<Float>(minX + 1, 0, 0), uv: SIMD2<Float>(1, 1))
            vertices.appendVertex(position: SIMD3<Float>(minX, 1, 0), uv: SIMD2<Float>(0, 0))
            data.appendLE(UInt32(vertices.count))
            data.append(vertices)
            data.appendLE(UInt32(3 * MemoryLayout<UInt16>.size))
            for vertexIndex: UInt16 in [0, 1, 2] {
                data.appendLE(vertexIndex)
            }
        }
        return data
    }
}

private extension Data {
    mutating func appendLE(_ value: UInt16) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ value: UInt32) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ value: Float) {
        appendLE(value.bitPattern)
    }

    mutating func appendCString(_ string: String) {
        append(contentsOf: Array(string.utf8))
        append(UInt8(0))
    }

    /// Position, normal, tangent (vec4), UV — the 0x0F vertex layout.
    mutating func appendVertex(position: SIMD3<Float>, uv: SIMD2<Float>) {
        for value in [position.x, position.y, position.z, 0, 0, 1, 1, 0, 0, 1, uv.x, uv.y] {
            appendLE(value)
        }
    }
}
