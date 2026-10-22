import Foundation
@testable import LiveWallpaperProWPE
import simd
import XCTest

/// Workshop 3437487219: an orthographic scene with two `perspective` model objects, Earth (112, generic4) and its
/// cloud shell (114, chroma4), one sub-mesh each, under three lights and skylight 0.3.
final class ParityProgramModelTests: XCTestCase {
    private func loadScene() throws -> (WPESceneDocument, WPEParityProgramScene) {
        let package = try CorpusFixtures.workshopPackage("3437487219")
        guard FileManager.default.fileExists(atPath: package.path) else {
            throw CorpusFixtures.MissingInput("Workshop 3437487219 is not installed")
        }
        let wpeAssets = try CorpusFixtures.url("WPE_ASSETS_DIR")
        guard FileManager.default.fileExists(atPath: wpeAssets.appendingPathComponent("materials/util").path) else {
            throw CorpusFixtures.MissingInput("Set WPE_ASSETS_DIR to a WPE 2.8.42 assets directory (materials/util, shaders)")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("parity-model-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try ParityProgramPuppetTests.unpack(package, into: root)
        let document = try WPESceneDocumentParser.parse(data: Data(contentsOf: root.appendingPathComponent("scene.json")),
                                                        userValues: [:])
        let assets = WPEParityProgramAssets(sceneDirectory: root, assetRoots: [wpeAssets])
        return (document, WPEParityProgramScene(document: document, assets: assets, settings: WPEParityProgramSettings()))
    }

    func testModelObjectsDrawOneSubMeshEachInPaintOrder() throws {
        let (_, scene) = try loadScene()
        let frame = WPEParitySceneFrameBuilder.build(scene.scene)
        let modelPasses = frame.operations.compactMap { operation -> String? in
            guard case .draw = operation.kind, frame.draws[operation.pass]?.geometry == .modelMesh else { return nil }
            return operation.pass.rawValue
        }
        XCTAssertEqual(modelPasses, ["112/mesh0", "114/mesh0"])
        let earth = try XCTUnwrap(frame.draws["112/mesh0"])
        XCTAssertEqual(earth.shader, "generic4")
        XCTAssertEqual(earth.source?.materialPath, "materials/models/Earth/DefaultMaterial.json")
        XCTAssertEqual(earth.blend, .translucent)
        XCTAssertEqual(earth.target, WPEParitySceneResource.backbuffer)
        XCTAssertTrue(earth.depthTest)
        XCTAssertFalse(earth.depthWrite)
        XCTAssertTrue(earth.cullsBackFaces)
        // REFLECTION=0 leaves the mip-mapped frame buffer sampler undeclared. Default shadow quality 2 with a
        // shadow-casting spot makes the earth read the atlas (generic4.frag:21-26).
        XCTAssertEqual(earth.reads, ["_rt_shadowAtlas"])
        let clouds = try XCTUnwrap(frame.draws["114/mesh0"])
        XCTAssertEqual(clouds.shader, "chroma4")
        XCTAssertEqual(clouds.source?.materialPath, "materials/models/Cloud_Cover/DefaultMaterial.json")
        XCTAssertEqual(scene.models["112"]?.meshes.count, 1)
        XCTAssertNil(scene.layerColors["112"])
    }

    func testModelBindingSamplesItsMaterialTexturesWithWhiteColour() throws {
        let (_, scene) = try loadScene()
        let frame = try WPEParityFrameComposer.compose(scene: scene.scene, post: scene.postProcess)
        let index = try XCTUnwrap(frame.draws.first { _, draw in
            if case let .scene(draw) = draw {
                draw.pass == "112/mesh0"
            } else {
                false
            }
        }?.key)
        let binding = try XCTUnwrap(WPEParityProgramBuilder.bindings(frame: frame, scene: scene)[index])
        XCTAssertEqual(binding.textures[0], .asset("8k_earth_daymap copy 3"))
        XCTAssertNil(binding.layerColorObjectID)
        XCTAssertEqual(Self.components(binding.constants[.vertex]?["g_Color4"]), [1, 1, 1, 1])
    }

    func testLightUniformsCopyGeneralAmbientAndSkylight() throws {
        let (document, _) = try loadScene()
        let lights = WPEParityUniformLights(document: document)
        XCTAssertEqual(lights.ambient, SIMD3(0, 0, 0))
        XCTAssertEqual(lights.skylight, SIMD3(0.3, 0.3, 0.3))
        let values = WPEParityUniformSet.values(
            frame: WPEParityUniformFrame(clock: WPEParityClock(), daytime: 0,
                                         screen: WPEParityUniformScreen(clientWidth: 1, clientHeight: 1),
                                         pointer: WPEParityUniformPointer(), parallax: WPEParityUniformParallax(),
                                         eyePosition: .zero, view: matrix_identity_float4x4, lights: lights),
            draw: WPEParityUniformDraw(matrices: .effectPass)
        )
        XCTAssertEqual(Self.components(values["g_LightAmbientColor"]), [0, 0, 0])
        XCTAssertEqual(Self.components(values["g_LightSkylightColor"]), [0.3, 0.3, 0.3])
    }

    private static func components(_ value: WPECBufferValue?) -> [Float]? {
        guard case let .vector(components)? = value else { return nil }
        return components
    }
}
