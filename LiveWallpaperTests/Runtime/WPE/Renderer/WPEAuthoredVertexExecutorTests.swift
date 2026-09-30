#if !LITE_BUILD && DEBUG
import CoreGraphics
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import Testing

@Suite("Authored fullscreen vertex executor contracts", .serialized)
struct WPEAuthoredVertexExecutorTests {
    @Test(arguments: [(false, true), (true, true), (true, false)])
    func dispatcherUsesRealStageOnlyWithItsPrewarmedPipeline(conditions: (Bool, Bool)) throws {
        let (prewarmed, enabled) = conditions
        let fixture = try fixture(prewarmed: prewarmed)
        fixture.executor.authoredVertexExecutionEnabled = enabled
        let output = try fixture.executor.render(pipeline: fixture.pipeline,
                                                 size: CGSize(width: 4, height: 4), textures: [:])
        let stagingDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: output.pixelFormat, width: 4, height: 4, mipmapped: false)
        stagingDescriptor.storageMode = .shared
        let staging = try #require(fixture.device.makeTexture(descriptor: stagingDescriptor))
        let command = try #require(fixture.executor.textureSourceCommandQueue.makeCommandBuffer())
        let blit = try #require(command.makeBlitCommandEncoder())
        blit.copy(from: output, to: staging)
        blit.endEncoding(); command.commit(); command.waitUntilCompleted()
        #expect(command.error == nil)
        var pixels = [UInt8](repeating: 0, count: 64)
        pixels.withUnsafeMutableBytes { staging.getBytes($0.baseAddress!, bytesPerRow: 16, from: MTLRegionMake2D(0, 0, 4, 4), mipmapLevel: 0) }
        let srgb = output.pixelFormat == .rgba8Unorm_srgb || output.pixelFormat == .bgra8Unorm_srgb
        let bgra = output.pixelFormat == .bgra8Unorm_srgb || output.pixelFormat == .bgra8Unorm
        for y in 0 ..< 4 {
            for x in 0 ..< 4 {
                let uv = [Double(x) + 0.5, Double(y) + 0.5].map { $0 / 4 }
                let linear = prewarmed && enabled ? uv.map { 0.375 + 0.25 * $0 } : uv
                let expected = linear.map { value in UInt8((255 * (srgb ? encode(value) : value)).rounded()) }
                let offset = (y * 4 + x) * 4
                #expect(abs(Int(pixels[offset + (bgra ? 2 : 0)]) - Int(expected[0])) <= 1)
                #expect(abs(Int(pixels[offset + 1]) - Int(expected[1])) <= 1)
            }
        }
    }

    @Test func uniformPlansKeepBothStageLayoutsWarmAndOnlyVertexGetsClipMVP() throws {
        let fixture = try fixture(prewarmed: true)
        let vs = try #require(fixture.result.vertexStage)
        let pass = fixture.pipeline.layers[0].passes[0]
        let before = fixture.executor.uniformPlanCompileCount
        let vertex = try fixture.executor.packTranslatedUniforms(for: pass, layout: vs.uniformLayout,
                                                                 stage: .vertex, vertexExecution: .authoredFullscreen)
        for _ in 0 ..< 3 {
            _ = try fixture.executor.packTranslatedUniforms(for: pass, layout: fixture.result.uniformLayout)
            _ = try fixture.executor.packTranslatedUniforms(for: pass, layout: vs.uniformLayout,
                                                            stage: .vertex, vertexExecution: .authoredFullscreen)
        }
        #expect(fixture.executor.uniformPlanCompileCount - before == 2)
        #expect(vertex == [SIMD4<Float>(1, 0, 0, 0), SIMD4<Float>(0, 1, 0, 0), SIMD4<Float>(0, 0, 1, 0), SIMD4<Float>(0, 0, 0, 1)])
    }

    @Test func fullscreenMVPAdmissionRejectsDepthAndNonPositionUses() throws {
        let fixture = try fixture(prewarmed: true)
        let texture = try #require(fixture.device.makeTexture(descriptor: .texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 4, height: 4, mipmapped: false)))
        let frame = WPEMetalFrameState(output: texture, sceneSize: CGSize(width: 4, height: 4))
        let pass = fixture.pipeline.layers[0].passes[0]
        let layer = fixture.pipeline.layers[0].graphLayer
        #expect(fixture.executor.authoredVertexRejection(for: pass, result: fixture.result, layer: layer, frameState: frame, effectTextureProjection: { nil }) == nil)
        var result = fixture.result
        result.fullscreenMVPPositionOnly = false
        #expect(fixture.executor.authoredVertexRejection(for: pass, result: result, layer: layer, frameState: frame, effectTextureProjection: { nil }) == .unverifiedFullscreenMVP)
        let authored = pass.pass
        let depth = WPERenderPass(id: authored.id, phase: authored.phase, shader: authored.shader, source: authored.source,
                                  target: authored.target, textures: authored.textures, binds: authored.binds, constants: authored.constants,
                                  combos: authored.combos, blending: authored.blending, cullMode: authored.cullMode,
                                  depthTest: "less", depthWrite: "enabled")
        let prepared = WPEPreparedRenderPass(pass: depth, shader: pass.shader, textureBindings: pass.textureBindings,
                                             comboValues: pass.comboValues, uniformValues: pass.uniformValues)
        #expect(fixture.executor.authoredVertexRejection(for: prepared, result: fixture.result, layer: layer, frameState: frame, effectTextureProjection: { nil }) == .unverifiedFullscreenDepth)
    }

    @Test func fullscreenMVPProofChecksActiveUsesAndPositionReads() {
        let declaration = "uniform mat4 g_ModelViewProjectionMatrix;"
        let position = "gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1.0);"
        #expect(WPEShaderStageLink.usesMVPOnlyForFullscreenPosition(declaration + " void main(){" + position + "}"))
        for assignment in ["gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);",
                           "gl_Position = mul(g_ModelViewProjectionMatrix, vec4(a_Position.xy, 0.0, 1.0));",
                           "gl_Position = vec4(a_Position, 1.0);"] {
            #expect(WPEShaderStageLink.usesMVPOnlyForFullscreenPosition(declaration + " void main(){" + assignment + "}"))
        }
        for extra in ["v_Other = g_ModelViewProjectionMatrix[2];", "v_Other = gl_Position;", "gl_Position.z += 0.2;"] {
            #expect(!WPEShaderStageLink.usesMVPOnlyForFullscreenPosition(declaration + " void main(){" + position + extra + "}"))
        }
        #expect(WPEShaderStageLink.usesMVPOnlyForFullscreenPosition(declaration + "\n#if UNUSED\nv_Other = gl_Position;\n#endif\nvoid main(){" + position + "}"))
    }

    @Test func recordedNativeClipMVPDoesNotClaimFullProjectionCoverage() {
        let uniform = WPEUniformSlot(name: "g_ModelViewProjectionMatrix", glslType: "mat4", slot: 0, slotCount: 4,
                                     arrayLength: nil, materialName: nil, defaultValue: nil)
        let coverage = WPEShaderSemanticCoverage.observedCustomDraw(passID: "draw", shaderName: "test", sourceClassification: nil,
                                                                    sourceFingerprint: nil, interface: nil, layout: [], sources: [],
                                                                    vertexLayout: [uniform], vertexSources: [.fullscreenVertexMVP], authoredVertexExecuted: true)
        #expect(coverage.entries.first { $0.feature == .uniformSupply && $0.stage == .vertex }?.status == .limited)
    }

    private struct Fixture {
        let device: MTLDevice
        let executor: WPEMetalRenderExecutor
        let pipeline: WPEPreparedRenderPipeline
        let result: WPEShaderCompileResult
    }

    private func fixture(prewarmed: Bool) throws -> Fixture {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let program = WPEShaderProgram(name: "linked-dispatch-test", vertexSource: """
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        uniform mat4 g_ModelViewProjectionMatrix;
        varying vec4 v_TexCoord;
        void main() {
            gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1);
            v_TexCoord = vec4(a_TexCoord, 0.375 + 0.25 * a_TexCoord);
        }
        """, fragmentSource: """
        varying vec4 v_TexCoord;
        uniform float tint; // {"default":1.0}
        void main() { gl_FragColor = vec4(v_TexCoord.zw * tint, 0, 1); }
        """, isBuiltin: false)
        func pass(_ id: String, shader: String, source: WPETextureReference, target: WPERenderTarget) -> WPERenderPass {
            WPERenderPass(id: id, phase: .command(file: "test/effect.json"), shader: shader, source: source, target: target,
                          textures: [:], binds: [:], constants: [:], combos: [:], blending: "disabled",
                          cullMode: "nocull", depthTest: "disabled", depthWrite: "disabled")
        }
        let prepared = WPEPreparedRenderPass(pass: pass("draw", shader: program.name, source: .asset("unused"), target: .layerComposite(name: "a")),
                                             shader: program, textureBindings: [:], comboValues: [:], uniformValues: [:])
        let present = WPEPreparedRenderPass(pass: pass("present", shader: "commands/copy", source: .fbo("a"), target: .scene),
                                            shader: WPEShaderProgram(name: "commands/copy", vertexSource: "", fragmentSource: "", isBuiltin: true),
                                            textureBindings: [0: .fbo("a")], comboValues: [:], uniformValues: [:])
        let graph = WPERenderLayer(objectID: "draw", objectName: "draw", imagePath: "unused", materialPath: nil,
                                   geometry: .identity, compositeA: "a", compositeB: "b", localFBOs: [], passes: [prepared.pass, present.pass])
        let pipeline = WPEPreparedRenderPipeline(layers: [.init(graphLayer: graph, passes: [prepared, present])])
        let request = try #require(try WPEMetalRenderExecutor.makeCompileRequest(for: prepared, recordFailure: false))
        let compiler = executor.shaderCompiler
        let result = try compiler.compile(request.replacingVertexExecution(.authoredFullscreen))
        let legacy = try compiler.compile(request)
        executor.seedCompiledShaderResultsByPassID([(passID: prepared.id, result: legacy)])
        executor.authoredShaderResultByPassID[prepared.id] = result
        let alpha = WPEMetalAlphaWritePolicy.resolve(targetID: .named("a"), blendMode: "disabled")
        for variant in prewarmed ? [legacy, result] : [legacy] {
            let prewarm = WPEMetalRenderExecutor.WPETranslatedPipelinePrewarm(device: device, defaultLibrary: executor.defaultLibrary,
                                                                              result: variant, vertexName: nil, blendMode: "disabled", alphaWritePolicy: alpha,
                                                                              colorPixelFormat: WPEMetalRenderExecutor.outputPixelFormat, depthPixelFormat: .invalid)
            let compiled = try #require(WPEMetalRenderExecutor.buildTranslatedPipeline(prewarm))
            executor.seedTranslatedPipelines([compiled])
        }
        return Fixture(device: device, executor: executor, pipeline: pipeline, result: result)
    }

    private func encode(_ value: Double) -> Double {
        value <= 0.0031308 ? value * 12.92 : 1.055 * pow(value, 1 / 2.4) - 0.055
    }
}
#endif
