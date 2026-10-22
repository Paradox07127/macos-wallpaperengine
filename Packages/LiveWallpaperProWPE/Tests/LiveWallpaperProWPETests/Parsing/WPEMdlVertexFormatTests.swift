import Foundation
@testable import LiveWallpaperProWPE
import simd
import Testing

/// WPE's vertex format table (exe 0x140484a20 flags, 0x1404849b0 sizes): attributes sit in table order.
@Suite("WPEMdlParser vertex format table")
struct WPEMdlVertexFormatTests {
    @Test("Stride is the sum of the table sizes of the set bits")
    func strideFollowsTheTable() {
        let sizes: [(UInt32, Int)] = [
            (0x1, 12), (0x10000, 16), (0x2000000, 12), (0x2, 12), (0x4, 16), (0x800000, 16), (0x1000000, 16),
            (0x8, 8), (0x10, 12), (0x20, 16), (0x40, 8), (0x80, 12), (0x100, 16), (0x200, 8), (0x400, 12),
            (0x800, 16), (0x1000, 8), (0x2000, 12), (0x4000, 16), (0x20000, 8), (0x40000, 12), (0x80000, 16),
            (0x100000, 8), (0x200000, 12), (0x400000, 16), (0x8000, 16),
        ]
        for (flag, size) in sizes {
            let withPosition = flag == 0x10000 ? flag : flag | 0x1
            #expect(WPEPuppetVertexLayout(format: withPosition).stride == size + (withPosition == flag ? 0 : 12),
                    "format \(String(flag, radix: 16))")
        }
        #expect(WPEPuppetVertexLayout(format: 0x180000F).stride == 80)
        #expect(WPEPuppetVertexLayout(format: 0x181000E).stride == 84)
        #expect(WPEPuppetVertexLayout(format: 0x1800009).stride == 52)
    }

    @Test("0x10000 is a float4 position right after 0x1, ahead of the normal")
    func positionVec4PrecedesNormal() throws {
        var vertex = Data()
        vertex.le([1, 2, 3, 1] as [Float]) // 0x10000 POSITION float4
        vertex.le([0, 1, 0] as [Float]) // 0x2 NORMAL
        vertex.le([1, 0, 0, 1] as [Float]) // 0x4 TANGENT
        vertex.le([2, 1, 0, 0] as [Int32]) // 0x800000 BLENDINDICES
        vertex.le([0.5, 0.5, 0, 0] as [Float]) // 0x1000000 BLENDWEIGHT
        vertex.le([0.25, 0.75] as [Float]) // 0x8 TEXCOORD0
        let mesh = try #require(WPEMdlParser.parse(data: mdl(format: 0x181000E, flags: 0x1000, vertex: vertex))
            .meshes.first)
        #expect(mesh.vertexFormat == 0x181000E)
        #expect(mesh.flags == 0x1000)
        let parsed = try #require(mesh.vertices.first)
        #expect(mesh.vertices.count == 3)
        #expect(parsed.position == SIMD3(1, 2, 3))
        #expect(parsed.normal == SIMD3(0, 1, 0))
        #expect(parsed.skinBlendIndices == SIMD4(2, 1, 0, 0))
        #expect(parsed.skinBlendWeights == SIMD4(0.5, 0.5, 0, 0))
        #expect(parsed.uv == SIMD2(0.25, 0.75))
    }

    @Test("A three-float texcoord0 (0x10) and a second texcoord set keep the layout")
    func texcoordVariants() throws {
        var vertex = Data()
        vertex.le([4, 5, 6] as [Float]) // 0x1 POSITION
        vertex.le([0.5, 0.25, 9] as [Float]) // 0x10 TEXCOORD0 float3
        vertex.le([7, 7] as [Float]) // 0x40 TEXCOORD1 float2
        vertex.le([8, 8, 8, 8] as [Float]) // 0x8000 COLOR
        let mesh = try #require(WPEMdlParser.parse(data: mdl(format: 0x8051, flags: 0, vertex: vertex)).meshes.first)
        #expect(mesh.vertices.count == 3)
        #expect(mesh.vertices[0].position == SIMD3(4, 5, 6))
        #expect(mesh.vertices[0].uv == SIMD2(0.5, 0.25))
    }

    @Test("Authored shader inputs retain all components and exact unsigned words")
    func rawVertexStreamRetainsSemanticSentinels() throws {
        let format: UInt32 = 0x10000 | 0x2000000 | 0x2 | 0x4 | 0x800000 | 0x1000000
            | 0x20 | 0x80 | 0x200 | 0x4000 | 0x20000 | 0x200000 | 0x8000
        var vertex = Data()
        vertex.le([1, 2, 3, 4, 5, 6, 7, 0, 0, 0, 9, 10, 11, 12] as [Float])
        vertex.le([0xFFFF_FFFF, 0x8000_0000, 12345, 0] as [UInt32])
        vertex.le([0.1, 0.2, 0.3, 0.4, 21, 22, 23, 24, 31, 32, 33, 41, 42,
                   51, 52, 53, 54, 61, 62, 71, 72, 73, 81, 82, 83, 84] as [Float])
        let mesh = try #require(WPEMdlParser.parse(data: mdl(format: format, flags: 0, vertex: vertex)).meshes.first)
        let stream = try #require(mesh.vertexStream)
        #expect(stream.data == vertex + vertex + vertex)
        #expect(stream.vertexCount == 3)
        #expect(stream.layout.stride == 176)
        #expect(!stream.layout.hasSyntheticPosition)
        #expect(stream.layout.attributes.map { "\($0.semantic)\($0.semanticIndex):\($0.byteOffset):\($0.componentCount)" }
            == ["POSITION0:0:4", "POSITION1:16:3", "NORMAL0:28:3", "TANGENT0:40:4",
                "BLENDINDICES0:56:4", "BLENDWEIGHT0:72:4", "TEXCOORD0:88:4", "TEXCOORD1:104:3",
                "TEXCOORD2:116:2", "TEXCOORD3:124:4", "TEXCOORD4:140:2", "TEXCOORD5:148:3", "COLOR0:160:4"])
        #expect(stream.layout.attributes[4].componentType == .uint32)
        #expect(mesh.vertices[0].normal == SIMD3(0, 0, 1), "legacy safety projection stays compatible")
        #expect(mesh.vertices[0].skinBlendIndices.x == -1, "raw input above keeps the original uint32 bits")
    }

    @Test("Duplicate semantic variants stay visible instead of silently choosing the first")
    func duplicateSemanticsRemainExplicit() {
        let layout = WPEPuppetVertexLayout(format: 0x10001)
        #expect(layout.stride == 28)
        #expect(layout.attributes(semantic: "position", index: 0).map(\.componentCount) == [3, 4])
    }

    @Test("Clip flags are the wire word after the name, not either preceding identity word")
    func clipHeaderRetainsFlagsAndIdentity() throws {
        var vertex = Data()
        vertex.le([1, 2, 3, 0.25, 0.75] as [Float])
        var tail = Data([0, 1]) // no companion, part table follows
        tail.le([32, 100, 0, 0, 3, 200, 0, 0, 3, 1, 0x1122_3344, 0xAABB_CCDD] as [UInt32])
        tail.append(contentsOf: Array("masks/a".utf8) + [0])
        tail.le([0x0F, 1, 1, 1, 0] as [UInt32]) // flags, targetCount, target1, sourceCount, source0
        let mesh = try #require(WPEMdlParser.parse(data: mdl(format: 9, flags: 0, vertex: vertex,
                                                             version: 22, tail: tail)).meshes.first)
        let group = try #require(mesh.clipGroups.first)
        #expect(group.flags == 0x0F)
        #expect(group.targetPartIndices == [1])
        #expect(group.sourcePartIndices == [0])
        #expect(WPEParityPuppetClipGroup.groups(of: mesh).first?.flags == 0x0F)
    }

    @Test("Mesh flag bit 1 carries a payload whatever the other bits (140261880.c:264-267)")
    func flagBitOneReadsThePayload() throws {
        var vertex = Data()
        vertex.le([4, 5, 6] as [Float])
        vertex.le([0.5, 0.25] as [Float])
        let mesh = try #require(WPEMdlParser.parse(data: mdl(format: 0x9, flags: 0x6, vertex: vertex)).meshes.first)
        #expect(mesh.flags == 0x6)
        #expect(mesh.vertices.count == 3)
        #expect(mesh.vertices[2].uv == SIMD2(0.5, 0.25))
    }

    @Test("A puppet's index bytes go up as R16, so u32 indices split into halves")
    func puppetIndicesAreSixteenBit() {
        let wide = WPEPuppetMesh(materialPath: "", vertices: [], indices: [0x0002_0001, 3], indexElementWidth: .uint32,
                                 parts: [])
        #expect(WPEParityScenePuppet.indices(of: wide) == [1, 2, 3, 0])
        let narrow = WPEPuppetMesh(materialPath: "", vertices: [], indices: [5, 6, 7], parts: [])
        #expect(WPEParityScenePuppet.indices(of: narrow) == [5, 6, 7])
    }

    @Test("Both puppet position layouts preserve authored unit normals and tangents",
          arguments: [UInt32(0x181000E), UInt32(0x180000F)])
    func authoredNormals(format: UInt32) throws {
        var vertex = Data()
        vertex.le([11, 22, 33] as [Float])
        if format == 0x181000E {
            vertex.le([1] as [Float])
        }
        vertex.le([0.6, 0.8, 0] as [Float])
        vertex.le([0, 0, 1, -1] as [Float])
        vertex.le([2, 1, 0, 0] as [Int32])
        vertex.le([0.75, 0.25, 0, 0] as [Float])
        vertex.le([0.25, 0.75] as [Float])
        let mesh = try #require(WPEMdlParser.parse(data: mdl(format: format, flags: 0x1000, vertex: vertex)).meshes.first)
        #expect(mesh.vertexFormat == format)
        let stream = try #require(mesh.vertexStream)
        #expect(stream.data == vertex + vertex + vertex)
        #expect(mesh.vertices.count == 3)
        for parsed in mesh.vertices {
            #expect(parsed.position == SIMD3(11, 22, 33))
            #expect(parsed.normal == SIMD3(0.6, 0.8, 0))
            #expect(abs(simd_length(parsed.normal) - 1) < 1e-3)
            #expect(parsed.uv == SIMD2(0.25, 0.75))
            #expect(parsed.skinBlendIndices == SIMD4(2, 1, 0, 0))
            #expect(parsed.skinBlendWeights == SIMD4(0.75, 0.25, 0, 0))
        }
    }

    /// MDLV0020: one skin, mesh flags (+ payload when bit 1 is set), bounds, format, three copies of `vertex`.
    private func mdl(format: UInt32, flags: UInt32, vertex: Data, version: Int = 20, tail: Data = Data()) -> Data {
        var data = Data(String(format: "MDLV%04d", version).utf8)
        data.append(0)
        data.le([0, 1, 1] as [UInt32])
        data.append(contentsOf: Array("materials/a.json".utf8) + [0])
        data.le([flags] as [UInt32])
        if flags & 2 != 0 {
            data.le([0] as [UInt32])
        }
        data.le([0, 0, 0, 1, 1, 0] as [Float])
        data.le([format, UInt32(vertex.count * 3)] as [UInt32])
        for _ in 0 ..< 3 {
            data.append(vertex)
        }
        data.le([6] as [UInt32])
        data.le([0, 1, 2] as [UInt16])
        data.append(tail)
        return data
    }
}

