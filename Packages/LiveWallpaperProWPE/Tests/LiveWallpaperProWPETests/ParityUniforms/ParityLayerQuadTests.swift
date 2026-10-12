@testable import LiveWallpaperProWPE
import simd
import XCTest

final class ParityLayerQuadTests: XCTestCase {
    /// RenderDoc vertex input for a 3840×2160 layer (windows-capture-20261007 center-a1 phase2).
    func testLayerQuadMatchesCapture() {
        let quad = WPEParityLayerQuad.layer(size: SIMD2(3840, 2160))
        XCTAssertEqual(quad.vertices.map(\.position), [
            SIMD3(-1920, 1080, 0), SIMD3(1920, 1080, 0), SIMD3(-1920, -1080, 0), SIMD3(1920, -1080, 0),
        ])
        XCTAssertEqual(quad.vertices.map(\.texcoord), [SIMD2(0, 0), SIMD2(1, 0), SIMD2(0, 1), SIMD2(1, 1)])
        XCTAssertEqual(WPEParityLayerQuad.indices, [0, 2, 1, 1, 2, 3])
        XCTAssertEqual(WPEParityLayerQuad.stride, 20)
        XCTAssertEqual(quad.packed.count * MemoryLayout<Float>.stride, 4 * WPEParityLayerQuad.stride)
        XCTAssertEqual(Array(quad.packed.prefix(5)), [-1920, 1080, 0, 0, 0])
    }

    func testMeshSizeIsTruncated() {
        let quad = WPEParityLayerQuad.layer(size: SIMD2(101.9, 50.5))
        XCTAssertEqual(quad.vertices[3].position, SIMD3(50.5, -25, 0))
    }

    func testUVMaxInsetAndFlip() {
        let scaled = WPEParityLayerQuad(size: SIMD2(100, 50), uvMax: SIMD2(0.5, 0.25))
        XCTAssertEqual(scaled.vertices[3].texcoord, SIMD2(0.5, 0.25))
        let inset = WPEParityLayerQuad(size: SIMD2(100, 50), insetsUV: true)
        let corners = [inset.vertices[0].texcoord, inset.vertices[3].texcoord]
        let expected: [SIMD2<Float>] = [SIMD2(0.0015, 0.003), SIMD2(1 - 0.0015, 1 - 0.003)]
        for (corner, want) in zip(corners, expected) {
            XCTAssertLessThan(simd_distance(corner, want), 1e-6, "\(corner)")
        }
        let effect = WPEParityLayerQuad.effectPass
        XCTAssertEqual(effect.vertices.map(\.position), [SIMD3(-1, 1, 0), SIMD3(1, 1, 0), SIMD3(-1, -1, 0),
                                                         SIMD3(1, -1, 0)])
        XCTAssertEqual(effect.vertices.map(\.texcoord), [SIMD2(0, 1), SIMD2(1, 1), SIMD2(0, 0), SIMD2(1, 0)])
    }
}
