import Foundation
@testable import LiveWallpaperProWPE
import XCTest

extension ParityProgramPuppetTests {
    func testRealPuppetSceneBuildsSkinnedPrograms() throws {
        let package = try CorpusFixtures.workshopPackage("2370640409")
        guard FileManager.default.fileExists(atPath: package.path) else {
            throw CorpusFixtures.MissingInput("Workshop 2370640409 is not installed")
        }
        let wpeAssets = try CorpusFixtures.url("WPE_ASSETS_DIR")
        guard FileManager.default.fileExists(atPath: wpeAssets.appendingPathComponent("materials/util").path) else {
            throw CorpusFixtures.MissingInput("Set WPE_ASSETS_DIR to a WPE 2.8.42 assets directory (materials/util, shaders)")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("parity-puppet-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.unpack(package, into: root)
        let document = try WPESceneDocumentParser.parse(data: Data(contentsOf: root.appendingPathComponent("scene.json")),
                                                        userValues: [:])
        let assets = WPEParityProgramAssets(sceneDirectory: root, assetRoots: [wpeAssets])
        let scene = WPEParityProgramScene(document: document, assets: assets, settings: WPEParityProgramSettings())

        let puppets = scene.scene.objects.filter { $0.puppet != nil }
        for object in puppets {
            let puppet = try XCTUnwrap(object.puppet)
            print("puppet layer \(object.id): \(puppet.vertices.count) vertices, \(puppet.indices.count) indices, "
                + "\(puppet.boneCount) bones, skinned \(puppet.skinned), bit4 \(object.puppetForcesComposite)")
            XCTAssertFalse(puppet.vertices.isEmpty, object.id)
            XCTAssertFalse(puppet.indices.isEmpty, object.id)
            XCTAssertGreaterThan(puppet.boneCount, 0, object.id)
            XCTAssertTrue(puppet.skinned, object.id)
            XCTAssertEqual(object.kind, .image, object.id)
        }
        XCTAssertEqual(puppets.map(\.id).sorted(), ["43", "47", "51"])
        XCTAssertEqual(puppets.filter(\.puppetForcesComposite).map(\.id).sorted(), ["47", "51"])

        let frame = try WPEParityFrameComposer.compose(scene: scene.scene, post: scene.postProcess)
        let puppetDraws = frame.draws.compactMap { index, draw -> (Int, WPEParitySceneDraw)? in
            guard case let .scene(draw) = draw, draw.geometry == .puppetMesh else { return nil }
            return (index, draw)
        }
        XCTAssertEqual(Set(puppetDraws.map(\.1.pass.rawValue)),
                       ["43/albedo", "47/passthrough4", "51/passthrough4"])
        for (_, draw) in puppetDraws {
            let description = try XCTUnwrap(WPEParityProgramBuilder.description(of: .scene(draw), scene: scene),
                                            draw.pass.rawValue)
            let program = try WPEParityProgramResolver.resolve(description, sources: assets)
            XCTAssertTrue(program.combos.contains { $0.name == "SKINNING" && $0.value == "1" }, draw.pass.rawValue)
            let vertex = String(bytes: program.hlsl.vertex ?? [], encoding: .isoLatin1)
            XCTAssertEqual(vertex?.contains("g_Bones["), true, draw.pass.rawValue)
        }
    }

    func testRealClipGroupScenesDrawMasksAndClippedSegments() throws {
        var checked = 0
        for id in ["3704273480", "3808922316"] {
            let scene = try Self.workshopScene(id)
            let clipped = scene.scene.objects.filter { !($0.puppet?.clipOperations.isEmpty ?? true) }
            let frame = try WPEParityFrameComposer.compose(scene: scene.scene, post: scene.postProcess)
            let draws = frame.draws.values.compactMap { draw -> WPEParitySceneDraw? in
                if case let .scene(draw) = draw {
                    draw
                } else {
                    nil
                }
            }
            for object in clipped {
                let puppet = try XCTUnwrap(object.puppet)
                let own = draws.filter { $0.objectID == object.id }
                let masks = own.filter { $0.target == WPEParitySceneResource.fullAlphaMask && !$0.multipliesDestination }
                let targets = own.filter { $0.source?.combos["CLIPPINGTARGET"] == 1 }
                print("\(id) puppet \(object.id): \(puppet.clipGroups.count) groups, "
                    + "\(puppet.clipOperations.count) ops, \(masks.count) masks, \(targets.count) clipped draws, "
                    + "bit4 \(object.requiresLayerComposite), effects \(object.effects.count(where: \.enabled)), "
                    + "visible \(object.visible)")
                guard object.visible else { continue }
                let clips = puppet.clipOperations.count {
                    if case .clip = $0 {
                        true
                    } else {
                        false
                    }
                }
                XCTAssertEqual(targets.count, clips, object.id)
                XCTAssertGreaterThanOrEqual(masks.count, clips, object.id)
                for mask in masks {
                    XCTAssertEqual(mask.source?.materialPath, "materials/util/clippingmaskimage4.json")
                    XCTAssertNotNil(mask.source?.textures[1])
                }
                for target in targets {
                    XCTAssertEqual(target.source?.textures[8], "_rt_FullAlphaMask")
                    XCTAssertTrue(target.reads.contains(WPEParitySceneResource.fullAlphaMask))
                }
                XCTAssertNil(own.first { $0.geometry == .puppetMesh }, object.id)
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 0, "corpus must contain visible clipped puppets")
    }

    private static func workshopScene(_ id: String) throws -> WPEParityProgramScene {
        let package = try CorpusFixtures.workshopPackage(id)
        let wpeAssets = try CorpusFixtures.url("WPE_ASSETS_DIR")
        guard FileManager.default.fileExists(atPath: package.path),
              FileManager.default.fileExists(atPath: wpeAssets.appendingPathComponent("materials/util").path)
        else { throw CorpusFixtures.MissingInput("Missing WPE materials/util") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("parity-clip-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try unpack(package, into: root)
        let document = try WPESceneDocumentParser.parse(data: Data(contentsOf: root.appendingPathComponent("scene.json")),
                                                        userValues: [:])
        let assets = WPEParityProgramAssets(sceneDirectory: root, assetRoots: [wpeAssets])
        return WPEParityProgramScene(document: document, assets: assets, settings: WPEParityProgramSettings())
    }
}
