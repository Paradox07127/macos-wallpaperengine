@testable import LiveWallpaperProWPE
import simd
import XCTest

extension ParityLayerTransformTests {
    func testObject935ModelAndPackedModelViewProjection() throws {
        let document = try ParityCameraFixture.scene3660962877()
        let layers = WPEParityLayerTransformSet(document: document, renderTargetSize: canvas)
        let angle: Float = -1.5708
        let rotation = simd_float4x4(rows: [
            SIMD4(cos(angle), -sin(angle), 0, 0), SIMD4(sin(angle), cos(angle), 0, 0),
            SIMD4(0, 0, 1, 0), SIMD4(0, 0, 0, 1),
        ])
        let expected = translation(373.25635, 864.29602) * rotation
            * simd_float4x4(diagonal: SIMD4(5.99649, 1.97301, 1, 1))
        assertEqual(layers.model("935"), expected, accuracy: 1e-5)

        let draw = try layers.draw("935", kind: .layer, parallax: canvas / 2)
        guard case let .matrix(packed)? = draw.matrices.values["g_ModelViewProjectionMatrix"] else {
            return XCTFail("no g_ModelViewProjectionMatrix")
        }
        let registers: [[Float]] = [
            [-1.15e-8, 1.02761e-3, 0, -0.805596], [-5.55231e-3, -6.7e-9, 0, -0.199726],
            [0, 0, 2.5e-4, 0.5], [0, 0, 0, 1],
        ]
        for (register, expected) in registers.enumerated() {
            for component in 0 ..< 4 {
                XCTAssertEqual(packed.columns[register][component], expected[component], accuracy: 1e-5,
                               "c\(register).\(component)")
            }
        }
    }
}
