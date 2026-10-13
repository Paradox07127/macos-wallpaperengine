import Foundation
@testable import LiveWallpaperProWPE
import Testing

/// MDLV0021's flag 0x20 is native TEXCOORD0 float4 (not a second semantic). Its last two components and the
/// independent optional companion block both survive parsing without assigning the latter unproved semantics.
@Suite("WPEMdlParser UV2-implied UV")
struct WPEMdlParserUV2ImpliedUVTests {
    @Test("UV2-only mesh keeps texcoords in the vertex layout")
    func uv2OnlyMeshParses() throws {
        let model = try WPEMdlParser.parse(data: twoMeshMDLV21())

        #expect(model.meshes.count == 2)
        let channelMap = model.meshes[1]
        #expect(channelMap.materialPath == "materials/b.json")
        #expect(channelMap.vertices.count == 4)
        #expect(channelMap.indices == [0, 1, 2, 2, 3, 0])
        #expect(channelMap.vertices[0].uv == SIMD2<Float>(0, 0))
        #expect(channelMap.vertices[2].uv == SIMD2<Float>(1, 1))
        let attribute = try #require(channelMap.vertexStream?.layout.attributes(semantic: "TEXCOORD", index: 0).first)
        #expect(attribute.componentCount == 4)
    }

    @Test("The optional companion block retains its own header and bytes")
    func companionPayloadRemainsIndependent() throws {
        let model = try WPEMdlParser.parse(data: twoMeshMDLV21(includeCompanion: true))
        let mesh = model.meshes[1]
        let companion = try #require(mesh.companion)
        #expect(companion.hasPayload == 1)
        #expect(companion.headerWord == 0x1234)
        #expect(companion.headerByte == 7)
        #expect(companion.declaredByteCount == 48)
        #expect(companion.data == Data((0 ..< 48).map(UInt8.init)))
        #expect(mesh.vertexStream?.layout.stride == 44)
        #expect(mesh.vertexStream?.layout.attributes(semantic: "TEXCOORD", index: 1).isEmpty == true)
    }

    private func twoMeshMDLV21(includeCompanion: Bool = false) -> Data {
        var data = Data()
        data.append(contentsOf: Array("MDLV0021".utf8))
        data.append(UInt8(0))
        data.appendLE(UInt32(0x0180_0009)) // header flags (unused for v15+ meshes)
        data.appendLE(UInt32(1)) // skin count
        data.appendLE(UInt32(2)) // mesh count

        // Mesh 0: plain triangle, uv only.
        data.appendCString("materials/a.json")
        data.appendLE(UInt32(0)) // flagA
        for value in [Float(0), 0, 0, 1, 1, 0] {
            data.appendLE(value)
        } // bounds
        data.appendLE(UInt32(0x8)) // mesh flags: uv
        var mesh0 = Data()
        for (x, y, u, v) in [
            (Float(0), Float(0), Float(0), Float(0)),
            (Float(1), Float(0), Float(1), Float(0)),
            (Float(0), Float(1), Float(0), Float(1)),
        ] {
            mesh0.appendLE(x); mesh0.appendLE(y); mesh0.appendLE(Float(0))
            mesh0.appendLE(u); mesh0.appendLE(v)
        }
        data.appendLE(UInt32(mesh0.count))
        data.append(mesh0)
        data.appendLE(UInt32(6)) // index bytes: 3x u16
        for i in [UInt16(0), 1, 2] {
            data.appendLE(i)
        }
        data.append(UInt8(0)) // uv2 marker
        data.append(UInt8(0)) // hasParts

        // Mesh 1: flags 0x00800021 (POSITION0, BLENDINDICES0, TEXCOORD0 float4).
        data.appendCString("materials/b.json")
        data.appendLE(UInt32(2)) // flagA
        data.appendLE(UInt32(1)) // flagA payload
        for value in [Float(0), 0, 0, 1, 1, 0] {
            data.appendLE(value)
        } // bounds
        data.appendLE(UInt32(0x0080_0021))
        var mesh1 = Data()
        for (x, y, u, v, u2, v2) in [
            (Float(0), Float(0), Float(0), Float(0), Float(0.25), Float(0.25)),
            (Float(1), Float(0), Float(1), Float(0), Float(0.75), Float(0.25)),
            (Float(1), Float(1), Float(1), Float(1), Float(0.75), Float(0.75)),
            (Float(0), Float(1), Float(0), Float(1), Float(0.25), Float(0.75)),
        ] {
            mesh1.appendLE(x); mesh1.appendLE(y); mesh1.appendLE(Float(0))
            for _ in 0 ..< 4 {
                mesh1.appendLE(Int32(0))
            } // skinBlendIndices
            mesh1.appendLE(u); mesh1.appendLE(v)
            mesh1.appendLE(u2); mesh1.appendLE(v2)
        }
        data.appendLE(UInt32(mesh1.count))
        data.append(mesh1)
        data.appendLE(UInt32(12)) // index bytes: 6x u16 quad
        for i in [UInt16(0), 1, 2, 2, 3, 0] {
            data.appendLE(i)
        }
        if includeCompanion {
            data.append(contentsOf: [1, 1]) // companion marker and payload present
            data.appendLE(UInt16(0x1234))
            data.append(UInt8(7))
            data.appendLE(UInt32(48))
            data.append(contentsOf: (0 ..< 48).map(UInt8.init))
        } else {
            data.append(UInt8(0))
        }
        data.append(UInt8(0)) // hasParts

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

    mutating func appendLE(_ value: Int32) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ value: Float) {
        appendLE(value.bitPattern)
    }

    mutating func appendCString(_ string: String) {
        append(contentsOf: string.utf8)
        append(UInt8(0))
    }
}
