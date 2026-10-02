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
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let red = try solid(device: device, [255, 0, 0, 255])
        let green = try solid(device: device, [0, 255, 0, 255])

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
        let pass = WPERenderPass(
            id: "multi.material", phase: .material, shader: shader, source: .asset("red"),
            target: .scene, textures: [0: .asset("red")], binds: [:], constants: [:], combos: [:],
            blending: "disabled", cullMode: "nocull", depthTest: "disabled", depthWrite: "disabled"
        )
        let geometry = WPERenderLayerGeometry(
            origin: SIMD3<Double>(12, 4, -1), scale: SIMD3<Double>(1, 1, 1), angles: .zero,
            alignment: .center, size: CGSize(width: 24, height: 8), alpha: 1,
            color: SIMD3<Double>(1, 1, 1), brightness: 1
        )
        let layer = WPERenderLayer(
            objectID: "multi", objectName: "Multi-material mesh", imagePath: "multi.mdl",
            materialPath: "materials/mat0.json", puppetPath: "multi.mdl", geometry: geometry,
            compositeA: "a", compositeB: "b", localFBOs: [], passes: [pass],
            meshMaterialTextures: [1: [0: .asset("green")], 2: [0: .asset("red")]]
        )
        let pipeline = WPEPreparedRenderPipeline(layers: [
            WPEPreparedRenderLayer(
                graphLayer: layer,
                puppetModel: model,
                passes: [WPEPreparedRenderPass(
                    pass: pass,
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
            pipeline: pipeline, size: size, textures: ["red": red, "green": green], cameraUniforms: camera
        )
        let pixels = try readPixels(output)
        func pixel(x: Int) -> SIMD4<UInt8> {
            let offset = (4 * output.width + x) * 4
            return SIMD4(pixels[offset], pixels[offset + 1], pixels[offset + 2], pixels[offset + 3])
        }
        let regions = [pixel(x: 4), pixel(x: 12), pixel(x: 20)]
        #expect(regions.map { $0.x > $0.y } == [true, false, true], "regions (left, middle, right) = \(regions)")
        #expect(regions.map { $0.y > $0.x } == [false, true, false], "regions (left, middle, right) = \(regions)")
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