private extension Data {
    mutating func le(_ values: [some FixedWidthInteger]) {
        for value in values {
            Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
        }
    }

    mutating func le(_ values: [Float]) {
        le(values.map(\.bitPattern))
    }
}

/// `PKGV` archive: header string, entry count, then (name, offset, size) records before the data block.
enum PackageEntries {
    static func entries(_ data: Data) throws -> [String: Data] {
        let bytes = [UInt8](data)
        var cursor = 0
        func u32() throws -> Int {
            guard cursor + 4 <= bytes.count else { throw CocoaError(.fileReadCorruptFile) }
            defer { cursor += 4 }
            return (0 ..< 4).reduce(0) { $0 | Int(bytes[cursor + $1]) << ($1 * 8) }
        }
        func string() throws -> String {
            let count = try u32()
            guard cursor + count <= bytes.count,
                  let value = String(bytes: bytes[cursor ..< cursor + count], encoding: .utf8) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            cursor += count
            return value
        }
        _ = try string()
        let records = try (0 ..< u32()).map { _ in try (string(), u32(), u32()) }
        return Dictionary(records.map { name, offset, size in
            (name, Data(bytes[(cursor + offset) ..< (cursor + offset + size)]))
        }, uniquingKeysWith: { first, _ in first })
    }
}
