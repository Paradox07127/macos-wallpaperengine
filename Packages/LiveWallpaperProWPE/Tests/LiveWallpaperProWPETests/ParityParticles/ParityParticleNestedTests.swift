import Foundation
@testable import LiveWallpaperProWPE
import simd
import XCTest

final class ParityParticleNestedTests: XCTestCase {
    /// Original collisionbox case 0x17 is a no-op. Treating it as an unknown component incorrectly drops a
    /// follow child's complete simulation and draw stream, even though its native collision record does nothing.
    func testNativeCollisionBoxNoOpAdmitsTheActualFollowChild() throws {
        let parent = ParityParticleTestSupport.json(#"{"maxcount":1,"emitter":[{"name":"boxrandom","rate":0,"instantaneous":1,"distancemin":"1 1 1","distancemax":"1 1 1"}],"initializer":[{"name":"lifetimerandom","min":10,"max":10}],"renderer":[],"children":[{"name":"child","type":"eventfollow"}]}"#)
        func system(box: Bool) -> WPEParityParticleSystem {
            let child = ParityParticleTestSupport.json("""
            {"maxcount":1,"emitter":[{"name":"boxrandom","rate":0,"instantaneous":1,
              "distancemin":"1 1 1","distancemax":"1 1 1"}],
             "initializer":[{"name":"lifetimerandom","min":10,"max":10}],
             "operator":[\(box ? "{\"name\":\"collisionbox\",\"collisionbehavior\":\"delete\",\"flags\":3}" : "")],
             "renderer":[{"name":"sprite"}]}
            """)
            return WPEParityParticleSystem(json: parent, rng: WPEParityMT19937(seed: 7),
                                           resolveChild: { $0 == "child" ? child : nil })
        }
        var ordinary = system(box: false), box = system(box: true)
        ordinary.advance(dt: 0.01)
        box.advance(dt: 0.01)
        let expected = try XCTUnwrap(ordinary.drawBatches(objectID: "5").first)
        let actual = try XCTUnwrap(box.drawBatches(objectID: "5").first)
        XCTAssertEqual(actual.key.path, [.eventGroup(0)])
        XCTAssertEqual(actual.vertices.count, 1)
        XCTAssertEqual(actual.vertices.bytes, expected.vertices.bytes)
        XCTAssertEqual(box.eventChildren[0].first?.liveCount, 1)
        XCTAssertEqual(box.rng.next(), ordinary.rng.next())
        XCTAssertTrue(box.config.unsupportedChildren.isEmpty)
    }

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
                userValues: [:], makeTransformScriptResolver: { _, _ in ParityParticleTestSupport.NoScripts() }
            )
            var diagnostics: [WPEParitySceneDiagnostic] = []
            let prototypes = WPEParityProgramScene.particleDraws(objectID: "5", path: "particles/repeated.json",
                                                                 assets: assets, diagnostics: &diagnostics)
            let element: WPEParityParticlePathElement = event ? .eventGroup(0) : .staticChild(0)
            let expected = (0 ... 10).map { Array(repeating: element, count: $0) }
            XCTAssertEqual(prototypes.map(\.key.path), expected)

            var scene = WPEParityParticleScene(document: document, assets: assets,
                                               engineFlags: WPEEngineComboFlags(), seed: 7)
            scene.advance(dt: 0.1, frames: ["5": WPEParityParticleFrameContext()])
            XCTAssertEqual(scene.liveCount("5"), 11)
            let batches: [WPEParityParticleDrawBatch] = scene.drawBatches(for: "5")
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
