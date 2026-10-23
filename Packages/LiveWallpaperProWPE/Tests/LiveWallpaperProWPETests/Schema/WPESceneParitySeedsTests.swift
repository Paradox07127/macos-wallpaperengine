import Foundation
@testable import LiveWallpaperProWPE
import XCTest

final class WPESceneParitySeedsTests: XCTestCase {
    func testPrecacheMaterialsKeepOnlyMaterialsPrefixedStrings() throws {
        let general = try XCTUnwrap(WPESceneJSONValue(jsonValue: ["precache": [
            "materials/a.json", "models/b.json", 7, NSNull(), ["materials/nested.json"], "materialsx.json", "Materials/c.json",
        ]]))
        XCTAssertEqual(WPESceneParitySeeds(general: general, objects: []).precacheMaterials,
                       ["materials/a.json", "materialsx.json"])
        XCTAssertEqual(WPESceneParitySeeds(general: .object(["precache": .string("materials/a.json")]), objects: [])
            .precacheMaterials, [])
        XCTAssertEqual(WPESceneParitySeeds(general: .object([:]), objects: []).precacheMaterials, [])
    }

    func testObjectHeaderReadsStringPathAndEnvelopedSequentialQueueMode() {
        let objects: [WPESceneJSONValue] = [
            .object(["path": .string("camera.json"), "queuemode": .string("sequential")]),
            .object(["path": .number(3), "queuemode": .object(["value": .string("sequential")])]),
            .object(["queuemode": .string("random")]),
            .object([:]),
        ]
        let headers = WPESceneParitySeeds(general: .object([:]), objects: objects).objects
        XCTAssertEqual(headers.map(\.path), ["camera.json", nil, nil, nil])
        XCTAssertEqual(headers.map(\.sequentialQueue), [true, true, false, false])
    }
}
