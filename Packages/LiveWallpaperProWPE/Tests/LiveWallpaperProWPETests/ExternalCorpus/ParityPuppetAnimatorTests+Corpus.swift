import Foundation
@testable import LiveWallpaperProWPE
import simd
import XCTest

extension ParityPuppetAnimatorTests {
    func testWorkshop2370640409PuppetStaysFinite() throws {
        let url = try CorpusFixtures.workshopPackage("2370640409")
        guard let package = try? Data(contentsOf: url) else {
            throw CorpusFixtures.MissingInput("Workshop 2370640409 is not installed")
        }
        let files = try PackageEntries.entries(package)
        let sceneJSON = try XCTUnwrap(files["scene.json"].flatMap { String(bytes: $0, encoding: .utf8) })
        let document = try ParityCameraFixture.document(json: sceneJSON)
        let image = try XCTUnwrap(document.imageObjects.first { !$0.animationLayers.isEmpty })
        let modelJSON = try XCTUnwrap(JSONSerialization.jsonObject(
            with: XCTUnwrap(files[image.imageRelativePath])
        ) as? [String: Any])
        let puppetPath = try XCTUnwrap(modelJSON["puppet"] as? String)
        let model = try WPEMdlParser.parse(data: XCTUnwrap(files[puppetPath]))
        XCTAssertFalse(model.bones.isEmpty)
        var animator = WPEParityPuppetAnimator(model: model, layers: image.animationLayers)
        XCTAssertEqual(animator.layers.count, image.animationLayers.count)
        for _ in 0 ..< 60 {
            animator.advance(dt: 1.0 / 60)
        }
        XCTAssertEqual(animator.bones.count, model.bones.count * 3)
        XCTAssertTrue(animator.bones.allSatisfy { [$0.x, $0.y, $0.z, $0.w].allSatisfy(\.isFinite) })
        XCTAssertGreaterThan(animator.layers[0].time, 0)
    }
}
