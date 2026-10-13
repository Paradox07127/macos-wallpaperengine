@testable import LiveWallpaperProWPE
import simd
import XCTest

final class ParityLightsTests: XCTestCase {
    /// 3470948192's two directional lights under the `sd` model (14) and group 55, as authored.
    private static let scene = """
    {"camera": {"center": "0.32276 -0.01105 -0.52150", "eye": "-0.05628 0.03727 0.40262", "up": "0 1 0"},
     "general": {"orthogonalprojection": null, "fov": 50, "nearz": 0.1, "farz": 10000,
                 "ambientcolor": "1 1 1", "skylightcolor": "1 1 1", "lightconfig": {"directional": 2}},
     "objects": [
      {"id": 55, "name": "", "origin": "0.01 0 0", "angles": "0 0 0"},
      {"id": 14, "name": "sd", "model": "models/sd/sd.mdl", "parent": 55, "origin": "0.02 0 0",
       "angles": "3.14159 -1.57079 3.14159", "scale": "0.05 0.05 0.05"},
      {"id": 174, "light": "ldirectional", "parent": 14, "color": "1.00000 0.92549 0.89412", "intensity": 9.8400002,
       "radius": 50, "origin": "-6.95465 -5.95795 48.54903", "angles": "3.06187 1.30289 3.09024",
       "scale": "7.04461 9.99722 9.00063"},
      {"id": 75, "light": "ldirectional", "parent": 14, "color": "1.00000 0.91765 0.87059", "intensity": 8.9499998,
       "radius": 1.93, "origin": "-12.84633 -10.12890 140.86674", "angles": "0.01006 1.19415 -0.01802",
       "scale": "6.93225 9.99991 9.24864"}
     ]}
    """

    private func assertEqual(_ lhs: [SIMD4<Float>], _ rhs: [SIMD4<Float>], file: StaticString = #filePath,
                             line: UInt = #line) {
        XCTAssertEqual(lhs.count, rhs.count, file: file, line: line)
        for (left, right) in zip(lhs, rhs) {
            XCTAssertLessThan(simd_reduce_max(simd_abs(left - right)), 1e-4, "\(left) != \(right)", file: file,
                              line: line)
        }
    }

    func testDirectionalLightsOf3470948192() throws {
        let document = try ParityCameraFixture.document(json: Self.scene)
        let transforms = WPEParityLayerTransformSet(document: document, renderTargetSize: SIMD2(1920, 1080))
        let lights = WPEParityUniformLights(document: document, transforms: transforms)
        assertEqual(lights.directionalColor, [SIMD4(9.84, 9.10682, 8.79814, 1), SIMD4(8.95, 8.21297, 7.79178, 1)])
        assertEqual(lights.directionalDirection.map { SIMD4($0, 0) }, [
            SIMD4(-0.33966608, -0.00478421, 0.09311494, 0), SIMD4(-0.32231531, 0.00229887, -0.12746679, 0),
        ])
        XCTAssertNotNil(lights.values["g_LDirectional_Direction"])
        XCTAssertNil(lights.values["g_LPoint_Color"])
    }

    func testLightConfigCountsAndMasks() throws {
        let general = try ParityCameraFixture.document(json: """
        {"camera": {"center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"},
         "general": {"lightconfig": {"directional": 1, "directionalshadow": 1, "point": 17, "spotshadowcookie": 2,
                                     "spotcookie": 1}}, "objects": []}
        """).sourceJSON["general"]
        let config = WPEParityLightConfig(general: general)
        XCTAssertEqual([config.point, config.directional, config.spotCookie, config.directionalShadow], [1, 1, 3, 0])
        var flags = WPEEngineComboFlags()
        config.apply(to: &flags)
        XCTAssertEqual(flags.directionalLights, 1)
        XCTAssertEqual(WPEParityLightConfig(general: general, shadowQuality: 1).directionalShadow, 1)
    }
}
