import Foundation
@testable import LiveWallpaperProWPE
import XCTest

extension ParityProgramSettingsTests {
    func testLoadedMDLModelsUseOneSampleCountForCombosSceneAndPost() throws {
        let (document, assets) = try modelFixture()
        for requested in [1, 2, 4, 8, 3, 16] {
            let scene = WPEParityProgramScene(document: document, assets: assets,
                                              settings: .init(bloom: false, msaaSampleCount: requested,
                                                              colorCorrection: .init(wecE: true, wecBrs: 75)))
            XCTAssertEqual(scene.models["112"]?.meshes.count, 1, "fixture must load Earth's MDL")
            XCTAssertEqual(scene.models["114"]?.meshes.count, 1, "fixture must load the cloud MDL")
            let expected = [2, 4, 8].contains(requested) ? requested : 1
            try assertSampleRoute(scene, expected: expected)
        }
    }

    private func modelFixture() throws -> (WPESceneDocument, WPEParityProgramAssets) {
        let package = try CorpusFixtures.workshopPackage("3437487219")
        let engine = try CorpusFixtures.url("WPE_ASSETS_DIR")
        guard FileManager.default.fileExists(atPath: package.path),
              FileManager.default.fileExists(atPath: engine.appendingPathComponent("materials/util").path) else {
            throw CorpusFixtures.MissingInput("Needs Workshop 3437487219 and original WPE assets (WPE_ASSETS_DIR)")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("parity-settings-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try ParityProgramPuppetTests.unpack(package, into: root)
        let document = try WPESceneDocumentParser.parse(data: Data(contentsOf: root.appendingPathComponent("scene.json")),
                                                        userValues: [:])
        return (document, WPEParityProgramAssets(sceneDirectory: root, assetRoots: [engine]))
    }
}
