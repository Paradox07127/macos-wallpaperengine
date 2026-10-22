import Foundation
@testable import LiveWallpaperProWPE
import XCTest

final class ParitySceneUniqueFBOWorkshopTests: XCTestCase {
    func testMotionBlurFBOsTakeWPEPoolNames() throws {
        let package = try CorpusFixtures.workshopPackage("3808922316")
        let wpeAssets = try CorpusFixtures.url("WPE_ASSETS_DIR")
        guard FileManager.default.fileExists(atPath: package.path),
              FileManager.default.fileExists(atPath: wpeAssets.appendingPathComponent("materials/util").path) else {
            throw CorpusFixtures.MissingInput("Workshop 3808922316 or the WPE assets are not installed")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("parity-unique-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try ParityProgramPuppetTests.unpack(package, into: root)
        let document = try WPESceneDocumentParser.parse(data: Data(contentsOf: root.appendingPathComponent("scene.json")),
                                                        userValues: [:])
        let scene = WPEParityProgramScene(document: document, assets: WPEParityProgramAssets(sceneDirectory: root,
                                                                                             assetRoots: [wpeAssets]),
                                          settings: WPEParityProgramSettings())
        let frame = WPEParitySceneFrameBuilder.build(scene.scene)
        let ids = Set(frame.resources.map(\.id.rawValue))
        var checked = 0
        for object in scene.scene.objects where object.visible {
            for effect in object.effects where effect.enabled {
                for fbo in effect.fbos where fbo.name.hasPrefix("_rt_FullCompoBuffer") && !fbo.shared {
                    let expected = fbo.unique ? "\(fbo.name)_\(effect.id)"
                        : object.fullscreen ? fbo.name : "\(fbo.name)_\(object.width)_\(object.height)_1"
                    XCTAssertEqual(fbo.unique, fbo.name == "_rt_FullCompoBuffer1", "\(object.id)/\(effect.id)")
                    XCTAssertTrue(ids.contains(expected), "\(object.id)/\(effect.id): \(expected)")
                    checked += 1
                }
            }
        }
        print("3808922316: \(checked) motion-blur FBOs, \(frame.draws.values.count(where: \.layerMatrices)) "
            + "last-segment quads with layer matrices")
        XCTAssertGreaterThan(checked, 0)
        // A raw scene keeps possible sampler reads; post owns the declaration after shader preparation.
        // Supply that preparation fact here without inferring activity from a source annotation.
        var post = scene.postProcess
        post.sceneMipMappedFrameBufferEnabled = true
        let composed = try WPEParityFrameComposer.compose(scene: scene.scene, post: post)
        XCTAssertTrue(composed.resources.contains { $0.id == "_rt_MipMappedFrameBuffer" })
        _ = try WPERenderGraphCompiler.compile(resources: composed.resources, operations: composed.operations)
    }
}
