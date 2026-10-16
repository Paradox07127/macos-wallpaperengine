@testable import LiveWallpaperProWPE
import XCTest

/// Layers under plain group objects take the nearest scene-object ancestor as parent.
final class ParityProgramGroupParentTests: XCTestCase {
    private typealias D = ParitySceneDocuments

    func testGroupsAreSkippedWhenResolvingParents() throws {
        var compose = D.layer("1", width: 64, height: 64, json: ["copybackground": false])
        compose.model = ["material": "materials/genericimage2.json", "passthrough": true]
        let program = try D.programScene([
            compose, D.layer("3", json: ["parent": 2]), D.layer("5", json: ["parent": 4]),
            D.layer("7", json: ["parent": 6]),
        ], objects: [
            ["id": 2, "name": "g", "parent": 1],
            ["id": 4, "name": "loose"],
            ["id": 6, "name": "hair", "parent": 3, "attachment": "hand"],
        ])
        let parents = Dictionary(uniqueKeysWithValues: program.scene.objects.map { ($0.id, $0.parentID) })
        XCTAssertEqual(parents["3"], "1")
        XCTAssertEqual(parents["5"], .some(nil))
        XCTAssertEqual(parents["7"], "3")

        let frame = WPEParitySceneFrameBuilder.build(program.scene)
        XCTAssertEqual(frame.draws["3/albedo"]?.compositeOwnerID, "1")
        XCTAssertEqual(frame.draws["7/albedo"]?.compositeOwnerID, "1")
        XCTAssertEqual(frame.draws["5/albedo"]?.target, "backbuffer")
        XCTAssertNil(frame.draws["5/albedo"]?.compositeOwnerID)
    }
}
