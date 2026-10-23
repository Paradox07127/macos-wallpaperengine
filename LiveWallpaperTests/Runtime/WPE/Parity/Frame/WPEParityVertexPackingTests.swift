#if !LITE_BUILD && DEBUG
import Foundation
@testable import LiveWallpaper
@testable import LiveWallpaperProWPE
import Metal
import XCTest

final class WPEParityVertexPackingTests: XCTestCase {
    private typealias Vertex = WPEParityFrameDrawPlanner.Vertex

    private func attributes(_ json: String) throws -> [WPEStageReflection.StageAttribute] {
        try JSONDecoder().decode([WPEStageReflection.StageAttribute].self, from: Data(json.utf8))
    }

    private func f(_ value: Float) -> UInt32 {
        value.bitPattern
    }

    private func packedWords(_ vertices: [Vertex], inputs: [WPEStageReflection.StageAttribute],
                             device: MTLDevice) throws -> (words: [UInt32], length: Int) {
        let planned = WPEParityFrameDrawPlanner.geometry(vertices, indices: [UInt16(0), 1, 0], inputs: inputs,
                                                         device: device)
        let geometry = try XCTUnwrap(planned, "geometry returned nil, so no vertex buffer was allocated")
        let buffer = geometry.vertices
        let count = buffer.length / MemoryLayout<UInt32>.stride
        let words = Array(UnsafeBufferPointer(start: buffer.contents().bindMemory(to: UInt32.self, capacity: count),
                                              count: count))
        return (words, buffer.length)
    }

    func testMixedCaseUnorderedInputsPackPerReflectionOrderAndColumns() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let inputs = try attributes("""
        [
          {"name": "TEXCOORD0", "index": 1, "elementType": "float", "columns": 2},
          {"name": "TexCoord1", "index": 6, "elementType": "float", "columns": 2},
          {"name": "Position", "index": 0, "elementType": "float", "columns": 3},
          {"name": "COLOR0", "index": 5, "elementType": "float", "columns": 4},
          {"name": "BLENDINDICES", "index": 3, "elementType": "uint", "columns": 4},
          {"name": "normal", "index": 4, "elementType": "float", "columns": 3},
          {"name": "BlendWeight0", "index": 2, "elementType": "float", "columns": 3}
        ]
        """)
        let vertices = [
            Vertex(position: SIMD3(1, 2, 3), texcoord: SIMD2(0.25, 0.5),
                   blendIndices: SIMD4(1, 2, 3, 4), blendWeights: SIMD4(0.5, 0.25, 0.125, 0.0625),
                   normal: SIMD3(0, 1, 0)),
            Vertex(position: SIMD3(-1, 0, 4), texcoord: SIMD2(0.75, 1)),
        ]
        let expected: [UInt32] = [
            f(1), f(2), f(3), f(0.25), f(0.5), f(0.5), f(0.25), f(0.125), 1, 2, 3, 4,
            f(0), f(1), f(0), f(1), f(1), f(1), f(1), 0, 0,
            f(-1), f(0), f(4), f(0.75), f(1), 0, 0, 0, 0, 0, 0, 0,
            f(0), f(0), f(1), f(1), f(1), f(1), f(1), 0, 0,
        ]
        let packed = try packedWords(vertices, inputs: inputs, device: device)
        XCTAssertEqual(packed.length, expected.count * 4,
                       "vertex buffer length differs from 21 words per vertex across two vertices")
        XCTAssertEqual(packed.words, expected,
                       "packed words differ from the index-ordered, column-truncated layout of the inputs")
    }

    func testFourColumnPositionCarriesUnitW() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let inputs = try attributes("""
        [{"name": "POSITION", "index": 0, "elementType": "float", "columns": 4},
         {"name": "texcoord0", "index": 1, "elementType": "float", "columns": 4}]
        """)
        let packed = try packedWords([Vertex(position: SIMD3(5, 6, 7), texcoord: SIMD2(0.125, 0.875))],
                                     inputs: inputs, device: device)
        XCTAssertEqual(packed.words, [f(5), f(6), f(7), f(1), f(0.125), f(0.875), f(0), f(0)],
                       "a four-column position lost its unit w, or texcoord0 padding is non-zero")
    }

    func testEmptyInputsStillAllocateSixteenBytes() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let packed = try packedWords([Vertex(position: SIMD3(1, 1, 1), texcoord: .zero)], inputs: [], device: device)
        XCTAssertEqual(packed.length, 16, "an input-less vertex stage got a vertex buffer shorter than 16 bytes")
    }

    func testShortPackingIsPaddedToSixteenBytes() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let inputs = try attributes("""
        [{"name": "TexCoord0", "index": 0, "elementType": "float", "columns": 2}]
        """)
        let packed = try packedWords([Vertex(position: .zero, texcoord: SIMD2(0.5, 0.25))], inputs: inputs,
                                     device: device)
        XCTAssertEqual(packed.length, 16, "an eight-byte packing was not padded to the 16-byte minimum")
        XCTAssertEqual(Array(packed.words.prefix(2)), [f(0.5), f(0.25)],
                       "a lone two-column texcoord0 input packed something other than u, v")
    }
}
#endif
