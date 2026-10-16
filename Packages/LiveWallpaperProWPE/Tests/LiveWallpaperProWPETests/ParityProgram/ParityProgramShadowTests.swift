import Foundation
@testable import LiveWallpaperProWPE
import Testing

private typealias D = ParitySceneDocuments

struct ParityProgramShadowTests {
    private static func scene(shadowQuality: Int32) throws -> WPEParityProgramScene {
        let castshadow: [Any?] = [nil, false, ["value": false]]
        let layers = castshadow.enumerated().map { index, value in
            var json: [String: Any] = [:]
            json["castshadow"] = value
            return D.layer("\(index + 1)", image: "models/m\(index + 1).mdl", json: json)
        }
        let model = ShadowMDLFixture.data(materials: ["materials/generic4.json"])
        return try D.programScene(
            layers, general: ["lightconfig": ["spot": 1, "spotshadow": 1]],
            files: ["materials/generic4.json": #"{"passes":[{"shader":"generic4"}]}"#],
            binaries: Dictionary(uniqueKeysWithValues: (1 ... 3).map { ("models/m\($0).mdl", model) }),
            settings: WPEParityProgramSettings(shadowQuality: shadowQuality)
        )
    }

    @Test func shadowQualityReadsShadowLightsAndModelsCastByDefault() throws {
        let scene = try Self.scene(shadowQuality: 2)
        #expect(scene.engineFlags.shadowQuality == 2)
        #expect(scene.engineFlags.spotShadowLights == 1)
        #expect(scene.scene.shadowAtlas)
        let casts = scene.scene.objects.compactMap { object -> Bool? in
            guard case let .model(model) = object.kind else { return nil }
            return model.castsShadow
        }
        #expect(casts == [true, false, false])
        #expect(scene.models.values.allSatisfy { $0.meshes.count == 1 })
    }

    @Test func shadowQualityZeroDropsShadowLightsAndTheAtlas() throws {
        let scene = try Self.scene(shadowQuality: 0)
        #expect(scene.engineFlags.spotShadowLights == 0)
        #expect(!scene.scene.shadowAtlas)
    }
}

/// MDLV0016 static scene model with one quad submesh per material path.
private enum ShadowMDLFixture {
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

    /// Position, normal, tangent (vec4), UV: the 0x0F vertex layout.
    mutating func appendVertex(position: SIMD3<Float>, uv: SIMD2<Float>) {
        for value in [position.x, position.y, position.z, 0, 0, 1, 1, 0, 0, 1, uv.x, uv.y] {
            appendLE(value)
        }
    }
}
