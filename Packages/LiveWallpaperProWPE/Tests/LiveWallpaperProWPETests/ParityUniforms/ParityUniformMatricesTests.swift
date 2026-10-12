@testable import LiveWallpaperProWPE
import simd
import XCTest

final class ParityUniformMatricesTests: XCTestCase {
    private func assertEqual(_ lhs: simd_float4x4, _ rhs: simd_float4x4, accuracy: Float = 1e-4,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(simd_almost_equal_elements(lhs, rhs, accuracy), "\(lhs) != \(rhs)", file: file, line: line)
    }

    func testTransposedPackingPutsRowsInRegisters() {
        let matrix = simd_float4x4(rows: [
            SIMD4(1, 2, 3, 4), SIMD4(5, 6, 7, 8), SIMD4(9, 10, 11, 12), SIMD4(13, 14, 15, 16),
        ])
        guard case let .matrix(packed) = WPECBufferValue.wpeTransposed(matrix) else {
            return XCTFail("not a matrix")
        }
        XCTAssertEqual(packed.columns[0], [1, 2, 3, 4])
        XCTAssertEqual(packed.columns[3], [13, 14, 15, 16])
    }

    func testNormalMatrixNormalizesColumnsNotInverseTranspose() {
        let angle = Float.pi / 6
        let rotation = simd_float4x4(simd_quatf(angle: angle, axis: SIMD3(0, 0, 1)))
        let model = rotation * simd_float4x4(diagonal: SIMD4(2, 3, 4, 1))
        let matrices = WPEParityUniformMatrices(model: model, view: matrix_identity_float4x4,
                                                projection: matrix_identity_float4x4)
        let normal = matrices.normalModel
        let expected = simd_float3x3(simd_quatf(angle: angle, axis: SIMD3(0, 0, 1)))
        XCTAssertTrue(simd_almost_equal_elements(normal, expected, 2e-3), "\(normal)")
        let mat3 = simd_float3x3(SIMD3(model.columns.0.x, model.columns.0.y, model.columns.0.z),
                                 SIMD3(model.columns.1.x, model.columns.1.y, model.columns.1.z),
                                 SIMD3(model.columns.2.x, model.columns.2.y, model.columns.2.z))
        let inverseTranspose = mat3.inverse.transpose
        XCTAssertEqual(simd_length(inverseTranspose.columns.0), 0.5, accuracy: 1e-5)
        XCTAssertFalse(simd_almost_equal_elements(normal, inverseTranspose, 0.1))
    }

    func testEffectPassPlainMatricesUseOrtho() {
        let effect = WPEParityUniformMatrices.effectPass
        let ortho = simd_float4x4(diagonal: SIMD4(1, 1, -0.001, 1))
        assertEqual(effect.viewProjection, ortho)
        assertEqual(effect.modelViewProjection, ortho)
        assertEqual(effect.model, matrix_identity_float4x4)
        XCTAssertEqual(effect.values.count, 6)
    }

    func testEffectIntermediateVersusLastPass() {
        let layerModel = simd_float4x4(rows: [
            SIMD4(1, 0, 0, 100), SIMD4(0, 1, 0, 50), SIMD4(0, 0, 1, 0), SIMD4(0, 0, 0, 1),
        ])
        let layerMVP = simd_float4x4(diagonal: SIMD4(1.0 / 960, 1.0 / 540, -0.001, 1)) * layerModel
        let scale = simd_float4x4(diagonal: SIMD4(200, 100, 1, 1))
        var pass = WPEParityUniformEffectPass(layerModel: layerModel, layerModelViewProjection: layerMVP,
                                              size: SIMD2(400, 200), isLastPass: false)
        assertEqual(pass.effectModel, layerModel * scale)
        assertEqual(pass.effectModelViewProjection, layerMVP * scale)
        assertEqual(pass.effectTextureProjection, layerMVP * scale)
        pass.isLastPass = true
        assertEqual(pass.effectModel, layerModel)
        assertEqual(pass.effectModelViewProjection, layerMVP)
        assertEqual(pass.effectTextureProjection, layerMVP * scale)
        XCTAssertEqual(Set(pass.values.keys), [
            "g_EffectModelMatrix", "g_EffectModelViewProjectionMatrix", "g_EffectModelViewProjectionMatrixInverse",
            "g_EffectTextureProjectionMatrix", "g_EffectTextureProjectionMatrixInverse", "g_LayerModelMatrix",
        ])
        assertEqual(pass.effectModelViewProjection.inverse * pass.effectModelViewProjection, matrix_identity_float4x4)
    }
}
