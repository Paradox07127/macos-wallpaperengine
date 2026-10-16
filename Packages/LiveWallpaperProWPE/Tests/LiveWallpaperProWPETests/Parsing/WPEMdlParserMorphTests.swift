import Foundation
@testable import LiveWallpaperProWPE
import Testing

/// MDMP0001 (140261880.c:3128-3226) with workshop 3647999330's single target.
@Suite("WPEMdlParser MDMP morph targets")
struct WPEMdlParserMorphTests {
    @Test("A 0x1000 mesh reads the positions and the alpha blob")
    func alphaMeshReadsTheTarget() throws {
        let morph = try #require(WPEMdlParser.parse(data: mdl(flags: 0x1000)).meshes.first?.morph)
        #expect(morph.scale == 10.269853)
        #expect(morph.vertexCount == 1)
        #expect(morph.targets.map(\.name) == ["Shape 1706"])
        #expect(morph.targets.first?.positions == [-28174, 16728, 0])
        #expect(morph.targets.first?.alpha == [32767])
        #expect(morph.targets.first?.normals == nil)
    }

    @Test("Without flag 0x1000 the target has no alpha blob")
    func plainMeshHasNoAlpha() throws {
        let morph = try #require(WPEMdlParser.parse(data: mdl(flags: 0)).meshes.first?.morph)
        #expect(morph.vertexCount == 1)
        #expect(morph.targets.first?.positions == [-28174, 16728, 0])
        #expect(morph.targets.first?.alpha == nil)
    }

    /// MDLV0020 with one mesh of three 0x10001 vertices, then MDMP0001 with one target over one vertex.
    private func mdl(flags: UInt32) -> Data {
        var data = Data("MDLV0020".utf8)
        data.append(0)
        data.le([0, 1, 1] as [UInt32])
        data.append(contentsOf: Array("materials/a.json".utf8) + [0])
        data.le([flags] as [UInt32])
        data.le([0, 0, 0, 1, 1, 0] as [Float])
        data.le([0x10001, 3 * 28] as [UInt32])
        for _ in 0 ..< 3 {
            data.le([1, 2, 3, 1, 2, 3, 1] as [Float])
        }
        data.le([6] as [UInt32])
        data.le([0, 1, 2] as [UInt16])

        data.append(contentsOf: Array("MDMP0001".utf8) + [0])
        let endOffset = data.count
        data.le([0] as [UInt32])
        data.le([1] as [UInt16])
        data.le([10.269853] as [Float])
        data.le([1] as [UInt32])
        data.le([0] as [UInt64])
        data.append(contentsOf: Array("Shape 1706".utf8) + [0])
        data.le([6] as [UInt32])
        data.le([-28174, 16728, 0] as [Int16])
        if flags & 0x1000 != 0 {
            data.le([2] as [UInt32])
            data.le([32767] as [Int16])
        }
        withUnsafeBytes(of: UInt32(data.count).littleEndian) { data.replaceSubrange(endOffset ..< endOffset + 4, with: $0) }
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
