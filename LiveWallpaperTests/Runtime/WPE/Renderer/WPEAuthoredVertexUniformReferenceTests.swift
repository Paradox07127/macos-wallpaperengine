#if !LITE_BUILD && DEBUG
import CoreGraphics
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import Testing

@Suite("Authored vertex uniform reference contracts", .serialized)
struct WPEAuthoredVertexUniformReferenceTests {
    @Test func activeSourceProofRetainsHelpersMacrosAndShadowing() {
        let declaration = "uniform float g_TextureReductionScale;\n"
        let unused = declaration + "void main() { gl_Position = vec4(0.0); }"
        #expect(provesUnused(unused))
        #expect(provesUnused(declaration + "// g_TextureReductionScale\nvoid main() {}"))
        #expect(provesUnused(declaration + "#if 0\nfloat v = g_TextureReductionScale;\n#endif\nvoid main() {}"))
        for source in [
            "float helper() { return g_TextureReductionScale; }\nvoid main() {}",
            "#define FACTOR g_TextureReductionScale\nvoid main() {}",
            "void main() { float g_TextureReductionScale = 1.0; }",
            "void main() { gl_Position = vec4(g_TextureReductionScale); }",
        ] {
            #expect(!provesUnused(declaration + source))
        }
        let malformed = WPEShaderInterfaceParser.parse(
            vertex: declaration + "uniform UnknownBlock { float other; }; void main() {}", fragment: ""
        )
        #expect(malformed.unreferencedVertexUniforms == nil)
    }

    @Test(arguments: [0, 1, 2])
    func activeUniformsStillRequireTheirProducer(mode: Int) throws {
        let fixture = try fixture(mode: mode)
        let unused = try #require(fixture.result.shaderInterface?.unreferencedVertexUniforms)
        #expect(unused.contains("g_TextureReductionScale") == (mode != 1))
        #expect(unused.contains("g_ModelMatrixInverse") == (mode != 2))
        let expected: WPEAuthoredVertexRejection? = switch mode {
        case 1: .requiredUniformMissing("g_TextureReductionScale")
        case 2: .invalidMatrix("g_ModelMatrixInverse")
        default: nil
        }
        #expect(rejection(fixture, result: fixture.result) == expected)
        if mode == 1 {
            fixture.executor.frameUniformContext.textureReductionScaleByPassID[fixture.pass.id] = 2
            #expect(rejection(fixture, result: fixture.result) == nil)
        }
        if mode == 0 {
            let slots = WPEMetalTextureSlotTable(slotCount: 1)
            #expect(fixture.executor.authoredVertexResolvedInputRejection(
                for: fixture.pass, result: fixture.result, textures: slots
            ) == nil, "An unused texture-resolution declaration must not require an unbound slot")
        }
    }

    @Test func missingProofRemainsConservativeAndWarmCompilationRebuildsProof() throws {
        let fixture = try fixture(mode: 0)
        var unknown = fixture.result
        unknown.shaderInterface?.unreferencedVertexUniforms = nil
        #expect(rejection(fixture, result: unknown) == .requiredUniformMissing("g_TextureReductionScale"))
        unknown.shaderInterface = nil
        #expect(rejection(fixture, result: unknown) == .requiredUniformMissing("g_TextureReductionScale"))
        let request = try #require(try WPEMetalRenderExecutor.makeCompileRequest(for: fixture.pass, recordFailure: false))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = WPEShaderTranslationCache(rootURL: root)
        let compiler = WPESwiftShaderCompiler(device: fixture.executor.textureSourceDevice, translationCache: cache)
        let authored = request.replacingVertexExecution(.authoredFullscreen)
        let cold = try compiler.compile(authored)
        let memory = try compiler.compile(authored)
        #expect(cache.memoryHitCountForTesting == 1)
        cache.dropMemoryForTesting()
        let disk = try compiler.compile(authored)
        #expect(cache.diskHitCountForTesting == 1)
        #expect(cache.storeCountForTesting == 1)
        for result in [cold, memory, disk] {
            #expect(result.shaderInterface?.unreferencedVertexUniforms == fixture.result.shaderInterface?.unreferencedVertexUniforms)
            #expect(result.mslSource == cold.mslSource)
            #expect(result.vertexStage?.mslSource == cold.vertexStage?.mslSource)
            #expect(WPEShaderTranslationCache.Payload.from(result) == WPEShaderTranslationCache.Payload.from(cold))
            #expect(rejection(fixture, result: result) == nil)
        }
    }

    private func provesUnused(_ source: String) -> Bool {
        WPEShaderInterfaceParser.parse(vertex: source, fragment: "")
            .isVertexUniformProvenUnreferenced("g_TextureReductionScale")
    }

    private struct Fixture {
        let executor: WPEMetalRenderExecutor
        let pass: WPEPreparedRenderPass
        let layer: WPERenderLayer
        let frame: WPEMetalFrameState
        let result: WPEShaderCompileResult
    }

    private func rejection(_ fixture: Fixture, result: WPEShaderCompileResult) -> WPEAuthoredVertexRejection? {
        fixture.executor.authoredVertexRejection(
            for: fixture.pass, result: result, layer: fixture.layer,
            frameState: fixture.frame, effectTextureProjection: { nil }
        )
    }

    private func fixture(mode: Int) throws -> Fixture {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let program = WPEShaderProgram(name: "uniform-reference-probe", vertexSource: """
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        uniform mat4 g_ModelViewProjectionMatrix;
        uniform float g_TextureReductionScale;
        uniform vec4 g_Texture0Resolution;
        uniform mat4 g_ModelMatrixInverse;
        varying vec2 v_TexCoord;
        void main() {
            gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1.0);
            v_TexCoord = a_TexCoord;
        #if MODE == 1
            v_TexCoord *= g_TextureReductionScale;
        #endif
        #if MODE == 2
            v_TexCoord += g_ModelMatrixInverse[0].xy;
        #endif
        }
        """, fragmentSource: """
        varying vec2 v_TexCoord;
        void main() { gl_FragColor = vec4(v_TexCoord, 0.0, 1.0); }
        """, isBuiltin: false)
        let pass = WPERenderPass(
            id: "reference", phase: .effect(file: "probe.json"), shader: program.name,
            source: .asset("unused"), target: .layerComposite(name: "a"),
            textures: [:], binds: [:], constants: [:], combos: ["MODE": mode], blending: "disabled",
            cullMode: "nocull", depthTest: "disabled", depthWrite: "disabled"
        )
        let prepared = WPEPreparedRenderPass(pass: pass, shader: program, textureBindings: [:],
                                             comboValues: ["MODE": mode], uniformValues: [:])
        let layer = WPERenderLayer(objectID: "reference", objectName: "reference", imagePath: "unused", materialPath: nil,
                                   geometry: .identity, compositeA: "a", compositeB: "b", localFBOs: [], passes: [pass])
        let request = try #require(try WPEMetalRenderExecutor.makeCompileRequest(for: prepared, recordFailure: false))
        let result = try executor.shaderCompiler.compile(request.replacingVertexExecution(.authoredFullscreen))
        let texture = try #require(device.makeTexture(descriptor: .texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 4, height: 4, mipmapped: false
        )))
        return Fixture(executor: executor, pass: prepared, layer: layer,
                       frame: WPEMetalFrameState(output: texture, sceneSize: CGSize(width: 4, height: 4)), result: result)
    }
}
#endif
