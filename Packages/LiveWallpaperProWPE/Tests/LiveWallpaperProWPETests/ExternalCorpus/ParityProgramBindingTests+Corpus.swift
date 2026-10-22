import Foundation
import LiveWallpaperCore
@testable import LiveWallpaperProWPE
import XCTest

extension ParityProgramBindingTests {
    func testRealSceneEffectPassBindsSceneConstantsAndTextures() throws {
        guard let directory = ProcessInfo.processInfo.environment["WPE_HLSL_CAPTURE_DIR"], !directory.isEmpty else {
            throw CorpusFixtures.MissingInput("Set WPE_HLSL_CAPTURE_DIR to the capture directory containing scene-sources/")
        }
        let wpeAssets = try CorpusFixtures.url("WPE_ASSETS_DIR")
        guard FileManager.default.fileExists(atPath: wpeAssets.appendingPathComponent("materials/util").path) else {
            throw CorpusFixtures.MissingInput("Set WPE_ASSETS_DIR to a WPE 2.8.42 assets directory (materials/util)")
        }
        let fixture = try ParityProgramCaptureFixture(root: URL(fileURLWithPath: directory), wpeAssets: wpeAssets)
        let assets = WPEParityProgramAssets(
            sceneDirectory: fixture.root.appendingPathComponent("scene-sources/3815666789"),
            assetRoots: fixture.assetRoots
        )
        let scene = try WPEParityProgramScene(document: fixture.document("3815666789"), assets: assets,
                                              settings: ParityProgramCaptureFixture.captureSettings)
        let frame = try WPEParityFrameComposer.compose(scene: scene.scene, post: scene.postProcess)
        let bindings = WPEParityProgramBuilder.bindings(frame: frame, scene: scene)
        func sceneDraw(_ shader: String) throws -> (WPEParitySceneDraw, WPEParityProgramBinding) {
            let draws = frame.draws.compactMap { index, draw -> (Int, WPEParitySceneDraw)? in
                guard case let .scene(draw) = draw, draw.shader == shader else { return nil }
                return (index, draw)
            }
            let (index, draw) = try XCTUnwrap(draws.first, shader)
            return try (draw, XCTUnwrap(bindings[index]))
        }

        let (foliage, binding) = try sceneDraw("effects/foliagesway")
        let expected: [String: [Float]] = [
            "g_Strength": [0.4], "g_Phase": [0.5], "g_Power": [1], "g_DirectionWeights": [1, 0.2],
            "g_CornerWeights": [1, 1, 0, 0], "g_Bounds": [0, 1], "g_NoiseScale": [0.05], "g_Ratio": [0.3],
            "g_Direction": [0], "g_Color4": [1, 1, 1, 1], "g_Alpha": [1],
        ]
        let vertex = binding.constants[.vertex] ?? [:], fragment = binding.constants[.fragment] ?? [:]
        for (name, value) in expected {
            XCTAssertEqual(Self.floats(fragment[name] ?? vertex[name]), value, name)
        }
        // The vertex stage reads `speed` (default 1), the fragment stage `speeduv` (scene 5).
        XCTAssertEqual(Self.floats(vertex["g_Speed"]), [1])
        XCTAssertEqual(Self.floats(fragment["g_Speed"]), [5])
        XCTAssertEqual(binding.textures, [0: .resource(foliage.reads[0]),
                                          1: .asset("masks/foliagesway_mask_74f285a7"), 2: .asset("util/noise")])
        XCTAssertFalse(binding.cullsBackFaces)

        let (ripple, rippleBinding) = try sceneDraw("effects/waterripple")
        XCTAssertEqual(rippleBinding.textures, [0: .resource(ripple.reads[0]),
                                                1: .asset("masks/waterripple_mask_886131ae"),
                                                2: .asset("effects/waterripplenormal")])
        XCTAssertEqual(Self.floats(rippleBinding.constants[.vertex]?["g_AnimationSpeed"]), [0.11])
        XCTAssertEqual(Self.floats(rippleBinding.constants[.fragment]?["g_SpecularColor"]), [1, 1, 1])

        let (albedo, albedoBinding) = try sceneDraw("genericimage4")
        XCTAssertEqual(albedoBinding.textures[0],
                       .imported(albedo.reads[0], asset: "AF3DD4AEF955193C9E71595ACC80BF57"))
    }
}
