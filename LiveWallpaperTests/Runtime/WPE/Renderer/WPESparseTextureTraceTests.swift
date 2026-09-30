#if !LITE_BUILD && DEBUG
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import Testing

@Suite("Sparse stage texture bindings retain numeric identity", .serialized)
struct WPESparseTextureTraceTests {
    @Test func namesAreFoundByRegisterInsteadOfArrayIndex() {
        #expect(WPECanonicalTraceRecorder.samplerName(at: 0, in: ["g_Texture5"]) == nil)
        #expect(WPECanonicalTraceRecorder.samplerName(at: 5, in: ["g_Texture5"]) == "g_Texture5")
        #expect(WPECanonicalTraceRecorder.samplerName(at: 2, in: ["g_Texture0", "g_Texture2", "g_Texture5"]) == "g_Texture2")
        #expect(WPECanonicalTraceRecorder.samplerName(at: 1, in: ["first", "second"]) == "second")
    }

    @Test func realVertexAndFragmentSamplingAndTraceAgreeOnSparseRegisters() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cache) }
        let translationCache = WPEShaderTranslationCache(rootURL: cache)
        let compiler = WPESwiftShaderCompiler(device: device, translationCache: translationCache)
        let vertex = """
        attribute vec3 a_Position;
        uniform sampler2D g_Texture2;
        varying vec4 v_Value;
        void main() { gl_Position = vec4(a_Position, 1.0); v_Value = texture2DLod(g_Texture2, vec2(0.5), 1.0); }
        """
        let fragment = """
        uniform sampler2D g_Texture5;
        varying vec4 v_Value;
        void main() { gl_FragColor = 0.5 * (v_Value + textureLod(g_Texture5, vec2(0.5), 1.0)); }
        """
        let request = try WPEShaderPreprocessor().process(shaderName: "sparse-stage-probe", vertexSource: vertex,
                                                          fragmentSource: fragment, comboValues: [:], materialTextureBindings: [:])
            .replacingVertexExecution(.authoredFullscreen)
        let result = try compiler.compile(request)
        let vs = try #require(result.vertexStage)
        #expect(vs.samplerNames == ["g_Texture2"] && result.samplerNames == ["g_Texture5"])
        translationCache.dropMemoryForTesting()
        let replay = try compiler.compile(request)
        #expect(translationCache.diskHitCountForTesting == 1)
        #expect(replay.vertexStage?.mslSource == vs.mslSource && replay.mslSource == result.mslSource)
        #expect(replay.vertexStage?.samplerNames == vs.samplerNames && replay.samplerNames == result.samplerNames)
        let state = try executor.translatedPipelineState(for: result, blendMode: "disabled", alphaWritePolicy: .all,
                                                         colorPixelFormat: .rgba32Float, depthPixelFormat: .invalid)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: 1, height: 1, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.renderTarget, .shaderRead]
        let target = try #require(device.makeTexture(descriptor: descriptor))
        let renderPass = MTLRenderPassDescriptor()
        renderPass.colorAttachments[0].texture = target
        renderPass.colorAttachments[0].loadAction = .clear
        renderPass.colorAttachments[0].storeAction = .store
        let command = try #require(device.makeCommandQueue()?.makeCommandBuffer())
        let encoder = try #require(command.makeRenderCommandEncoder(descriptor: renderPass))
        encoder.setRenderPipelineState(state)
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .nearest
        samplerDescriptor.magFilter = .nearest
        samplerDescriptor.mipFilter = .nearest
        let sampler = try #require(device.makeSamplerState(descriptor: samplerDescriptor))
        var textures: [MTLTexture] = []
        var bindings: [WPECanonicalTraceRecorder.TextureBindingInput] = []
        for slot in 0 ..< 6 {
            let mipmapped = slot == 2 || slot == 5
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float,
                                                              width: mipmapped ? 2 : 1, height: mipmapped ? 2 : 1, mipmapped: mipmapped)
            td.storageMode = .shared
            td.usage = [.shaderRead]
            let texture = try #require(device.makeTexture(descriptor: td))
            var base = Array(repeating: [Float(0.9), 0.9, 0.9, 1], count: td.width * td.height).flatMap(\.self)
            base.withUnsafeMutableBytes {
                texture.replace(region: MTLRegionMake2D(0, 0, td.width, td.height), mipmapLevel: 0,
                                withBytes: $0.baseAddress!, bytesPerRow: td.width * 16)
            }
            if mipmapped {
                let value: Float = slot == 2 ? 0.2 : 0.6
                var color = [value, value, value, Float(1)]
                color.withUnsafeMutableBytes {
                    texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 1, withBytes: $0.baseAddress!, bytesPerRow: 16)
                }
            }
            if slot < vs.requiredTextureSlotCount {
                encoder.setVertexTexture(texture, index: slot)
                encoder.setVertexSamplerState(sampler, index: slot)
            }
            encoder.setFragmentTexture(texture, index: slot)
            encoder.setFragmentSamplerState(sampler, index: slot)
            textures.append(texture)
            // Stale dense labels reproduce the old diagnostic input. Numeric identity wins.
            bindings.append(.init(slot: slot, name: slot == 0 ? "g_Texture5" : nil,
                                  reference: .asset("input-\(slot)"), texture: texture, fallbackToPrimary: false,
                                  sampler: ["probe-slot": String(slot)]))
        }
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        #expect(command.error == nil && command.status == .completed)
        var pixels = [Float](repeating: 0, count: 4)
        pixels.withUnsafeMutableBytes { target.getBytes($0.baseAddress!, bytesPerRow: 16, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0) }
        #expect(abs(pixels[0] - 0.4) < 1e-6 && pixels[3] == 1)
        withExtendedLifetime(textures) {}

        let artifacts = WPESceneDebugArtifacts()
        artifacts.setEnabledForTesting(true)
        let recorder = WPECanonicalTraceRecorder(artifacts: artifacts)
        recorder.beginScene(workshopID: "sparse-fixture", projectJsonPath: nil, descriptor: "GPU sparse register fixture")
        let pass = WPEPreparedRenderPass(pass: WPERenderPass(id: "probe", phase: .effect(file: "probe"), shader: "sparse-stage-probe",
                                                             source: .asset("input-0"), target: .scene, textures: [:], binds: [:], constants: [:], combos: [:],
                                                             blending: "disabled", cullMode: "nocull", depthTest: "disabled", depthWrite: "disabled"),
                                         shader: nil, textureBindings: [:], comboValues: [:], uniformValues: [:])
        recorder.recordCustomPass(pass: pass, destination: (.scene, target), result: result, textureBindings: bindings,
                                  packedUniformSlots: [], usesObjectQuad: false,
                                  nativeState: .scenePass(blendMode: "disabled", alphaWritePolicy: .all, cullMode: "nocull",
                                                          depthAttached: false, depthTest: "disabled", depthWrite: "disabled", reversedZ: false))
        let data = try #require(recorder.finishFrame(outputTexture: target, runtimeUniforms: nil, firstFrameStats: nil,
                                                     resolutionDiagnostics: .init(events: [])))
        let trace = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let draws = try #require(trace["passes"] as? [[String: Any]])
        let draw = try #require(draws.first)
        let sampled = try #require(draw["textures"] as? [[String: Any]])
        let fragmentBindings = sampled.filter { $0["stage"] as? String == "fragment" }
        #expect(fragmentBindings.compactMap { $0["slot"] as? Int } == Array(0 ..< 6))
        #expect(fragmentBindings.first { $0["slot"] as? Int == 5 }?["name"] as? String == "g_Texture5")
        let vertexBindings = sampled.filter { $0["stage"] as? String == "vertex" }
        #expect(vertexBindings.first { $0["slot"] as? Int == 2 }?["name"] as? String == "g_Texture2")
        let recordedState = try #require(draw["state"] as? [String: Any])
        let samplers = try #require(recordedState["samplers"] as? [[String: Any]])
        for (stage, slot) in [("vertex", 2), ("fragment", 5)] {
            let item = try #require(samplers.first { $0["stage"] as? String == stage && $0["slot"] as? Int == slot })
            #expect((item["descriptor"] as? [String: String])?["probe-slot"] == String(slot))
        }
        let contract = try #require(draw["colorContract"] as? [String: Any])
        let inputs = try #require(contract["inputs"] as? [[String: Any]])
        #expect(inputs.compactMap { $0["authoredSlot"] as? Int } == Array(0 ..< 6))
    }
}
#endif
