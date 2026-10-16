#if !LITE_BUILD && DEBUG
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import XCTest

/// A scene model's u32 MDLV indices upload as R32; puppets keep R16.
final class WPEParityModelIndexWidthTests: XCTestCase {
    private static let vertexInputs = """
    [{"name":"position0","index":0,"elementType":"float","columns":3},
     {"name":"texcoord0","index":1,"elementType":"float","columns":2}]
    """

    func testU32ModelMeshUploadsR32Indices() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        // Index 65536 is out of R16 range, so a halved upload cannot reach the last vertex.
        let mesh = WPEPuppetMesh(materialPath: "m", vertices: Self.vertices(65537), indices: [65536, 1, 0],
                                 indexElementWidth: .uint32, parts: [])
        let geometry = try XCTUnwrap(WPEParityFrameDrawPlanner.modelGeometry(mesh, inputs: Self.inputs(),
                                                                             device: device))
        XCTAssertEqual(geometry.indexCount, 3)
        XCTAssertEqual(geometry.indexType, .uint32)
        let indices = geometry.indices.contents().assumingMemoryBound(to: UInt32.self)
        XCTAssertEqual(Array(UnsafeBufferPointer(start: indices, count: 3)), [65536, 1, 0])
    }

    func testU16ModelMeshKeepsR16Indices() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let mesh = WPEPuppetMesh(materialPath: "m", vertices: Self.vertices(3), indices: [2, 1, 0], parts: [])
        let geometry = try XCTUnwrap(WPEParityFrameDrawPlanner.modelGeometry(mesh, inputs: Self.inputs(),
                                                                             device: device))
        XCTAssertEqual(geometry.indexCount, 3)
        XCTAssertEqual(geometry.indexType, .uint16)
        let indices = geometry.indices.contents().assumingMemoryBound(to: UInt16.self)
        XCTAssertEqual(Array(UnsafeBufferPointer(start: indices, count: 3)), [2, 1, 0])
    }

    private static func vertices(_ count: Int) -> [WPEPuppetVertex] {
        (0 ..< count).map { WPEPuppetVertex(position: SIMD3(Float($0), 0, 0), uv: .zero) }
    }

    private static func inputs() throws -> [WPEStageReflection.StageAttribute] {
        try JSONDecoder().decode([WPEStageReflection.StageAttribute].self, from: Data(vertexInputs.utf8))
    }
}
#endif
