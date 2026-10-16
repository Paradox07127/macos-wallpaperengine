@testable import LiveWallpaperProWPE
import simd
import XCTest

final class ParityShadowLayoutTests: XCTestCase {
    private static let radiansPerDegree: Float = 0.017453292

    private func layout(_ json: String, quality: Int32, orthographic: Bool) throws -> WPEParityShadowLayout {
        let document = try ParityCameraFixture.document(json: json)
        let transforms = WPEParityLayerTransformSet(document: document, renderTargetSize: SIMD2(64, 64))
        let state = WPEParitySceneState(document: document, hdr: false)
        return WPEParityShadowLayout(document: document, transforms: transforms, state: state, quality: quality,
                                     eye: .zero, forward: SIMD3(0, 0, -1), orthographic: orthographic)
    }

    private func assertClose(_ lhs: simd_float4x4, _ rhs: simd_float4x4, file: StaticString = #filePath,
                             line: UInt = #line) {
        for column in 0 ..< 4 {
            XCTAssertLessThan(simd_reduce_max(simd_abs(lhs[column] - rhs[column])), 1e-5,
                              "column \(column): \(lhs[column]) != \(rhs[column])", file: file, line: line)
        }
    }

    func testOrthographicSpotFillsOneAtlasCell() throws {
        let shadows = try layout("""
        {"camera":{"eye":"0 0 0","center":"0 0 -1","up":"0 1 0"},
         "general":{"orthogonalprojection":{"width":64,"height":64},"lightconfig":{"spot":1,"spotshadow":1}},
         "objects":[{"id":1,"light":"lspot","origin":"0 0 100","outercone":30,"radius":200,"castshadow":true}]}
        """, quality: 2, orthographic: true)
        XCTAssertEqual(shadows.atlasSize, SIMD2(256, 256))
        XCTAssertEqual(shadows.entries.count, 1)
        let entry = try XCTUnwrap(shadows.entries.first)
        XCTAssertEqual(entry.rect, SIMD4(0, 0, 1, 1))
        XCTAssertEqual(entry.draws.map(\.viewport), [.init(x: 0, y: 0, width: 256, height: 256)])
        assertClose(entry.projection, WPEParityCamera.perspective(fovY: 60 * Self.radiansPerDegree, aspect: 1,
                                                                  near: 1, far: 200))
        let biased = try XCTUnwrap(shadows.batches.first?.first?.viewProjection)
        XCTAssertEqual(biased.columns.3.z, entry.viewProjection.columns.3.z - 0.0005)
        XCTAssertEqual(shadows.projections, [entry.viewProjection])
        XCTAssertEqual(shadows.projectionTransforms, [SIMD4(0, 0, 1, 1)])

        // CalculateProjectedCoords (common_pbr_2.h:118-129) on a point along the spot axis W·(1, 0, 0).
        let projected = entry.viewProjection * SIMD4<Float>(50, 0, 100, 1)
        let ndc = SIMD2(projected.x, projected.y) / projected.w
        XCTAssertEqual(ndc.x * 0.5 + 0.5, 0.5, accuracy: 1e-5)
        XCTAssertEqual(ndc.y * -0.5 + 0.5, 0.5, accuracy: 1e-5)
        XCTAssertGreaterThan(projected.w, 0)
    }

    func testPointLightFovByQualityAndSixFaceViewports() throws {
        let json = """
        {"camera":{"eye":"0 0 0","center":"0 0 -1","up":"0 1 0"},
         "general":{"lightconfig":{"point":1,"pointshadow":1}},
         "objects":[{"id":1,"light":"lpoint","origin":"5 6 7","radius":100,"lightsourcesize":0.5,
                     "castshadow":true}]}
        """
        for (quality, fov) in [(Int32(2), Float(94)), (3, 92), (4, 91.2)] {
            let entry = try XCTUnwrap(layout(json, quality: quality, orthographic: false).entries.first)
            assertClose(entry.projection, WPEParityCamera.perspective(fovY: fov * Self.radiansPerDegree, aspect: 1,
                                                                      near: 0.5, far: 100))
        }
        let shadows = try layout(json, quality: 2, orthographic: false)
        let entry = try XCTUnwrap(shadows.entries.first)
        XCTAssertTrue(entry.isPoint)
        XCTAssertEqual(shadows.atlasSize, SIMD2(256, 256))
        XCTAssertEqual(entry.draws.map(\.viewport), [(0, 0), (128, 0), (0, 85), (128, 85), (0, 170), (128, 170)].map {
            WPEParityShadowLayout.Viewport(x: $0.0, y: $0.1, width: 128, height: 85)
        })
        XCTAssertEqual(shadows.batches.count, 1)
        let projection = entry.projection
        XCTAssertEqual(shadows.pointProjections, [SIMD4(projection.columns.2.z, projection.columns.3.z,
                                                        projection.columns.2.w, projection.columns.3.w)])
        XCTAssertEqual(shadows.pointProjectionTransforms, [SIMD4(0, 0, 1, 1)])
        // Face order of CalculateProjectedCoordsPoint (common_pbr_2.h:167-235): +x, -x, +y, -y, +z, -z.
        let directions: [SIMD3<Float>] = [SIMD3(1, 0, 0), SIMD3(-1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, -1, 0),
                                          SIMD3(0, 0, 1), SIMD3(0, 0, -1)]
        for (draw, direction) in zip(entry.draws, directions) {
            let projected = draw.viewProjection * SIMD4(SIMD3<Float>(5, 6, 7) + direction * 10, 1)
            XCTAssertGreaterThan(projected.w, 0, "\(direction)")
            XCTAssertEqual(projected.x / projected.w, 0, accuracy: 1e-5, "\(direction)")
            XCTAssertEqual(projected.y / projected.w, 0, accuracy: 1e-5, "\(direction)")
        }
    }

    func testDirectionalCascadesPackSideBySide() throws {
        let shadows = try layout("""
        {"camera":{"eye":"0 0 0","center":"0 0 -1","up":"0 1 0"},
         "general":{"lightconfig":{"directional":1,"directionalshadow":1}},
         "objects":[{"id":259,"light":"ldirectional","castshadow":true,"cascadedistance0":0.3,
                     "cascadedistance1":0.4,"cascadedistance2":8}]}
        """, quality: 2, orthographic: false)
        XCTAssertEqual(shadows.entries.count, 3)
        XCTAssertEqual(shadows.atlasSize, SIMD2(768, 256))
        XCTAssertEqual(shadows.entries.map(\.origin), [SIMD2(0, 0), SIMD2(256, 0), SIMD2(512, 0)])
        XCTAssertEqual(shadows.entries.map(\.slot), [0, 1, 2])
        XCTAssertEqual(shadows.projectionTransforms.map(\.x), [0, 1.0 / 3, 2.0 / 3])
        assertClose(shadows.entries[2].projection,
                    WPEParityCamera.ortho(left: -4, right: 4, bottom: -4, top: 4, near: -6, far: 6))
    }

    func testQualitySettingStrings() {
        let cases: [(String?, Int32)] = [(nil, 2), ("disabled", 0), ("low", 1), ("medium", 2), ("high", 3),
                                         ("ultra", 4), ("x", 2)]
        for (setting, level) in cases {
            XCTAssertEqual(WPEParityShadowQuality.level(setting), level, "\(String(describing: setting))")
        }
    }
}
