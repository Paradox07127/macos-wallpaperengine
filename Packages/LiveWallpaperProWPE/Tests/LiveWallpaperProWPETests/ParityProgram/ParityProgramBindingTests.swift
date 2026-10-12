import Foundation
@testable import LiveWallpaperProWPE
import XCTest

final class ParityProgramBindingTests: XCTestCase {
    private static func floats(_ value: WPECBufferValue?) -> [Float]? {
        switch value {
        case let .float(number)?: [number]
        case let .vector(vector)?: vector
        default: nil
        }
    }

    func testAnnotationDefaultsFillOnlyKeysTheMaterialLacks() {
        let uniforms = WPEParityProgramConstants.uniforms(vertex: """
        uniform mat4 g_ModelViewProjectionMatrix;
        uniform float g_Speed; // {"material":"speed","default":1}
        \tuniform vec2 g_Bounds; // {"material":"bounds","default":"0 1"}
        uniform vec4 g_Tint; // {"material":"tint","type":"color","default":"1 0.5 0.25"}
        """, fragment: """
        uniform float g_Speed; // {"material":"speeduv","default":5}
        uniform float g_Ratio; // {"material":"ratio","default":0.3}
        uniform vec3 g_NoDefault; // {"material":"nodefault"}
        uniform float g_Engine;
        uniform sampler2D g_Texture0; // {"default":"util/noise"}
        """)
        XCTAssertEqual(Set(uniforms.keys), ["g_Speed", "g_Bounds", "g_Tint", "g_Ratio", "g_NoDefault"])
        XCTAssertEqual(uniforms["g_Speed"]?.material, "speeduv")

        let constants = WPEParityProgramConstants.resolve(uniforms, values: ["ratio": [0.7], "bounds": [0.2, 0.8]])
        XCTAssertEqual(Self.floats(constants["g_Speed"]), [5])
        XCTAssertEqual(Self.floats(constants["g_Ratio"]), [0.7])
        XCTAssertEqual(Self.floats(constants["g_Bounds"]), [0.2, 0.8])
        // A colour default with fewer numbers than the vector pads with zero.
        XCTAssertEqual(Self.floats(constants["g_Tint"]), [1, 0.5, 0.25, 0])
        XCTAssertNil(constants["g_NoDefault"])
    }

    func testConstantShapesReadAsComponents() {
        XCTAssertEqual(WPEParityProgramConstants.components(WPESceneJSONValue.string("0.05, 0.00")), [0.05, 0])
        XCTAssertEqual(WPEParityProgramConstants.components(WPESceneJSONValue.array([.number(1), .number(2)])), [1, 2])
        XCTAssertEqual(WPEParityProgramConstants.components(WPESceneJSONValue.object(["value": .number(3)])), [3])
        XCTAssertEqual(WPEParityProgramConstants.components(WPESceneJSONValue.bool(true)), [1])
        XCTAssertEqual(WPEParityProgramConstants.components(WPESceneShaderConstantValue.string("1 1 1")), [1, 1, 1])
        XCTAssertEqual(WPEParityProgramConstants.components(WPESceneShaderConstantValue.vector([0, 0.58])), [0, 0.58])
        XCTAssertNil(WPEParityProgramConstants.components(WPESceneShaderConstantValue.string("util/noise")))
    }

    /// Scene 3815666789's foliagesway pass: every material uniform gets the scene value or its default.
    func testRealSceneEffectPassBindsSceneConstantsAndTextures() throws {
        guard let directory = ProcessInfo.processInfo.environment["WPE_HLSL_CAPTURE_DIR"], !directory.isEmpty else {
            throw XCTSkip("Set WPE_HLSL_CAPTURE_DIR to the capture directory containing scene-sources/")
        }
        let install = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Steam/steamapps/common/wallpaper_engine/assets")
        let wpeAssets = ProcessInfo.processInfo.environment["WPE_ASSETS_DIR"].map { URL(fileURLWithPath: $0) } ?? install
        guard FileManager.default.fileExists(atPath: wpeAssets.appendingPathComponent("materials/util").path) else {
            throw XCTSkip("Set WPE_ASSETS_DIR to a WPE 2.8.42 assets directory (materials/util)")
        }
        let fixture = try ParityProgramCaptureFixture(root: URL(fileURLWithPath: directory), wpeAssets: wpeAssets)
        let assets = WPEParityProgramAssets(
            sceneDirectory: fixture.root.appendingPathComponent("scene-sources/3815666789"),
            assetRoots: fixture.assetRoots
        )
        let scene = try WPEParityProgramScene(document: fixture.document("3815666789"), assets: assets,
                                              settings: ParityProgramCaptureFixture.captureSettings)
        let frame = try WPEParityFrameComposer.compose(scene: scene.scene, post: scene.postProcess, frameIndex: 0)
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
            "g_Speed": [5], "g_Strength": [0.4], "g_Phase": [0.5], "g_Power": [1], "g_DirectionWeights": [1, 0.2],
            "g_CornerWeights": [1, 1, 0, 0], "g_Bounds": [0, 1], "g_NoiseScale": [0.05], "g_Ratio": [0.3],
            "g_Direction": [0], "g_Color4": [1, 1, 1, 1], "g_Alpha": [1],
        ]
        for (name, value) in expected {
            XCTAssertEqual(Self.floats(binding.constants[name]), value, name)
        }
        XCTAssertEqual(binding.textures, [0: .resource(foliage.reads[0]),
                                          1: .asset("masks/foliagesway_mask_74f285a7"), 2: .asset("util/noise")])
        XCTAssertFalse(binding.cullsBackFaces)

        let (ripple, rippleBinding) = try sceneDraw("effects/waterripple")
        XCTAssertEqual(rippleBinding.textures, [0: .resource(ripple.reads[0]),
                                                1: .asset("masks/waterripple_mask_886131ae"),
                                                2: .asset("effects/waterripplenormal")])
        XCTAssertEqual(Self.floats(rippleBinding.constants["g_AnimationSpeed"]), [0.11])
        XCTAssertEqual(Self.floats(rippleBinding.constants["g_SpecularColor"]), [1, 1, 1])

        let (albedo, albedoBinding) = try sceneDraw("genericimage4")
        XCTAssertEqual(albedoBinding.textures[0],
                       .imported(albedo.reads[0], asset: "AF3DD4AEF955193C9E71595ACC80BF57"))
    }
}
