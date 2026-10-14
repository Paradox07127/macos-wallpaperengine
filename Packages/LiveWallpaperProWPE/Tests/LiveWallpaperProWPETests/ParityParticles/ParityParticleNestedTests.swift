import Foundation
@testable import LiveWallpaperProWPE
import simd
import XCTest

final class ParityParticleNestedTests: XCTestCase {
    /// Native 22ebe0/22f890 permit the root and ten descendants, including repeated resource paths.
    /// Exercise the public scene producer, actual simulation, prototype lookup and packed draw stream together.
    func testRepeatedStaticAndEventAssetsProduceEveryDepthThroughTen() throws {
        for event in [false, true] {
            let definition = """
            {"maxcount":1,"material":"materials/plain.json",
             "emitter":[{"name":"sphererandom","rate":0,"instantaneous":1,"distancemax":0}],
             "initializer":[{"name":"lifetimerandom","min":10,"max":10}],
             "children":[{"name":"particles/repeated.json"\(event ? ",\"type\":\"eventspawn\"" : "")}],
             "renderer":[{"name":"sprite"}]}
            """
            let files = [
                "particles/repeated.json": Data(definition.utf8),
                "materials/plain.json": Data(#"{"passes":[{"shader":"genericparticle"}]}"#.utf8),
            ]
            let assets = WPEParityProgramAssets(sources: [.lookup(URL(fileURLWithPath: "/")) { files[$0] }])
            let document = try WPESceneDocumentParser.parse(
                data: Data(#"{"camera":{"center":"0 0 0"},"general":{"orthogonalprojection":{"width":64,"height":64}},"objects":[{"id":5,"name":"fx","particle":"particles/repeated.json"}]}"#.utf8),
                userValues: [:], makeTransformScriptResolver: { _, _ in NoScripts() }
            )
            var diagnostics: [WPEParitySceneDiagnostic] = []
            let prototypes = WPEParityProgramScene.particleDraws(objectID: "5", path: "particles/repeated.json",
                                                                 assets: assets, diagnostics: &diagnostics)
            let element: WPEParityParticlePathElement = event ? .eventGroup(0) : .staticChild(0)
            let expected = (0 ... 10).map { Array(repeating: element, count: $0) }
            XCTAssertEqual(prototypes.map(\.key.path), expected)

            var scene = WPEParityParticleScene(document: document, assets: assets,
                                               engineFlags: WPEEngineComboFlags(), seed: 7)
            scene.advance(dt: 0.1, frames: ["5": .init()])
            XCTAssertEqual(scene.liveCount("5"), 11)
            let batches = scene.drawBatches(for: "5")
            XCTAssertEqual(batches.map(\.key.path), expected)
            for batch in batches {
                let prototype = try XCTUnwrap(WPEParityParticleScene.prototype(for: batch.key,
                                                                               document: document, assets: assets))
                XCTAssertEqual(prototype.slotCount, 1)
                XCTAssertEqual(batch.vertices.count, 1)
                XCTAssertEqual(ParityParticleTestSupport.floats(batch.vertices.bytes, at: 0, count: 3), [0, 0, 0])
            }
            let beyond = WPEParityParticleDrawKey(objectID: "5", path: expected[10] + [element], renderer: 0)
            XCTAssertNil(WPEParityParticleScene.prototype(for: beyond, document: document, assets: assets))
        }
    }
}
