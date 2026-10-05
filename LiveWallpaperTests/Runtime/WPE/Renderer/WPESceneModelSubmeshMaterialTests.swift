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

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPESceneModelSubmeshMaterialTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("models"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("materials"), withIntermediateDirectories: true)
        return root
    }

    private func writeMaterial(_ path: String, texture: String, root: URL) throws {
        let json: [String: Any] = ["passes": [["shader": "generic4", "textures": [texture]]]]
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

    private func renderSubmeshes(shader: String, componentMapOnFirstMesh: Bool?, tintCase: Int? = nil) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let red = try solid(device: device, tintCase != nil ? [64, 64, 64, 255] : (componentMapOnFirstMesh == nil ? [255, 0, 0, 255] : [128, 32, 32, 255]))
        let green = try solid(device: device, tintCase != nil ? [64, 64, 64, 255] : (componentMapOnFirstMesh == nil ? [0, 255, 0, 255] : [32, 128, 32, 255]))
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
            target: .scene, textures: baseTextures, binds: [:], constants: materialConstants, combos: [:],
            blending: "disabled", cullMode: "nocull", depthTest: "disabled", depthWrite: "disabled"
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
            meshMaterialTextures: [1: middleTextures, 2: [0: .asset("red")]]
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
                                                       "constantshadervalues": constants, "combos": ["LIGHTING": 0], "blending": "disabled", "cullmode": "nocull"]]]
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
            pipeline: pipeline, size: size, textures: ["red": red, "green": green, "component": component], cameraUniforms: camera
        )
        let pixels = try readPixels(output)
        func pixel(x: Int) -> SIMD4<UInt8> {
            let offset = (4 * output.width + x) * 4
            return SIMD4(pixels[offset], pixels[offset + 1], pixels[offset + 2], pixels[offset + 3])
        }
        let regions = [pixel(x: 4), pixel(x: 12), pixel(x: 20)]
        if let tintCase {
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
