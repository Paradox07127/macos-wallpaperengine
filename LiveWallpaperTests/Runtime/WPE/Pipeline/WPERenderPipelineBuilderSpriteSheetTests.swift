import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import Testing

@Suite("WPE render pipeline builder spritesheet")
struct WPERenderPipelineBuilderSpriteSheetTests {

    @Test("Generic image pass emits g_Texture0 sprite-sheet uniforms only when SPRITESHEET combo is enabled")
    func genericImageSpriteSheetEmitsTransformUniformsOnlyWhenEnabled() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let builder = WPERenderPipelineBuilder(cacheRootURL: fixture.root)

        // Builtin passes never run a compiled vertex stage, so the frame
        // transform lives in the fragment where the uniforms actually resolve.
        let spritePipeline = try builder.build(graph: makeGraph(combos: ["SPRITESHEET": 1]))
        let spriteFragment = try #require(spritePipeline.layers.first?.passes.first?.shader?.fragmentSource)

        #expect(spriteFragment.contains("uniform vec2 g_Texture0Translation"))
        #expect(spriteFragment.contains("uniform vec4 g_Texture0Rotation"))
        #expect(spriteFragment.contains("v_TexCoord.x * g_Texture0Rotation.xy"))
        #expect(spriteFragment.contains("v_TexCoord.y * g_Texture0Rotation.zw"))
        #expect(spriteFragment.contains("#define SPRITESHEET 1"))

        let plainPipeline = try builder.build(graph: makeGraph(combos: [:]))
        let plainFragment = try #require(plainPipeline.layers.first?.passes.first?.shader?.fragmentSource)

        #expect(plainFragment.contains("g_Texture0Translation") == false)
        #expect(plainFragment.contains("g_Texture0Rotation") == false)
    }

    @Test("Lowercase spritesheet combo also activates the sprite transform")
    func lowercaseSpriteSheetComboActivatesSpriteTransform() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let builder = WPERenderPipelineBuilder(cacheRootURL: fixture.root)
        let pipeline = try builder.build(graph: makeGraph(combos: ["spritesheet": 1]))
        let fragment = try #require(pipeline.layers.first?.passes.first?.shader?.fragmentSource)

        #expect(fragment.contains("uniform vec2 g_Texture0Translation"))
        #expect(fragment.contains("uniform vec4 g_Texture0Rotation"))
    }

    @Test("SPRITESHEET pass packs the TEXS sampling descriptor into generic image uniforms")
    func spriteSheetPassPacksSamplingDescriptorIntoUniforms() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let layer = try #require(makeGraph(combos: ["SPRITESHEET": 1]).layers.first)
        let descriptor = WPETexSpriteSamplingDescriptor(
            rotation: SIMD4<Float>(0.25, 0, 0, 0.5),
            translation: SIMD2<Float>(0.5, 0.25)
        )
        let texture = try #require(device.makeTexture(descriptor: .texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 8, height: 4, mipmapped: false
        )))
        WPEMetalTextureMetadataRegistry.shared.register(texture: texture, imageWidth: 4, imageHeight: 2)
        let prepared = WPEPreparedRenderPass(
            pass: layer.passes[0],
            shader: WPEShaderProgram(
                name: "genericimage4", vertexSource: "", fragmentSource: "", isBuiltin: true
            ),
            textureBindings: [:],
            comboValues: [:],
            uniformValues: [:]
        )

        let sprite = executor.genericImageUniforms(
            for: prepared, layer: layer, hasMask: false, sourceTexture: texture, spriteDescriptor: descriptor
        )
        #expect(sprite.spriteRotation == SIMD4<Float>(0.25, 0, 0, 0.5))
        #expect(sprite.spriteTranslation == SIMD4<Float>(0.5, 0.25, 1, 0))
        #expect(sprite.textureUVScale.x == 1 && sprite.textureUVScale.y == 1)

        // Same descriptor on a non-SPRITESHEET pass stays inert.
        let plainPass = WPERenderPass(
            id: "1.0", phase: .material, shader: "genericimage4",
            source: .image("materials/base.tex"), target: .scene,
            textures: [:], binds: [:], constants: [:], combos: [:],
            blending: "normal", cullMode: "nocull",
            depthTest: "disabled", depthWrite: "disabled"
        )
        let plain = executor.genericImageUniforms(
            for: WPEPreparedRenderPass(
                pass: plainPass, shader: prepared.shader,
                textureBindings: [:], comboValues: [:], uniformValues: [:]
            ),
            layer: layer, hasMask: false, sourceTexture: texture, spriteDescriptor: descriptor
        )
        #expect(plain.spriteRotation == SIMD4<Float>(1, 0, 0, 1))
        #expect(plain.spriteTranslation.z == 0)
        #expect(plain.textureUVScale.x == 0.5 && plain.textureUVScale.y == 0.5)
    }

    private func makeGraph(combos: [String: Int]) -> WPERenderGraph {
        WPERenderGraph(layers: [
            WPERenderLayer(
                objectID: "1",
                objectName: "Layer",
                imagePath: "materials/base.tex",
                materialPath: "materials/base.json",
                geometry: .identity,
                compositeA: "_rt_imageLayerComposite_1_a",
                compositeB: "_rt_imageLayerComposite_1_b",
                localFBOs: [],
                passes: [
                    WPERenderPass(
                        id: "1.0",
                        phase: .material,
                        shader: "genericimage4",
                        source: .image("materials/base.tex"),
                        target: .scene,
                        textures: [:],
                        binds: [:],
                        constants: [:],
                        combos: combos,
                        blending: "normal",
                        cullMode: "nocull",
                        depthTest: "disabled",
                        depthWrite: "disabled"
                    )
                ]
            )
        ])
    }

    private struct Fixture {
        let root: URL

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPERenderPipelineBuilderSpriteSheetTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return Fixture(root: root)
    }
}
