@testable import LiveWallpaperProWPE
import XCTest

final class WPESceneParticleLocalTransformTests: XCTestCase {
    func testChildParticleKeepsItsOwnLocalTransform() throws {
        let document = try ParityCameraFixture.document(json: """
        {"camera": {"center": "0 0 0"}, "general": {"orthogonalprojection": {"width": 1920, "height": 1080}},
         "objects": [
          {"id": 1, "name": "group", "origin": "100 50 0"},
          {"id": 2, "name": "rain", "particle": "particles/rain.json", "parent": 1,
           "origin": "10 20 0", "scale": "3 3 1", "angles": "0 0 0.5"}
         ]}
        """)
        let particle = try XCTUnwrap(document.particleObjects.first)
        XCTAssertEqual(particle.parentObjectID, "1")
        XCTAssertEqual(particle.localOrigin, SIMD3(10, 20, 0))
        XCTAssertEqual(particle.localScale, SIMD3(3, 3, 1))
        XCTAssertEqual(particle.localAngles, SIMD3(0, 0, 0.5))
        // The parent-resolved origin is unchanged.
        XCTAssertEqual(particle.origin, SIMD3(110, 70, 0))
    }
}
