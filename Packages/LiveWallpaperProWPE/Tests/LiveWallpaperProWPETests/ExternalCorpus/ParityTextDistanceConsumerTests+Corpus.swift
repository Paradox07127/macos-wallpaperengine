import CryptoKit
import Foundation
@testable import LiveWallpaperProWPE
import XCTest

extension ParityTextDistanceConsumerTests {
    func testOriginalHFieldFlowsThroughExistingPlannerAtlasAndQuad() throws {
        let oracle = try oracle(environment: "LOOMSCREEN_WPE_GLYPH_ORACLE_DIR",
                                manifestSHA: "ac47bffbf998d8ac6fb3bec69f2564b6f7578bb13509ffc575a759746a50da1f")
        let planner = WPEParityTextPlanner(assets: WPEParityProgramAssets(sources: [.directory(oracle)]))
        let object = text()
        let bitmap = try XCTUnwrap(planner.layout(object, effectCount: 0).mesh)
        let prepared = try planner.plan(object, effectCount: 0, glyphMode: .distanceField)
        let mesh = try XCTUnwrap(prepared.layout.mesh)
        XCTAssertEqual(mesh.glyphMode, .distanceField)
        XCTAssertEqual(prepared.atlasKey, "NotoSans-Regular.ttf_msdf")
        let instance = try XCTUnwrap(planner.atlases[prepared.atlasKey])
        XCTAssertEqual(instance.mono.format, .rgba8)
        XCTAssertTrue(instance.colorGroups.isEmpty)
        let entry = try XCTUnwrap(instance.mono.entry(forKey: 43))
        XCTAssertEqual([entry.x0, entry.y0, entry.x1, entry.y1], [0, 0, 42, 47])
        XCTAssertEqual(entry.references, 1)
        var cell = Data()
        for y in entry.y0 ..< entry.y1 {
            let start = (y * instance.mono.width + entry.x0) * 4
            cell.append(contentsOf: instance.mono.pixels[start ..< start + 42 * 4])
        }
        XCTAssertEqual(cell, try Data(contentsOf: oracle.appendingPathComponent("rgba-cell.bin")))
        XCTAssertEqual([mesh.minX, mesh.maxX, mesh.top, mesh.bottom, mesh.lineHeight],
                       [bitmap.minX, bitmap.maxX, bitmap.top, bitmap.bottom, bitmap.lineHeight])
        XCTAssertEqual(prepared.layout.fboSize, try planner.layout(object, effectCount: 0).fboSize)
        XCTAssertEqual(prepared.layout.blockOffset, try planner.layout(object, effectCount: 0).blockOffset)
        let vertices = mesh.mono.vertices, ordinary = bitmap.mono.vertices
        XCTAssertEqual(vertices.count, 4)
        // Actual original y_ppem33: vertex-only gutter33*12/32=12.375, not the24px logical cell extent.
        XCTAssertEqual(vertices[0].x, ordinary[0].x - 12.375)
        XCTAssertEqual(vertices[0].y, ordinary[0].y + 12.375)
        XCTAssertEqual(vertices[3].x, ordinary[3].x + 12.375)
        XCTAssertEqual(vertices[3].y, ordinary[3].y - 12.375)
        XCTAssertEqual(vertices.map { SIMD2($0.u, $0.v) },
                       [SIMD2(0, 0), SIMD2(42.0 / 512, 0), SIMD2(0, 47.0 / 512), SIMD2(42.0 / 512, 47.0 / 512)])
    }

    private func oracle(environment: String, manifestSHA: String) throws -> URL {
        guard let path = ProcessInfo.processInfo.environment[environment] else {
            throw CorpusFixtures.MissingInput("Set \(environment) to the pinned original oracle directory")
        }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let manifest = try Data(contentsOf: root.appendingPathComponent("manifest.json"))
        XCTAssertEqual(sha(manifest), manifestSHA)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: manifest) as? [String: Any])
        let files = try XCTUnwrap(json["files"] as? [[String: Any]])
        for file in files {
            let name = try XCTUnwrap(file["path"] as? String)
            let data = try Data(contentsOf: root.appendingPathComponent(name))
            XCTAssertEqual(data.count, file["bytes"] as? Int)
            XCTAssertEqual(sha(data), file["sha256"] as? String)
        }
        return root
    }

    private func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
