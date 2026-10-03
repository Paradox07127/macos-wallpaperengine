#if !LITE_BUILD && DEBUG
import CoreGraphics
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import simd
import Testing

@Suite("Authored fullscreen vertex executor contracts", .serialized)
struct WPEAuthoredVertexExecutorTests {
    @Test("A suspended pass selects local, object, and alpha variants after preprocess memo eviction")
    func samePassSelectsPrewarmedRequestVariantsAfterMemoEviction() throws {
        let fixture = try fixture(prewarmed: true)
        let (pipeline, camera) = publicationPipeline(fixture)
        let layer = pipeline.layers[0]
        let variants = WPEMetalRenderExecutor.authoredPrewarmVariants(for: layer, camera: camera)
            .filter { $0.pass.shader?.isBuiltin == false }
        #expect(variants.count == 5)
        var keys: [String: WPEShaderCompileResult] = [:]
        for variant in variants {
            let request = try #require(fixture.executor.authoredPrewarmRequest(for: variant.pass, execution: variant.vertexExecution))
            if keys[request.translationCacheKey] == nil {
                keys[request.translationCacheKey] = try fixture.executor.shaderCompiler.compile(request)
            }
        }
        let local = try #require(variants.first { $0.vertexExecution == .authoredFullscreen })
        let alternateLocal = try #require(variants.first { $0.vertexExecution == .authoredFullscreen && $0.pass.pass.source == .fbo("b") })
        let terminal = try #require(variants.first { $0.vertexExecution == .authoredObjectQuad })
        let straightLocal = WPEPreparedRenderPass(pass: local.pass.pass, shader: local.pass.shader,
                                                  textureBindings: local.pass.textureBindings, comboValues: local.pass.comboValues, uniformValues: [:],
                                                  alphaContract: .init(unpremultipliedInputSlots: [], premultipliedOutput: false))
        let straightRequest = try #require(fixture.executor.authoredPrewarmRequest(for: straightLocal, execution: .authoredFullscreen))
        keys[straightRequest.translationCacheKey] = try fixture.executor.shaderCompiler.compile(straightRequest)
        fixture.executor.seedTranslatedShaderCache(keys.map { (key: $0.key, result: $0.value) })
        let preparedMetadataCount = fixture.executor.authoredRequestKeyByIdentity.count
        fixture.executor.releaseTransientResources()
        #expect(fixture.executor.authoredRequestKeyByIdentity.count == preparedMetadataCount)
        #expect(fixture.executor.authoredRequestKeyByPassID.isEmpty && fixture.executor.authoredShaderResultByPassID.isEmpty)
        let namespace = UUID().uuidString
        for index in 0 ..< 129 {
            let program = WPEShaderProgram(name: "eviction-\(namespace)-\(index)", vertexSource: "void main() {}",
                                           fragmentSource: "void main() {}", isBuiltin: false)
            let pass = WPEPreparedRenderPass(pass: local.pass.pass, shader: program, textureBindings: [:], comboValues: [:], uniformValues: [:])
            _ = try WPEMetalRenderExecutor.makeCompileRequest(for: pass, recordFailure: false)
        }
        #expect(try WPEMetalRenderExecutor.makeCompileRequest(for: local.pass, recordFailure: false, allowPreprocessing: false) == nil)
        let cacheCount = fixture.executor.translatedShaderCache.count
        for (pass, execution) in [(local.pass, WPEVertexExecution.authoredFullscreen), (terminal.pass, .authoredObjectQuad),
                                  (alternateLocal.pass, .authoredFullscreen),
                                  (straightLocal, .authoredFullscreen), (local.pass, .authoredFullscreen)] {
            let selected = WPEPreparedRenderPipeline(layers: [layer.replacing(graphLayer: layer.graphLayer.replacingPasses([pass.pass]), passes: [pass])])
            fixture.executor.adoptPrewarmedAuthoredShaders(for: selected, camera: camera)
            let result = try #require(fixture.executor.authoredShaderResultByPassID[pass.id])
            #expect(result.vertexStage?.execution == execution)
            #expect(result.alphaContract?.unpremultipliedInputSlots == (pass.alphaContract?.unpremultipliedInputSlots ?? [0]))
            #expect(fixture.executor.authoredVertexFailureByPassID[pass.id] == nil)
        }
        #expect(fixture.executor.translatedShaderCache.count == cacheCount)
    }

    @Test("A missing object request does not poison the same pass's prepared local request")
    func authoredRequestMissIsScopedToItsKey() throws {
        let fixture = try fixture(prewarmed: true)
        let (pipeline, camera) = publicationPipeline(fixture)
        let layer = pipeline.layers[0]
        let variants = WPEMetalRenderExecutor.authoredPrewarmVariants(for: layer, camera: camera)
        let local = try #require(variants.first { $0.pass.shader?.isBuiltin == false && $0.vertexExecution == .authoredFullscreen })
        let terminal = try #require(variants.first { $0.pass.shader?.isBuiltin == false && $0.vertexExecution == .authoredObjectQuad })
        let localRequest = try #require(fixture.executor.authoredPrewarmRequest(for: local.pass, execution: local.vertexExecution))
        let terminalRequest = try #require(fixture.executor.authoredPrewarmRequest(for: terminal.pass, execution: terminal.vertexExecution))
        let localResult = try fixture.executor.shaderCompiler.compile(localRequest)
        fixture.executor.seedTranslatedShaderCache([(localRequest.translationCacheKey, localResult)])
        for variant in [terminal, local, terminal, local] {
            let selected = WPEPreparedRenderPipeline(layers: [layer.replacing(
                graphLayer: layer.graphLayer.replacingPasses([variant.pass.pass]), passes: [variant.pass]
            )])
            fixture.executor.adoptPrewarmedAuthoredShaders(for: selected, camera: camera)
            if variant.vertexExecution == .authoredObjectQuad {
                #expect(fixture.executor.authoredRequestKeyByPassID[variant.pass.id] == terminalRequest.translationCacheKey)
                #expect(fixture.executor.authoredShaderResultByPassID[variant.pass.id] == nil)
                #expect(fixture.executor.authoredVertexFailureByPassID[variant.pass.id] == "authored-stage-not-prepared")
            } else {
                #expect(fixture.executor.authoredRequestKeyByPassID[variant.pass.id] == localRequest.translationCacheKey)
                #expect(fixture.executor.authoredShaderResultByPassID[variant.pass.id]?.vertexStage?.execution == .authoredFullscreen)
                #expect(fixture.executor.authoredVertexFailureByPassID[variant.pass.id] == nil)
            }
        }
    }

    @Test("Publication remains canonical until every authored role and PSO is prepared")
    func publicationReadinessRequiresAllShadersAndPipelines() throws {
        let fixture = try fixture(prewarmed: true)
        let (pipeline, camera) = publicationPipeline(fixture)
        var pending: [WPEMetalRenderExecutor.WPETranslatedPipelinePrewarm] = []
        var objectRequests: [(WPEPreparedRenderPass, WPEShaderCompileRequest)] = []
        for variant in WPEMetalRenderExecutor.authoredPrewarmVariants(for: pipeline.layers[0], camera: camera) where variant.pass.shader?.isBuiltin == false {
            let request = try #require(fixture.executor.authoredPrewarmRequest(for: variant.pass, execution: variant.vertexExecution))
            if variant.vertexExecution == .authoredObjectQuad {
                objectRequests.append((variant.pass, request))
                continue
            }
            let result: WPEShaderCompileResult
            if let cached = fixture.executor.translatedShaderCache[request.translationCacheKey] {
                result = cached
            } else {
                result = try fixture.executor.shaderCompiler.compile(request)
                fixture.executor.seedTranslatedShaderCache([(request.translationCacheKey, result)])
            }
            let prewarm = WPEMetalRenderExecutor.WPETranslatedPipelinePrewarm(device: fixture.device, defaultLibrary: fixture.executor.defaultLibrary,
                                                                              result: result, vertexName: nil, blendMode: variant.pass.pass.blending,
                                                                              alphaWritePolicy: .resolve(targetID: WPEMetalTargetID(target: variant.pass.pass.target), blendMode: variant.pass.pass.blending),
                                                                              colorPixelFormat: WPEMetalRenderExecutor.outputPixelFormat, depthPixelFormat: .invalid)
            try fixture.executor.seedTranslatedPipelines([#require(WPEMetalRenderExecutor.buildTranslatedPipeline(prewarm))])
        }
        #expect(fixture.executor.readyEffectPublicationLayerIDs(in: pipeline, camera: camera).isEmpty)
        for (pass, request) in objectRequests {
            let result: WPEShaderCompileResult
            if let cached = fixture.executor.translatedShaderCache[request.translationCacheKey] {
                result = cached
            } else {
                result = try fixture.executor.shaderCompiler.compile(request)
                fixture.executor.seedTranslatedShaderCache([(request.translationCacheKey, result)])
            }
            pending.append(.init(device: fixture.device, defaultLibrary: fixture.executor.defaultLibrary,
                                 result: result, vertexName: nil, blendMode: pass.pass.blending,
                                 alphaWritePolicy: .resolve(targetID: WPEMetalTargetID(target: pass.pass.target), blendMode: pass.pass.blending),
                                 colorPixelFormat: WPEMetalRenderExecutor.outputPixelFormat, depthPixelFormat: .invalid))
        }
        #expect(fixture.executor.readyEffectPublicationLayerIDs(in: pipeline, camera: camera).isEmpty)
        let retained = pipeline.retainingEffectPublication(in: [])
        #expect(retained.layers[0].passes == pipeline.layers[0].passes)
        #expect(retained.layers[0].effectPublication == nil)
        #expect(retained.resolvingEffectPublication(passVisibility: [:], camera: camera) == retained)
        for prewarm in pending {
            try fixture.executor.seedTranslatedPipelines([#require(WPEMetalRenderExecutor.buildTranslatedPipeline(prewarm))])
        }
        let resolveCount = fixture.executor.passPipelineResolveCount
        #expect(fixture.executor.readyEffectPublicationLayerIDs(in: pipeline, camera: camera).isEmpty)
        #expect(fixture.executor.passPipelineResolveCount == resolveCount)
        let native = WPEMetalRenderExecutor.authoredPrewarmVariants(for: pipeline.layers[0], camera: camera).filter {
            $0.pass.shader?.isBuiltin == true && $0.pass.alphaContract?.premultipliedOutput == false
        }
        #expect(native.count == 2)
        for (index, variant) in native.enumerated() {
            let pass = variant.pass
            let object = variant.vertexExecution == .authoredObjectQuad
            _ = try fixture.executor.passPipelineState(passID: pass.id, variant: .solidLayerStraight, objectQuad: object,
                                                       vertexName: object ? "wpe_object_quad_vertex" : "wpe_fullscreen_vertex", fragmentName: "wpe_solidlayer_straight_fragment",
                                                       blendMode: pass.pass.blending, alphaWritePolicy: .resolve(targetID: WPEMetalTargetID(target: pass.pass.target), blendMode: pass.pass.blending),
                                                       colorPixelFormat: WPEMetalRenderExecutor.outputPixelFormat, depthPixelFormat: .invalid)
            #expect(fixture.executor.readyEffectPublicationLayerIDs(in: pipeline, camera: camera).isEmpty == (index == 0))
        }
        #expect(fixture.executor.readyEffectPublicationLayerIDs(in: pipeline, camera: camera) == [pipeline.layers[0].id])
    }

    @Test("An unprepared clone performs no preprocessing while selecting an authored request")
    func coldCloneCannotPreprocessDuringAdoption() throws {
        let fixture = try fixture(prewarmed: true)
        let original = fixture.pipeline.layers[0].passes[0]
        let program = WPEShaderProgram(name: "unprepared-\(UUID().uuidString)", vertexSource: "invalid unprepared shader",
                                       fragmentSource: "invalid unprepared shader", isBuiltin: false)
        let pass = WPEPreparedRenderPass(pass: original.pass, shader: program, textureBindings: [:], comboValues: [:], uniformValues: [:])
        let layer = fixture.pipeline.layers[0].replacing(passes: [pass])
        let pipeline = WPEPreparedRenderPipeline(layers: [layer])
        fixture.executor.adoptPrewarmedAuthoredShaders(for: pipeline, camera: .identity)
        #expect(fixture.executor.authoredShaderResultByPassID[pass.id] == nil)
        #expect(fixture.executor.authoredVertexFailureByPassID[pass.id] == "authored-request-not-prepared")
        #expect(try WPEMetalRenderExecutor.makeCompileRequest(for: pass, recordFailure: false, allowPreprocessing: false) == nil)
    }

    @MainActor
    @Test("Authored request metadata survives profile suspension and retires with the scene")
    func authoredRequestMetadataFollowsSceneLifetime() async throws {
        let scene = try MetalSceneFixture.solidColorScene()
        defer { scene.cleanup() }
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try WPEMetalSceneRenderer(descriptor: scene.descriptor, cacheRootURL: scene.root,
                                                 dependencyMounts: [], frame: CGRect(x: 0, y: 0, width: 64, height: 64), device: device)
        defer { renderer.cleanup() }
        try await renderer.load()
        let program = WPEShaderProgram(name: "lifetime-\(UUID().uuidString)", vertexSource: "void main() {}",
                                       fragmentSource: "void main() {}", isBuiltin: false)
        let authored = WPERenderPass(id: "lifetime", phase: .material, shader: program.name, source: .asset("unused"), target: .scene,
                                     textures: [:], binds: [:], constants: [:], combos: [:], blending: "disabled",
                                     cullMode: "nocull", depthTest: "disabled", depthWrite: "disabled")
        let pass = WPEPreparedRenderPass(pass: authored, shader: program, textureBindings: [:], comboValues: [:], uniformValues: [:])
        let identity = try #require(WPEMetalRenderExecutor.authoredShaderRequestIdentity(for: pass, execution: .authoredObjectQuad))
        let request = try #require(renderer.executor.authoredPrewarmRequest(for: pass, execution: .authoredObjectQuad))
        renderer.applyPerformanceProfile(.suspended)
        renderer.applyPerformanceProfile(.quality)
        #expect(renderer.executor.authoredRequestKeyByIdentity[identity] == request.translationCacheKey)
        try await renderer.reload()
        #expect(renderer.executor.authoredRequestKeyByIdentity[identity] == nil)
        _ = try #require(renderer.executor.authoredPrewarmRequest(for: pass, execution: .authoredObjectQuad))
        renderer.cleanup()
        #expect(renderer.executor.authoredRequestKeyByIdentity.isEmpty)
    }

    @Test(arguments: [(false, true, false), (true, true, false), (true, false, false),
                      (false, true, true), (true, true, true), (true, false, true)])
    func dispatcherUsesRealStageOnlyWithItsPrewarmedPipeline(conditions: (Bool, Bool, Bool)) throws {
        let (prewarmed, enabled, lookupByContent) = conditions
        let fixture = try fixture(prewarmed: prewarmed)
        if lookupByContent {
            let pass = fixture.pipeline.layers[0].passes[0]
            let request = try #require(try WPEMetalRenderExecutor.makeCompileRequest(for: pass, recordFailure: false))
            fixture.executor.seedTranslatedShaderCache([(key: request.replacingVertexExecution(.authoredFullscreen).translationCacheKey, result: fixture.result)])
            fixture.executor.authoredShaderResultByPassID.removeAll()
        }
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
        #expect(WPEShaderStageLink.usesMVPOnlyForFullscreenPosition(declaration + " uniform mat4 g_ModelViewProjectionMatrixInverse; void main(){" + position + "}"))
        #expect(!WPEShaderStageLink.usesMVPOnlyForFullscreenPosition(declaration + " uniform mat4 g_ModelViewProjectionMatrixInverse; void main(){" + position + "v_Other=g_ModelViewProjectionMatrixInverse[0];}"))
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

    @Test func fullscreenMVPProofAdmitsReadOnlyPositionAliasesAndRejectsEdits() {
        let declaration = "attribute vec3 a_Position; uniform mat4 g_ModelViewProjectionMatrix;"
        let position = "gl_Position = mul(vec4(position, 1.0), g_ModelViewProjectionMatrix);"
        let prefix = declaration + " void main(){ vec3 position = a_Position;"
        #expect(WPEShaderStageLink.usesMVPOnlyForFullscreenPosition(prefix + position + "}"))
        #expect(WPEShaderStageLink.usesMVPOnlyForFullscreenPosition(
            declaration + "\n#define MODE 0\nvoid main(){vec3 position=a_Position;\n#if MODE\nposition.xy *= 2.0;\n#endif\n" + position + "}"
        ))
        for extra in ["position.xy += vec2(1.0);", "position = vec3(0.0);", "edit(position);", "v_Raw = position.xy;"] {
            #expect(!WPEShaderStageLink.usesMVPOnlyForFullscreenPosition(prefix + extra + position + "}"))
        }
        for extra in ["a_Position.xy *= 2.0;", "v_Raw = a_Position.xy;"] {
            #expect(!WPEShaderStageLink.usesMVPOnlyForFullscreenPosition(
                declaration + " void main(){" + extra + "gl_Position=mul(vec4(a_Position,1.0),g_ModelViewProjectionMatrix);}"
            ))
        }
    }

    @Test("The staged Windows local transform needs its publication role and a structured XY proof", arguments: [false, true])
    func stagedLocalTransformRequiresPublicationRole(extraMVPConsumer: Bool) throws {
        let fixture = try fixture(prewarmed: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("local-effect-proof-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let vertexSource = extraMVPConsumer ? Self.localTransformProbeVertex.replacingOccurrences(
            of: "v_TexCoord = a_TexCoord;", with: "v_TexCoord = a_TexCoord; v_TexCoord += g_ModelViewProjectionMatrix[0].xy;"
        ) : Self.localTransformProbeVertex
        let files = ["shaders/probe-clock.vert": vertexSource,
                     "shaders/probe-clock.frag": "varying vec2 v_TexCoord; void main(){gl_FragColor=vec4(v_TexCoord,0.25,1.0);}"]
        for (path, source) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(source.utf8).write(to: url)
        }
        let authored = WPERenderPass(id: "local", phase: .effect(file: "test/probe.json"), shader: "probe-clock", source: .fbo("a"),
                                     target: .layerComposite(name: "b"), textures: [:], binds: [:], constants: [:], combos: ["MODE": 1], blending: "disabled",
                                     cullMode: "nocull", depthTest: "disabled", depthWrite: "disabled")
        let graph = fixture.pipeline.layers[0].graphLayer.replacingPasses([authored])
        let staged = try WPERenderPipelineBuilder(cacheRootURL: root).build(graph: .init(layers: [graph]),
                                                                            canonicalCompositeRotationEnabled: false, fullFramePassthroughElisionEnabled: false)
        let pass = try #require(staged.layers.first?.passes.first)
        let request = try #require(fixture.executor.authoredPrewarmRequest(for: pass, execution: .authoredFullscreen))
        #expect(request.processedVertexSource.contains("vec3 DecompressNormal(vec4 packed)"))
        #expect(request.processedVertexSource.contains("vec3 DecompressNormal(vec3 packed)"))
        let result = try fixture.executor.shaderCompiler.compile(request)
        #expect(result.fullscreenMVPPositionOnly == false)
        #expect(result.localEffectMVPPositionOnly == !extraMVPConsumer)
        #expect(try fixture.executor.shaderCompiler.compile(request).localEffectMVPPositionOnly == !extraMVPConsumer)
        let marked = WPEPreparedRenderPass(pass: pass.pass, shader: pass.shader, textureBindings: pass.textureBindings,
                                           comboValues: pass.comboValues, uniformValues: pass.uniformValues, materialUniformNames: pass.materialUniformNames,
                                           stageUniformBindings: pass.stageUniformBindings, publicationVertexRole: .localEffect)
        let texture = try #require(fixture.device.makeTexture(descriptor: .texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 4, height: 4, mipmapped: false)))
        let frame = WPEMetalFrameState(output: texture, sceneSize: CGSize(width: 4, height: 4), cameraUniforms: .identity)
        #expect(fixture.executor.authoredVertexRejection(for: pass, result: result, layer: graph, frameState: frame,
                                                         effectTextureProjection: { nil }) == .unverifiedFullscreenMVP)
        #expect(fixture.executor.authoredVertexRejection(for: marked, result: result, layer: graph, frameState: frame,
                                                         effectTextureProjection: { nil }) == (extraMVPConsumer ? .unverifiedFullscreenMVP : nil))
        let depth = WPERenderPass(id: marked.id, phase: marked.pass.phase, shader: marked.pass.shader, source: marked.pass.source,
                                  target: marked.pass.target, textures: marked.pass.textures, binds: marked.pass.binds, constants: marked.pass.constants,
                                  combos: marked.pass.combos, blending: marked.pass.blending, cullMode: marked.pass.cullMode, depthTest: "less", depthWrite: "enabled")
        let markedDepth = WPEPreparedRenderPass(pass: depth, shader: marked.shader, textureBindings: marked.textureBindings,
                                                comboValues: marked.comboValues, uniformValues: marked.uniformValues, materialUniformNames: marked.materialUniformNames,
                                                stageUniformBindings: marked.stageUniformBindings, publicationVertexRole: .localEffect)
        #expect(fixture.executor.authoredVertexRejection(for: markedDepth, result: result, layer: graph, frameState: frame,
                                                         effectTextureProjection: { nil }) == .unverifiedFullscreenDepth)
        let fragment = request.processedFragmentSource
        let source = request.processedVertexSource
        let unused = "void unused(inout vec4 q){if(q.x>0.0){q=vec4(1.0);}}"
        #expect(WPEShaderStageLink.usesMVPOnlyForLocalEffectPosition(unused + "\n" + source, fragment: fragment) == !extraMVPConsumer)
        for extra in ["v_TexCoord += g_ModelViewProjectionMatrix[0].xy;", "gl_Position.z += 0.2;", "position.z = 0.2;",
                      "v_TexCoord += g_ModelViewProjectionMatrixInverse[0].xy;"] {
            let modified = source.replacingOccurrences(of: "v_TexCoord = a_TexCoord;", with: "v_TexCoord = a_TexCoord;" + extra)
            #expect(!WPEShaderStageLink.usesMVPOnlyForLocalEffectPosition(modified, fragment: fragment))
        }
        for definition in ["#define a_Position vec3(0.0)", "#define gl_Position v_TexCoord", "#define g_ModelViewProjectionMatrix mat4(1.0)",
                           "#define g_ModelViewProjectionMatrixInverse mat4(1.0)", "#define inverse(m) m", "#define position a_Position", "#define a_Position"] {
            #expect(!WPEShaderStageLink.usesMVPOnlyForLocalEffectPosition(definition + "\n" + source, fragment: fragment))
        }
        let impure = "vec2 edit(inout vec2 q){q=vec2(0.0);return q;}\n" + source.replacingOccurrences(of: "applyFx(position.xy)", with: "edit(position.xy)")
        #expect(!WPEShaderStageLink.usesMVPOnlyForLocalEffectPosition(impure, fragment: fragment))
        let customMultiply = "vec4 mul(vec4 p,mat4 m){return vec4(0.0);}\n" + source
        #expect(!WPEShaderStageLink.usesMVPOnlyForLocalEffectPosition(customMultiply, fragment: fragment))
        let (canonical, camera) = publicationPipeline(fixture, includingTail: true)
        let original = canonical.layers[0].passes[1]
        let effect = WPEPreparedRenderPass(pass: original.pass, shader: pass.shader, textureBindings: original.textureBindings,
                                           comboValues: pass.comboValues, uniformValues: pass.uniformValues, materialUniformNames: pass.materialUniformNames,
                                           stageUniformBindings: pass.stageUniformBindings)
        let candidate = WPEPreparedRenderPipeline(layers: [canonical.layers[0].replacing(
            passes: [canonical.layers[0].passes[0], effect] + canonical.layers[0].passes.dropFirst(2)
        )])
        try prewarmPublicationTestVariants(candidate, camera: camera, fixture: fixture)
        #expect(fixture.executor.readyEffectPublicationLayerIDs(in: candidate, camera: camera).isEmpty == extraMVPConsumer)
        let tail = canonical.layers[0].passes[2]
        let transformedTail = WPEPreparedRenderPass(pass: tail.pass, shader: pass.shader, textureBindings: tail.textureBindings,
                                                    comboValues: pass.comboValues, uniformValues: pass.uniformValues, materialUniformNames: pass.materialUniformNames,
                                                    stageUniformBindings: pass.stageUniformBindings)
        let tailCandidate = WPEPreparedRenderPipeline(layers: [canonical.layers[0].replacing(
            passes: Array(canonical.layers[0].passes.prefix(2)) + [transformedTail, canonical.layers[0].passes[3]]
        )])
        try prewarmPublicationTestVariants(tailCandidate, camera: camera, fixture: fixture)
        #expect(fixture.executor.readyEffectPublicationLayerIDs(in: tailCandidate, camera: camera) == ["draw"])
    }

    private func prewarmPublicationTestVariants(_ candidate: WPEPreparedRenderPipeline, camera: WPEMetalCameraUniforms, fixture: Fixture) throws {
        for variant in WPEMetalRenderExecutor.authoredPrewarmVariants(for: candidate.layers[0], camera: camera) {
            let prepared = variant.pass
            if prepared.shader?.isBuiltin == false {
                let compileRequest = try #require(fixture.executor.authoredPrewarmRequest(for: prepared, execution: variant.vertexExecution))
                let compiled: WPEShaderCompileResult
                if let cached = fixture.executor.translatedShaderCache[compileRequest.translationCacheKey] {
                    compiled = cached
                } else {
                    compiled = try fixture.executor.shaderCompiler.compile(compileRequest)
                    fixture.executor.seedTranslatedShaderCache([(compileRequest.translationCacheKey, compiled)])
                }
                let prewarm = WPEMetalRenderExecutor.WPETranslatedPipelinePrewarm(device: fixture.device, defaultLibrary: fixture.executor.defaultLibrary,
                                                                                  result: compiled, vertexName: nil, blendMode: prepared.pass.blending,
                                                                                  alphaWritePolicy: .resolve(targetID: WPEMetalTargetID(target: prepared.pass.target), blendMode: prepared.pass.blending),
                                                                                  colorPixelFormat: WPEMetalRenderExecutor.outputPixelFormat, depthPixelFormat: .invalid)
                try fixture.executor.seedTranslatedPipelines([#require(WPEMetalRenderExecutor.buildTranslatedPipeline(prewarm))])
            } else if prepared.alphaContract?.premultipliedOutput == false {
                let object = variant.vertexExecution == .authoredObjectQuad
                _ = try fixture.executor.passPipelineState(passID: prepared.id, variant: .solidLayerStraight, objectQuad: object,
                                                           vertexName: object ? "wpe_object_quad_vertex" : "wpe_fullscreen_vertex", fragmentName: "wpe_solidlayer_straight_fragment",
                                                           blendMode: prepared.pass.blending, alphaWritePolicy: .resolve(targetID: WPEMetalTargetID(target: prepared.pass.target), blendMode: prepared.pass.blending),
                                                           colorPixelFormat: WPEMetalRenderExecutor.outputPixelFormat, depthPixelFormat: .invalid)
            }
        }
    }

    @Test func fullscreenProofExcludesOnlyPureUnobservedVertexWrites() {
        let vertex = """
        #define mul(a,b) ((b)*(a))
        attribute vec3 a_Position;
        uniform mat4 g_ModelViewProjectionMatrix;
        uniform mat4 g_ModelViewProjectionMatrixInverse;
        varying vec4 unused;
        varying vec2 uv;
        void main() {
            gl_Position = mul(vec4(a_Position,1),g_ModelViewProjectionMatrix);
            uv = vec2(0.5);
            unused.xyz = mul(vec4(0,0,0,1),g_ModelViewProjectionMatrixInverse).xyw;
            unused.xy *= 0.5;
        }
        """
        let fragment = "varying vec2 uv; void main(){gl_FragColor=vec4(uv,0,1);}"
        #expect(!WPEShaderStageLink.usesMVPOnlyForFullscreenPosition(vertex))
        #expect(WPEShaderStageLink.usesMVPOnlyForFullscreenPosition(vertex, fragment: fragment))
        let include = vertex.replacingOccurrences(of: "attribute vec3 a_Position;", with: "vec2 helper(vec2 value) { return value; }\nattribute vec3 a_Position;")
        #expect(WPEShaderStageLink.usesMVPOnlyForFullscreenPosition(include, fragment: fragment))
        let custom = vertex.replacingOccurrences(of: "attribute vec3 a_Position;", with: "vec4 mul(vec4 value,mat4 matrix) { counter++; return matrix*value; }\nattribute vec3 a_Position;")
        #expect(!WPEShaderStageLink.usesMVPOnlyForFullscreenPosition(custom, fragment: fragment))
        for live in ["varying vec4 unused; void main(){gl_FragColor=unused;}",
                     "varying vec4 unused; vec4 helper(){return unused;} void main(){gl_FragColor=helper();}"] {
            #expect(!WPEShaderStageLink.usesMVPOnlyForFullscreenPosition(vertex, fragment: live))
        }
        for change in ["uv = unused.xy;", "gl_Position.xy += unused.xy;", "if(unused.x>0) uv=vec2(1);"] {
            let relay = vertex.replacingOccurrences(of: "unused.xy *= 0.5;", with: "unused.xy *= 0.5; " + change)
            #expect(!WPEShaderStageLink.usesMVPOnlyForFullscreenPosition(relay, fragment: fragment))
        }
        for expression in ["modify(g_ModelViewProjectionMatrixInverse)", "vec3(g_ModelViewProjectionMatrixInverse[0].x + counter++)", "mul(vec4(counter++),g_ModelViewProjectionMatrixInverse)"] {
            let impure = vertex.replacingOccurrences(of: "mul(vec4(0,0,0,1),g_ModelViewProjectionMatrixInverse).xyw", with: expression)
            #expect(!WPEShaderStageLink.usesMVPOnlyForFullscreenPosition(impure, fragment: fragment))
        }
        let indirect = "#define HIDDEN (counter++)\n" + vertex.replacingOccurrences(of: "vec4(0,0,0,1)", with: "vec4(HIDDEN,0,0,1)")
        #expect(!WPEShaderStageLink.usesMVPOnlyForFullscreenPosition(indirect, fragment: fragment))
        let macro = vertex.replacingOccurrences(of: "((b)*(a))", with: "((b)*(a)+(counter++))")
        #expect(!WPEShaderStageLink.usesMVPOnlyForFullscreenPosition(macro, fragment: fragment))
    }

    @Test func finalOrdinaryEffectProjectionUsesCoupledNormalizedPosition() throws {
        let fixture = try fixture(prewarmed: true, effectProjection: true)
        let output = try fixture.executor.render(pipeline: fixture.pipeline, size: CGSize(width: 4, height: 4), textures: [:])
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: output.pixelFormat, width: 4, height: 4, mipmapped: false)
        descriptor.storageMode = .shared
        let staging = try #require(fixture.device.makeTexture(descriptor: descriptor))
        let command = try #require(fixture.executor.textureSourceCommandQueue.makeCommandBuffer())
        let blit = try #require(command.makeBlitCommandEncoder())
        blit.copy(from: output, to: staging)
        blit.endEncoding(); command.commit(); command.waitUntilCompleted()
        #expect(command.error == nil)
        var pixels = [UInt8](repeating: 0, count: 64)
        pixels.withUnsafeMutableBytes { staging.getBytes($0.baseAddress!, bytesPerRow: 16, from: MTLRegionMake2D(0, 0, 4, 4), mipmapLevel: 0) }
        let bgra = output.pixelFormat == .bgra8Unorm || output.pixelFormat == .bgra8Unorm_srgb
        let srgb = output.pixelFormat == .rgba8Unorm_srgb || output.pixelFormat == .bgra8Unorm_srgb
        for y in 0 ..< 4 {
            for x in 0 ..< 4 {
                let expected = [0.25 + 0.5 * (Double(x) + 0.5) / 4, 0.75 - 0.5 * (Double(y) + 0.5) / 4].map { Int((255 * (srgb ? encode($0) : $0)).rounded()) }
                #expect(abs(Int(pixels[(y * 4 + x) * 4 + (bgra ? 2 : 0)]) - expected[0]) <= 1)
                #expect(abs(Int(pixels[(y * 4 + x) * 4 + 1]) - expected[1]) <= 1)
            }
        }
        let pass = fixture.pipeline.layers[0].passes[0]
        let layer = fixture.pipeline.layers[0].graphLayer
        let frame = WPEMetalFrameState(output: output, sceneSize: CGSize(width: 4, height: 4))
        let utility = WPERenderLayer(objectID: layer.objectID, objectName: layer.objectName, imagePath: "models/util/composelayer.json", materialPath: nil, geometry: layer.geometry, compositeA: layer.compositeA, compositeB: layer.compositeB, localFBOs: [], passes: layer.passes)
        #expect(fixture.executor.authoredVertexRejection(for: pass, result: fixture.result, layer: utility, frameState: frame, effectTextureProjection: { nil }) == .geometryUnavailable)
        var annotatedResult = fixture.result
        let vertex = try #require(annotatedResult.vertexStage)
        let annotatedLayout = vertex.uniformLayout.map { uniform in
            uniform.name == WPEMetalObjectUniforms.effectModelViewProjectionMatrixUniformName
                ? WPEUniformSlot(name: uniform.name, glslType: uniform.glslType, slot: uniform.slot, slotCount: uniform.slotCount,
                                 arrayLength: uniform.arrayLength, materialName: "projection", defaultValue: uniform.defaultValue)
                : uniform
        }
        annotatedResult.vertexStage = .init(library: vertex.library, mslSource: vertex.mslSource, uniformLayout: annotatedLayout,
                                            samplerNames: vertex.samplerNames, textureSlotCount: vertex.textureSlotCount)
        #expect(fixture.executor.authoredVertexRejection(for: pass, result: annotatedResult, layer: layer, frameState: frame, effectTextureProjection: { nil }) == .unverifiedEffectPositionContext)
        // A distinct following effect owns the final local output.
        let other = WPERenderPass(id: "other", phase: pass.pass.phase, shader: pass.pass.shader, source: pass.pass.source, target: pass.pass.target, textures: [:], binds: [:], constants: [:], combos: [:], blending: "disabled", cullMode: "nocull", depthTest: "disabled", depthWrite: "disabled")
        let intermediate = WPERenderLayer(objectID: layer.objectID, objectName: layer.objectName, imagePath: layer.imagePath, materialPath: nil, geometry: layer.geometry, compositeA: layer.compositeA, compositeB: layer.compositeB, localFBOs: [], passes: [pass.pass, other, layer.passes[1]])
        #expect(fixture.executor.authoredVertexRejection(for: pass, result: fixture.result, layer: intermediate, frameState: frame, effectTextureProjection: { nil }) == .unverifiedEffectPositionContext)
    }

    @Test func fullscreenInverseDeclarationDoesNotInventAConsumedProducer() throws {
        let fixture = try fixture(prewarmed: true)
        let vertex = try #require(fixture.result.vertexStage)
        let inverse = WPEUniformSlot(name: "g_ModelViewProjectionMatrixInverse", glslType: "mat4", slot: 0, slotCount: 4,
                                     arrayLength: nil, materialName: nil, defaultValue: nil)
        let pass = fixture.pipeline.layers[0].passes[0]
        let (_, sources) = try fixture.executor.withUniformSourceTracing {
            try fixture.executor.packTranslatedUniforms(for: pass, layout: [inverse], stage: .vertex, vertexExecution: .authoredFullscreen)
        }
        #expect(sources == [.unreferencedEngineDeclaration])
        let output = try fixture.executor.render(pipeline: fixture.pipeline, size: CGSize(width: 4, height: 4), textures: [:])
        var result = fixture.result
        result.vertexStage = .init(library: vertex.library, mslSource: vertex.mslSource, uniformLayout: [inverse],
                                   samplerNames: vertex.samplerNames, textureSlotCount: vertex.textureSlotCount)
        result.fullscreenMVPPositionOnly = false
        let frame = WPEMetalFrameState(output: output, sceneSize: CGSize(width: 4, height: 4))
        #expect(fixture.executor.authoredVertexRejection(for: pass, result: result, layer: fixture.pipeline.layers[0].graphLayer, frameState: frame, effectTextureProjection: { nil }) == .unverifiedFullscreenMVP)
    }

    @Test func effectMVPProofRestrictsPositionToProjectedXYW() {
        let declaration = "uniform mat4 g_ModelViewProjectionMatrix; uniform mat4 g_EffectModelViewProjectionMatrix; attribute vec3 a_Position;"
        let position = "gl_Position=mul(vec4(a_Position,1.0),g_ModelViewProjectionMatrix);"
        let effect = "v_View=mul(vec4(a_Position,1.0),g_EffectModelViewProjectionMatrix)"
        for channels in ["xy", "xyw"] {
            #expect(WPEShaderStageLink.usesMVPOnlyForFullscreenPosition(declaration + "void main(){" + position + effect + "." + channels + ";}"))
        }
        for extra in [effect + ".xyz;", effect + ";", "v_Raw=a_Position.xy;", "v_View=g_EffectModelViewProjectionMatrix[0].xy;"] {
            #expect(!WPEShaderStageLink.usesMVPOnlyForFullscreenPosition(declaration + "void main(){" + position + extra + "}"))
        }
    }

    @Test func recordedNativeClipMVPDoesNotClaimFullProjectionCoverage() {
        let uniform = WPEUniformSlot(name: "g_ModelViewProjectionMatrix", glslType: "mat4", slot: 0, slotCount: 4,
                                     arrayLength: nil, materialName: nil, defaultValue: nil)
        let coverage = WPEShaderSemanticCoverage.observedCustomDraw(passID: "draw", shaderName: "test", sourceClassification: nil,
                                                                    sourceFingerprint: nil, interface: nil, layout: [], sources: [],
                                                                    vertexLayout: [uniform], vertexSources: [.fullscreenVertexMVP], authoredVertexExecuted: true)
        #expect(coverage.entries.first { $0.feature == .uniformSupply && $0.stage == .vertex }?.status == .limited)
    }

    @Test func inheritedQuadAdmissionRequiresTheFullAffineProducerAndFlatPositivePlane() throws {
        let fixture = try fixture(prewarmed: true)
        let original = fixture.pipeline.layers[0].passes[0]
        let pass = WPEPreparedRenderPass(pass: original.pass.replacingTarget(.scene), shader: original.shader,
                                         textureBindings: [:], comboValues: [:], uniformValues: [:])
        let request = try #require(try WPEMetalRenderExecutor.makeCompileRequest(for: pass, recordFailure: false))
        let result = try fixture.executor.shaderCompiler.compile(request.replacingVertexExecution(.authoredObjectQuad))
        let geometry = WPERenderLayerGeometry(origin: SIMD3(20, 20, 0), scale: SIMD3(repeating: 1), angles: .zero, alignment: .center,
                                              size: CGSize(width: 10, height: 10), alpha: 1, color: SIMD3(repeating: 1), brightness: 1)
        let layer = WPERenderLayer(objectID: "child", objectName: "child", imagePath: "image", materialPath: nil,
                                   parentObjectID: "parent", geometry: geometry, localGeometry: geometry,
                                   compositeA: "a", compositeB: "b", localFBOs: [], passes: [pass.pass])
        let texture = try #require(fixture.device.makeTexture(descriptor: .texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 4, height: 4, mipmapped: false)))
        let frame = WPEMetalFrameState(output: texture, sceneSize: CGSize(width: 4, height: 4))
        func context(scale: SIMD3<Double> = SIMD3(repeating: 1), angles: SIMD3<Double> = .zero, verified: Bool) -> WPEFrameUniformContext {
            var value = WPEFrameUniformContext(runtimeUniformValues: [:], cameraUniformValues: WPEMetalCameraUniforms.identity.uniformValues,
                                               objectUniformValuesByPassID: [pass.id: WPEMetalObjectUniforms.uniformValues(origin: .zero, scale: scale, angles: angles)])
            if verified {
                value.affineModelMatrixPassIDs = [pass.id]
            }
            return value
        }
        fixture.executor.frameUniformContext = context(verified: false)
        #expect(fixture.executor.authoredVertexRejection(for: pass, result: result, layer: layer, frameState: frame, effectTextureProjection: { nil }) == .unverifiedInheritedObjectMatrix)
        fixture.executor.frameUniformContext = context(verified: true)
        #expect(fixture.executor.authoredVertexRejection(for: pass, result: result, layer: layer, frameState: frame, effectTextureProjection: { nil }) == nil)
        for value in [context(scale: SIMD3(-1, 1, 1), verified: true), context(angles: SIMD3(0.2, 0, 0), verified: true)] {
            fixture.executor.frameUniformContext = value
            #expect(fixture.executor.authoredVertexRejection(for: pass, result: result, layer: layer, frameState: frame, effectTextureProjection: { nil }) == .unverifiedInheritedObjectMatrix)
        }
    }

    @Test("Static root parallax keeps the captured positive and negative draw offsets", arguments: [0.5, -0.75])
    func staticRootParallaxDrawMVPMatchesWindows(amount: Double) throws {
        let fixture = try fixture(prewarmed: true)
        let original = fixture.pipeline.layers[0].passes[0]
        let pass = WPEPreparedRenderPass(pass: original.pass.replacingTarget(.scene), shader: original.shader,
                                         textureBindings: [:], comboValues: [:], uniformValues: [:])
        let request = try #require(try WPEMetalRenderExecutor.makeCompileRequest(for: pass, recordFailure: false))
        let result = try fixture.executor.shaderCompiler.compile(request.replacingVertexExecution(.authoredObjectQuad))
        fixture.executor.authoredShaderResultByPassID[pass.id] = result
        fixture.executor.seedTranslatedShaderCache([(request.replacingVertexExecution(.authoredObjectQuad).translationCacheKey, result)])
        let geometry = WPERenderLayerGeometry(origin: SIMD3(208, 84, 0), scale: SIMD3(1.2, 0.8, 1), angles: SIMD3(0, 0, 0.17),
                                              alignment: .center, size: CGSize(width: 192, height: 192), alpha: 1,
                                              color: SIMD3(repeating: 1), brightness: 1)
        let layer = WPERenderLayer(objectID: "root", objectName: "root", imagePath: "image", materialPath: nil, geometry: geometry,
                                   compositeA: "a", compositeB: "b", localFBOs: [], passes: [pass.pass], parallaxDepth: SIMD2(repeating: 1))
        let pipeline = WPEPreparedRenderPipeline(layers: [.init(graphLayer: layer, passes: [pass])])
        let camera = WPEMetalCameraUniforms(orthogonalProjection: .init(width: 384, height: 192, auto: false),
                                            sceneCamera: .defaultCamera, perspectiveOverrideFOVDegrees: 30)
        let runtime = WPEMetalRuntimeUniforms(time: 0, daytime: 0.5, brightness: 1, pointerPosition: SIMD2(repeating: 0.5))
        let base = pipeline.addingMetalRuntimeUniforms(runtime, camera: camera).frameUniforms
        var context = base
        fixture.executor.applyingAuthoredRootParallaxDrawProjection(to: &context, pipeline: pipeline, camera: camera,
                                                                    parallax: .init(smoothed: .zero, amount: amount, influence: 0), sceneSize: camera.renderSize)
        #expect(context.parallaxDrawMatrixPassIDs == [pass.id])
        let matrix = try #require(context.value(named: "g_ModelViewProjectionMatrix", passID: pass.id)?.vectorValue)
        let expectedX = amount > 0 ? 0.125 : 0.0208333731
        let expectedY = amount > 0 ? -0.1875 : -0.0312499404
        #expect(abs(matrix[12] - expectedX) < 0.000001 && abs(matrix[13] - expectedY) < 0.000001)
        #expect(context.value(named: "g_ModelMatrix", passID: pass.id) == base.value(named: "g_ModelMatrix", passID: pass.id))
        var dynamic = base
        fixture.executor.applyingAuthoredRootParallaxDrawProjection(to: &dynamic, pipeline: pipeline, camera: camera,
                                                                    parallax: .init(smoothed: SIMD2(0.25, -0.25), amount: amount, influence: 1), sceneSize: camera.renderSize)
        #expect(dynamic.parallaxDrawMatrixPassIDs.isEmpty)
    }

    @Test("Static parallax VS truth does not admit unmeasured fragment model inputs",
          arguments: ["g_ModelMatrix", "g_ModelViewProjectionMatrix", "g_LayerTransform"])
    func staticParallaxRejectsFragmentModelInputs(name: String) throws {
        let fixture = try fixture(prewarmed: true)
        let original = fixture.pipeline.layers[0].passes[0]
        let source = try #require(original.shader)
        let program = WPEShaderProgram(name: "parallax-fragment-owner", vertexSource: source.vertexSource,
                                       fragmentSource: """
                                       uniform mat4 \(name);
                                       varying vec4 v_TexCoord;
                                       void main() {
                                           gl_FragColor = vec4(v_TexCoord.zw, 0, 1) + \(name)[0] * 0.00001;
                                       }
                                       """,
                                       isBuiltin: false)
        let pass = WPEPreparedRenderPass(pass: original.pass.replacingTarget(.scene), shader: program,
                                         textureBindings: [:], comboValues: [:], uniformValues: [:])
        let request = try #require(try WPEMetalRenderExecutor.makeCompileRequest(for: pass, recordFailure: false))
        let result = try fixture.executor.shaderCompiler.compile(request.replacingVertexExecution(.authoredObjectQuad))
        #expect(result.uniformLayout.contains { $0.name == name && $0.materialName == nil })
        let geometry = WPERenderLayerGeometry(origin: SIMD3(20, 20, 0), scale: SIMD3(repeating: 1), angles: .zero, alignment: .center,
                                              size: CGSize(width: 10, height: 10), alpha: 1, color: SIMD3(repeating: 1), brightness: 1)
        let layer = WPERenderLayer(objectID: "root", objectName: "root", imagePath: "image", materialPath: nil, geometry: geometry,
                                   compositeA: "a", compositeB: "b", localFBOs: [], passes: [pass.pass], parallaxDepth: SIMD2(repeating: 1))
        let texture = try #require(fixture.device.makeTexture(descriptor: .texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 4, height: 4, mipmapped: false)))
        var frame = WPEMetalFrameState(output: texture, sceneSize: CGSize(width: 4, height: 4))
        frame.cameraParallax = .init(smoothed: .zero, amount: 0.5, influence: 0)
        fixture.executor.frameUniformContext.parallaxDrawMatrixPassIDs = [pass.id]
        let rejection = fixture.executor.authoredVertexRejection(for: pass, result: result, layer: layer, frameState: frame, effectTextureProjection: { nil })
        #expect(rejection == .unverifiedObjectQuadSpace)
    }

    @Test func serializedDefaultClipPlanesRetainCapturedProjection() {
        func camera(near: Double) -> WPEMetalCameraUniforms {
            .init(orthogonalProjection: .init(width: 7680, height: 4320, auto: false),
                  sceneCamera: .init(center: SIMD3(0, 0, -1), eye: .zero, up: SIMD3(0, 1, 0),
                                     nearZ: near, farZ: 10000, fov: 50))
        }
        #expect(camera(near: 0.0099999998).hasCapturedFlatDrawProjection)
        #expect(camera(near: 0.0099999998).hasCapturedOrthographicShaderGlobals)
        #expect(!camera(near: 0.02).hasCapturedFlatDrawProjection)
        #expect(!camera(near: .nan).hasCapturedFlatDrawProjection)
    }

    @Test func rootShapeQuadSuppliesPointPositionsUVAndIndependentDrawMVP() throws {
        let points = [SIMD2<Double>(0.15, 0.1), SIMD2(0.85, 0.2), SIMD2(0.75, 0.9), SIMD2(0.2, 0.8)]
        let geometry = WPERenderLayerGeometry(origin: SIMD3(208, 84, 0), scale: SIMD3(1.2, 0.8, 1),
                                              angles: SIMD3(0, 0, 0.17), alignment: .center, size: CGSize(width: 192, height: 192),
                                              alpha: 1, color: SIMD3(repeating: 1), brightness: 1, shapePoints: points)
        let layer = WPERenderLayer(objectID: "shape", objectName: "shape", imagePath: "models/util/solidlayer.json",
                                   materialPath: nil, geometry: geometry, compositeA: "a", compositeB: "b", localFBOs: [], passes: [])
        let camera = WPEMetalCameraUniforms(orthogonalProjection: .init(width: 384, height: 192, auto: false),
                                            sceneCamera: .defaultCamera, perspectiveOverrideFOVDegrees: 30)
        #expect(!camera.hasCapturedOrthographicShaderGlobals)
        #expect(WPEMetalRenderExecutor.canSupplyAuthoredObjectQuad(layer: layer, camera: camera))
        let inputs = WPEMetalRenderExecutor.authoredObjectQuadInputs(layer: layer)
        for (index, pointIndex) in [0, 2, 1, 0, 3, 2].enumerated() {
            #expect(abs(inputs[index].x - Float((points[pointIndex].x - 0.5) * 192)) < 0.00001)
            #expect(abs(inputs[index].y - Float((0.5 - points[pointIndex].y) * 192)) < 0.00001)
            #expect(inputs[index].z == Float(points[pointIndex].x))
            #expect(inputs[index].w == Float(points[pointIndex].y))
        }
        let model = WPEMetalObjectUniforms.uniformValues(origin: geometry.origin, scale: geometry.scale, angles: geometry.angles)
        var context = WPEFrameUniformContext(runtimeUniformValues: [:], cameraUniformValues: camera.uniformValues,
                                             objectUniformValuesByPassID: ["shape.0": model])
        let globalVP = context.value(named: "g_ViewProjectionMatrix", passID: "shape.0")
        context.drawViewProjectionMatrixByPassID["shape.0"] = .vector(camera.shaderDrawViewProjectionMatrix(objectID: layer.id))
        let mvp = try #require(context.value(named: "g_ModelViewProjectionMatrix", passID: "shape.0")?.vectorValue)
        let expected = [0.0061599053, 0.0021147795, 0, 0, -0.0007049264, 0.0082132071, 0, 0, 0, 0, 0.00025, 0, 0.0833333731, -0.125, 0.5, 1]
        for (actual, oracle) in zip(mvp, expected) {
            #expect(abs(actual - oracle) < 0.000001)
        }
        #expect(context.value(named: "g_ViewProjectionMatrix", passID: "shape.0") == globalVP)
        let perspective = WPEMetalCameraUniforms(orthogonalProjection: .init(width: 384, height: 192, auto: false),
                                                 sceneCamera: .defaultCamera, perspectiveOverrideFOVDegrees: 30,
                                                 perspectiveObjectIDs: [layer.id])
        #expect(!WPEMetalRenderExecutor.canSupplyAuthoredObjectQuad(layer: layer, camera: perspective))
    }

    @Test("Measured quad draw projection preserves native and unsupported geometry owners",
          arguments: ["authored", "builtin", "nonplanar"])
    func measuredDrawProjectionKeepsExistingOwners(kind: String) throws {
        let fixture = try fixture(prewarmed: true)
        let original = fixture.pipeline.layers[0].passes[0]
        let shader = kind == "builtin"
            ? WPEShaderProgram(name: "commands/copy", vertexSource: "", fragmentSource: "", isBuiltin: true)
            : original.shader
        let pass = WPEPreparedRenderPass(pass: original.pass.replacingTarget(.scene), shader: shader,
                                         textureBindings: [:], comboValues: [:], uniformValues: [:])
        if kind == "authored" {
            let request = try #require(try WPEMetalRenderExecutor.makeCompileRequest(for: pass, recordFailure: false))
            let result = try fixture.executor.shaderCompiler.compile(request.replacingVertexExecution(.authoredObjectQuad))
            fixture.executor.authoredShaderResultByPassID[pass.id] = result
            fixture.executor.seedTranslatedShaderCache([(request.replacingVertexExecution(.authoredObjectQuad).translationCacheKey, result)])
        }
        let geometry = WPERenderLayerGeometry(origin: SIMD3(208, 84, kind == "nonplanar" ? 10 : 0),
                                              scale: SIMD3(1.2, 0.8, 1), angles: SIMD3(0, 0, 0.17),
                                              alignment: .center, size: CGSize(width: 192, height: 192),
                                              alpha: 1, color: SIMD3(repeating: 1), brightness: 1)
        let layer = WPERenderLayer(objectID: "root", objectName: "root", imagePath: "image", materialPath: nil,
                                   geometry: geometry, compositeA: "a", compositeB: "b", localFBOs: [],
                                   passes: [pass.pass], parallaxDepth: SIMD2(repeating: 1))
        let pipeline = WPEPreparedRenderPipeline(layers: [.init(graphLayer: layer, passes: [pass])])
        let camera = WPEMetalCameraUniforms(orthogonalProjection: .init(width: 384, height: 192, auto: false),
                                            sceneCamera: .defaultCamera, perspectiveOverrideFOVDegrees: 30)
        let runtime = WPEMetalRuntimeUniforms(time: 0, daytime: 0.5, brightness: 1, pointerPosition: SIMD2(repeating: 0.5))
        var context = pipeline.addingMetalRuntimeUniforms(runtime, camera: camera).frameUniforms
        if kind == "authored" {
            #expect(context.drawViewProjectionMatrixByPassID[pass.id] != nil)
        } else {
            #expect(context.drawViewProjectionMatrixByPassID[pass.id] == nil)
            let model = WPEMetalObjectUniforms.uniformValues(origin: geometry.origin, scale: geometry.scale, angles: geometry.angles)
            let previous = WPEFrameUniformContext(runtimeUniformValues: [:], cameraUniformValues: camera.uniformValues,
                                                  objectUniformValuesByPassID: [pass.id: model])
            #expect(context.value(named: "g_ModelViewProjectionMatrix", passID: pass.id)
                == previous.value(named: "g_ModelViewProjectionMatrix", passID: pass.id))
        }
        fixture.executor.applyingAuthoredRootParallaxDrawProjection(to: &context, pipeline: pipeline, camera: camera,
                                                                    parallax: .init(smoothed: .zero, amount: 0.5, influence: 0),
                                                                    sceneSize: camera.renderSize)
        #expect(context.parallaxDrawMatrixPassIDs.contains(pass.id) == (kind == "authored"))
    }

    @Test func vertexSkewDoesNotOverwriteAuthoredObjectQuadInputs() throws {
        func render(skew: Bool) throws -> (pixels: [UInt8], format: MTLPixelFormat) {
            let fixture = try fixture(prewarmed: true)
            let original = fixture.pipeline.layers[0].passes[0]
            let constants: [String: WPESceneShaderConstantValue] = skew
                ? ["top": .number(0.25), "bottom": .number(0.25), "left": .number(0.25), "right": .number(0.25)] : [:]
            let authored = WPERenderPass(id: "skew", phase: original.pass.phase, shader: "effects/skew", source: original.pass.source,
                                         target: .scene, textures: [:], binds: [:], constants: constants, combos: ["MODE": 1],
                                         blending: "disabled", cullMode: "nocull", depthTest: "disabled", depthWrite: "disabled")
            let pass = WPEPreparedRenderPass(pass: authored, shader: original.shader, textureBindings: [:], comboValues: [:], uniformValues: [:])
            let geometry = WPERenderLayerGeometry(origin: SIMD3(2, 2, 0), scale: SIMD3(repeating: 1), angles: .zero, alignment: .center,
                                                  size: CGSize(width: 2, height: 2), alpha: 1, color: SIMD3(repeating: 1), brightness: 1)
            let layer = WPERenderLayer(objectID: "skew", objectName: "skew", imagePath: "image", materialPath: nil, geometry: geometry,
                                       compositeA: "a", compositeB: "b", localFBOs: [], passes: [authored])
            let pipeline = WPEPreparedRenderPipeline(layers: [.init(graphLayer: layer, passes: [pass])])
            let camera = WPEMetalCameraUniforms(orthogonalProjection: .init(width: 4, height: 4, auto: false), sceneCamera: .defaultCamera)
            #expect(fixture.executor.isVertexSkewPass(pass) == skew)
            #expect(WPEMetalRenderExecutor.canSupplyAuthoredObjectQuad(layer: layer, camera: camera))
            let request = try #require(try WPEMetalRenderExecutor.makeCompileRequest(for: pass, recordFailure: false))
            let result = try fixture.executor.shaderCompiler.compile(request.replacingVertexExecution(.authoredObjectQuad))
            fixture.executor.authoredShaderResultByPassID[pass.id] = result
            fixture.executor.seedTranslatedShaderCache([(request.replacingVertexExecution(.authoredObjectQuad).translationCacheKey, result)])
            let alpha = WPEMetalAlphaWritePolicy.resolve(targetID: WPEMetalTargetID(target: .scene), blendMode: "disabled")
            let prewarm = WPEMetalRenderExecutor.WPETranslatedPipelinePrewarm(device: fixture.device, defaultLibrary: fixture.executor.defaultLibrary,
                                                                              result: result, vertexName: nil, blendMode: "disabled", alphaWritePolicy: alpha,
                                                                              colorPixelFormat: WPEMetalRenderExecutor.outputPixelFormat, depthPixelFormat: .invalid)
            let compiled = try #require(WPEMetalRenderExecutor.buildTranslatedPipeline(prewarm))
            fixture.executor.seedTranslatedPipelines([compiled])
            let output = try fixture.executor.render(pipeline: pipeline, size: CGSize(width: 4, height: 4), textures: [:], cameraUniforms: camera)
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: output.pixelFormat, width: 4, height: 4, mipmapped: false)
            descriptor.storageMode = .shared
            let staging = try #require(fixture.device.makeTexture(descriptor: descriptor))
            let command = try #require(fixture.executor.textureSourceCommandQueue.makeCommandBuffer())
            let blit = try #require(command.makeBlitCommandEncoder())
            blit.copy(from: output, to: staging)
            blit.endEncoding(); command.commit(); command.waitUntilCompleted()
            #expect(command.error == nil)
            var pixels = [UInt8](repeating: 0, count: 64)
            pixels.withUnsafeMutableBytes { staging.getBytes($0.baseAddress!, bytesPerRow: 16, from: MTLRegionMake2D(0, 0, 4, 4), mipmapLevel: 0) }
            return (pixels, output.pixelFormat)
        }
        let plain = try render(skew: false)
        let srgb = plain.format == .rgba8Unorm_srgb || plain.format == .bgra8Unorm_srgb
        let bgra = plain.format == .bgra8Unorm_srgb || plain.format == .bgra8Unorm
        let band = [0.4375, 0.5625].map { Int((255 * (srgb ? encode($0) : $0)).rounded()) }
        for (x, y) in [(1, 1), (2, 1), (1, 2), (2, 2)] {
            let red = Int(plain.pixels[(y * 4 + x) * 4 + (bgra ? 2 : 0)])
            #expect(band.contains { abs($0 - red) <= 1 })
        }
        #expect(try render(skew: true).pixels == plain.pixels)
    }

    @Test("Object quad admission accepts finite authored pixel origins at unit boundaries",
          arguments: [SIMD3<Double>(-0.5, 120, 0), SIMD3<Double>(0.5, 0.5, 0), SIMD3<Double>(0, 120, 0),
                      SIMD3<Double>(1, 1, 0), SIMD3<Double>(1.01, 12.375, 0), SIMD3<Double>(208, 84, 0)])
    func objectQuadAdmissionAcceptsPixelOrigins(origin: SIMD3<Double>) {
        let geometry = WPERenderLayerGeometry(origin: origin, scale: SIMD3(repeating: 1), angles: .zero, alignment: .center,
                                              size: CGSize(width: 192, height: 192), alpha: 1, color: SIMD3(repeating: 1), brightness: 1)
        let layer = WPERenderLayer(objectID: "root", objectName: "root", imagePath: "image", materialPath: nil, geometry: geometry,
                                   compositeA: "a", compositeB: "b", localFBOs: [], passes: [])
        let camera = WPEMetalCameraUniforms(orthogonalProjection: .init(width: 384, height: 192, auto: false), sceneCamera: .defaultCamera)
        #expect(WPEMetalRenderExecutor.canSupplyAuthoredObjectQuad(layer: layer, camera: camera))
    }

    @Test("Fallback, model matrix and hit testing share authored pixel origins",
          arguments: [-0.5, 0, 0.5, 1, 1.01, 12.375])
    func pixelOriginConsumersAgree(value: Double) throws {
        let scene = CGSize(width: 256, height: 128)
        let origin = SIMD3<Double>(value, value, 0)
        let geometry = WPERenderLayerGeometry(origin: origin, scale: SIMD3(repeating: 1), angles: .zero,
                                              alignment: .center, size: CGSize(width: 32, height: 32),
                                              alpha: 1, color: SIMD3(repeating: 1), brightness: 1)
        let centered = WPEMetalRenderExecutor.centeredOrigin(of: geometry, sceneSize: scene)
        #expect(abs(Double(centered.x) - (value - 128)) < 0.00001)
        #expect(abs(Double(centered.y) - (value - 64)) < 0.00001)
        let model = WPEMetalObjectUniforms.modelMatrix(origin: origin, scale: geometry.scale, angles: geometry.angles)
        #expect(model.columns.3 == SIMD4(value, value, 0, 1))
        let hit = try #require(WPEMetalSceneRenderer.hoverHitRect(geometry: geometry, sceneSize: scene, projection: nil))
        #expect(hit.center == SIMD2(value, 128 - value))
    }

    @Test("A singular root still supplies its raw geometry for shader execution",
          arguments: [SIMD3<Double>(0, 1, 1), SIMD3<Double>(1, 0, 1)])
    func singularRootSuppliesRawGeometry(scale: SIMD3<Double>) {
        let geometry = WPERenderLayerGeometry(origin: SIMD3(0.5, 0.5, 0), scale: scale, angles: .zero,
                                              alignment: .center, size: CGSize(width: 32, height: 32),
                                              alpha: 1, color: SIMD3(repeating: 1), brightness: 1)
        let layer = WPERenderLayer(objectID: "root", objectName: "root", imagePath: "image", materialPath: nil,
                                   geometry: geometry, compositeA: "a", compositeB: "b", localFBOs: [], passes: [])
        let camera = WPEMetalCameraUniforms(orthogonalProjection: .init(width: 256, height: 128, auto: false), sceneCamera: .defaultCamera)
        #expect(WPEMetalRenderExecutor.canSupplyAuthoredObjectQuad(layer: layer, camera: camera))
    }

    @Test("Signed root inputs retain authored coordinates and captured ordinary-quad topology",
          arguments: [SIMD3<Double>(-1.2, 0.8, 1), SIMD3<Double>(1.2, -0.8, 1), SIMD3<Double>(-1.2, -0.8, 1),
                      SIMD3<Double>(-0.00001, 0.8, 1), SIMD3<Double>(0.00001, 0.8, 1)])
    func signedRootQuadMatchesCapturedMatrixAndInputs(scale: SIMD3<Double>) throws {
        let geometry = WPERenderLayerGeometry(origin: SIMD3(144, 52, 0), scale: scale, angles: SIMD3(0, 0, 0.17),
                                              alignment: .center, size: CGSize(width: 160, height: 96),
                                              alpha: 1, color: SIMD3(repeating: 1), brightness: 1)
        let layer = WPERenderLayer(objectID: "root", objectName: "root", imagePath: "image", materialPath: nil,
                                   geometry: geometry, compositeA: "a", compositeB: "b", localFBOs: [], passes: [])
        let camera = WPEMetalCameraUniforms(orthogonalProjection: .init(width: 256, height: 128, auto: false), sceneCamera: .defaultCamera)
        #expect(WPEMetalRenderExecutor.canSupplyAuthoredObjectQuad(layer: layer, camera: camera))
        #expect(WPEMetalRenderExecutor.authoredObjectQuadInputs(layer: layer) == [
            SIMD4<Float>(-80, 48, 0, 0), SIMD4(-80, -48, 0, 1), SIMD4(80, 48, 1, 0),
            SIMD4(80, 48, 1, 0), SIMD4(-80, -48, 0, 1), SIMD4(80, -48, 1, 1),
        ])
        var context = WPEFrameUniformContext(runtimeUniformValues: [:], cameraUniformValues: camera.uniformValues,
                                             objectUniformValuesByPassID: ["root.0": WPEMetalObjectUniforms.uniformValues(origin: geometry.origin, scale: scale, angles: geometry.angles)])
        context.drawViewProjectionMatrixByPassID["root.0"] = .vector(camera.shaderDrawViewProjectionMatrix(objectID: layer.id))
        let matrix = try #require(context.value(named: "g_ModelViewProjectionMatrix", passID: "root.0")?.vectorValue)
        let captured = [0.009239858016371727 * scale.x / 1.2, 0.003172169206663966 * scale.x / 1.2, 0, 0,
                        -0.0010573896579444408 * scale.y / 0.8, 0.012319809757173061 * scale.y / 0.8, 0, 0,
                        0, 0, 0.0002500000118743628, 0, 0.125, -0.1875, 0.5, 1]
        for (actual, expected) in zip(matrix, captured) {
            #expect(abs(actual - expected) < 0.00000001)
        }
    }

    @Test("Signed admission stays bounded to measured root rectangles and cull modes",
          arguments: ["shape", "bare-shape", "parent", "front", "normal", "zero-parent", "zero-shape", "nonfinite", "underflow"])
    func signedRootAdmissionKeepsUnmeasuredContextsGuarded(scope: String) {
        let scale = scope.hasPrefix("zero") ? SIMD3<Double>(0, 1, 1)
            : scope == "nonfinite" ? SIMD3<Double>(-.infinity, 1, 1)
            : scope == "underflow" ? SIMD3<Double>(-Double.leastNonzeroMagnitude, 1, 1) : SIMD3<Double>(-1, 1, 1)
        let geometry = WPERenderLayerGeometry(origin: SIMD3(144, 52, 0), scale: scale, angles: .zero,
                                              alignment: .center, size: CGSize(width: 160, height: 96), alpha: 1, color: SIMD3(repeating: 1), brightness: 1,
                                              shapePoints: ["shape", "zero-shape"].contains(scope) ? [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)] : nil)
        let pass = WPERenderPass(id: "draw", phase: .material, shader: "probe", source: .asset("unused"), target: .scene,
                                 textures: [:], binds: [:], constants: [:], combos: [:], blending: "disabled",
                                 cullMode: ["front", "normal"].contains(scope) ? scope : "nocull", depthTest: "disabled", depthWrite: "disabled")
        let layer = WPERenderLayer(objectID: "root", objectName: "root", imagePath: "image", materialPath: nil,
                                   parentObjectID: ["parent", "zero-parent"].contains(scope) ? "parent" : nil,
                                   authoredJSON: scope == "bare-shape" ? .init(sceneObjects: [.object(["shape": .string("quad")])]) : .empty,
                                   geometry: geometry, localGeometry: geometry,
                                   compositeA: "a", compositeB: "b", localFBOs: [], passes: [pass])
        let camera = WPEMetalCameraUniforms(orthogonalProjection: .init(width: 256, height: 128, auto: false), sceneCamera: .defaultCamera)
        #expect(!WPEMetalRenderExecutor.canSupplyAuthoredObjectQuad(layer: layer, camera: camera))
    }

    @Test("Bare authored shapes retain their captured diagonal without active gizmo points")
    func bareShapeQuadKeepsShapeTopology() {
        let geometry = WPERenderLayerGeometry(origin: SIMD3(144, 52, 0), scale: SIMD3(repeating: 1), angles: .zero,
                                              alignment: .center, size: CGSize(width: 160, height: 96), alpha: 1, color: SIMD3(repeating: 1), brightness: 1)
        let layer = WPERenderLayer(objectID: "shape", objectName: "shape", imagePath: "models/util/solidlayer.json", materialPath: nil,
                                   authoredJSON: .init(sceneObjects: [.object(["shape": .string("quad")])]), geometry: geometry,
                                   compositeA: "a", compositeB: "b", localFBOs: [], passes: [])
        #expect(WPEMetalRenderExecutor.authoredObjectQuadInputs(layer: layer) == [
            SIMD4<Float>(-80, 48, 0, 0), SIMD4(80, -48, 1, 1), SIMD4(80, 48, 1, 0),
            SIMD4(-80, 48, 0, 0), SIMD4(-80, -48, 0, 1), SIMD4(80, -48, 1, 1),
        ])
    }

    @Test("Signed and singular rotated roots execute the shader with fixed counterclockwise culling",
          arguments: [(1.0, 1.0, "back", 4), (-1.0, 1.0, "back", 0), (1.0, -1.0, "back", 0),
                      (-1.0, -1.0, "back", 4), (-1.0, 1.0, "nocull", 4), (1.0, -1.0, "nocull", 4),
                      (-0.00001, 1.0, "nocull", 0), (0.0, 1.0, "nocull", 0), (1.0, 0.0, "nocull", 0),
                      (0.0, 0.0, "nocull", 4)])
    func signedRootRasterizationKeepsCapturedCulling(scaleX: Double, scaleY: Double, cull: String, visiblePixels: Int) throws {
        let fixture = try fixture(prewarmed: true)
        let original = fixture.pipeline.layers[0].passes[0]
        let authored = WPERenderPass(id: "signed", phase: .material, shader: "signed-probe", source: .asset("unused"), target: .scene,
                                     textures: [:], binds: [:], constants: [:], combos: [:], blending: "disabled", cullMode: cull,
                                     depthTest: "disabled", depthWrite: "disabled")
        let source = try #require(original.shader)
        // A shader may restore area after the singular MVP, so zero scale must not skip the draw.
        let vertex = scaleX == 0 && scaleY == 0 ? source.vertexSource.replacingOccurrences(
            of: "v_TexCoord = vec4", with: "gl_Position.xy += 0.5 * a_Position.xy; v_TexCoord = vec4"
        ) : source.vertexSource
        let shader = WPEShaderProgram(name: source.name, vertexSource: vertex, fragmentSource: source.fragmentSource, isBuiltin: false)
        let pass = WPEPreparedRenderPass(pass: authored, shader: shader, textureBindings: [:], comboValues: [:], uniformValues: [:])
        let geometry = WPERenderLayerGeometry(origin: SIMD3(2, 2, 0), scale: SIMD3(scaleX, scaleY, 1), angles: SIMD3(0, 0, 0.17),
                                              alignment: .center, size: CGSize(width: 2, height: 2), alpha: 1, color: SIMD3(repeating: 1), brightness: 1)
        let layer = WPERenderLayer(objectID: "signed", objectName: "signed", imagePath: "image", materialPath: nil, geometry: geometry,
                                   compositeA: "a", compositeB: "b", localFBOs: [], passes: [authored], parallaxDepth: SIMD2(repeating: 1))
        let pipeline = WPEPreparedRenderPipeline(layers: [.init(graphLayer: layer, passes: [pass])])
        let camera = WPEMetalCameraUniforms(orthogonalProjection: .init(width: 4, height: 4, auto: false), sceneCamera: .defaultCamera)
        #expect(WPEMetalRenderExecutor.canSupplyAuthoredObjectQuad(layer: layer, camera: camera))
        let request = try #require(try WPEMetalRenderExecutor.makeCompileRequest(for: pass, recordFailure: false))
        let result = try fixture.executor.shaderCompiler.compile(request.replacingVertexExecution(.authoredObjectQuad))
        fixture.executor.authoredShaderResultByPassID[pass.id] = result
        fixture.executor.seedTranslatedShaderCache([(request.replacingVertexExecution(.authoredObjectQuad).translationCacheKey, result)])
        let prewarm = WPEMetalRenderExecutor.WPETranslatedPipelinePrewarm(device: fixture.device, defaultLibrary: fixture.executor.defaultLibrary,
                                                                          result: result, vertexName: nil, blendMode: "disabled",
                                                                          alphaWritePolicy: WPEMetalAlphaWritePolicy.resolve(targetID: WPEMetalTargetID(target: .scene), blendMode: "disabled"),
                                                                          colorPixelFormat: WPEMetalRenderExecutor.outputPixelFormat, depthPixelFormat: .invalid)
        try fixture.executor.seedTranslatedPipelines([#require(WPEMetalRenderExecutor.buildTranslatedPipeline(prewarm))])
        let output = try fixture.executor.render(pipeline: pipeline, size: CGSize(width: 4, height: 4), textures: [:], cameraUniforms: camera)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: output.pixelFormat, width: 4, height: 4, mipmapped: false)
        descriptor.storageMode = .shared
        let staging = try #require(fixture.device.makeTexture(descriptor: descriptor))
        let command = try #require(fixture.executor.textureSourceCommandQueue.makeCommandBuffer())
        let blit = try #require(command.makeBlitCommandEncoder())
        blit.copy(from: output, to: staging)
        blit.endEncoding(); command.commit(); command.waitUntilCompleted()
        #expect(command.error == nil)
        var pixels = [UInt8](repeating: 0, count: 64)
        pixels.withUnsafeMutableBytes { staging.getBytes($0.baseAddress!, bytesPerRow: 16, from: MTLRegionMake2D(0, 0, 4, 4), mipmapLevel: 0) }
        #expect(stride(from: 0, to: 64, by: 4).filter { pixels[$0 + 1] > 0 }.count == visiblePixels)
        if scaleX <= 0 || scaleY <= 0 {
            let runtime = WPEMetalRuntimeUniforms(time: 0, daytime: 0.5, brightness: 1, pointerPosition: SIMD2(repeating: 0.5))
            var context = pipeline.addingMetalRuntimeUniforms(runtime, camera: camera).frameUniforms
            fixture.executor.applyingAuthoredRootParallaxDrawProjection(to: &context, pipeline: pipeline, camera: camera,
                                                                        parallax: .init(smoothed: .zero, amount: 0.5, influence: 0), sceneSize: camera.renderSize)
            #expect(context.parallaxDrawMatrixPassIDs.isEmpty)
            fixture.executor.frameUniformContext = context
            var activeParallax = WPEMetalFrameState(output: output, sceneSize: camera.renderSize, cameraUniforms: camera)
            activeParallax.cameraParallax = .init(smoothed: .zero, amount: 0.5, influence: 0)
            #expect(fixture.executor.authoredVertexRejection(for: pass, result: result, layer: layer,
                                                             frameState: activeParallax, effectTextureProjection: { nil }) == .unverifiedObjectQuadSpace)
        }
    }

    @Test("Singular authored roots reject unverified inverse and normal inputs in either stage",
          arguments: ["g_ModelMatrixInverse", "g_ModelViewProjectionMatrixInverse", "g_NormalModelMatrix"], [false, true])
    func singularRootRejectsInverseConsumers(name: String, fragment: Bool) throws {
        let fixture = try fixture(prewarmed: true)
        let original = fixture.pipeline.layers[0].passes[0]
        let source = try #require(original.shader)
        let declaration = "uniform \(name == "g_NormalModelMatrix" ? "mat3" : "mat4") \(name);\n"
        let vertexSource = fragment ? source.vertexSource : declaration + source.vertexSource.replacingOccurrences(
            of: "v_TexCoord =", with: "gl_Position.x += \(name)[0][0];\n    v_TexCoord ="
        )
        let fragmentSource = fragment ? declaration + source.fragmentSource.replacingOccurrences(
            of: "gl_FragColor =", with: "gl_FragColor = vec4(\(name)[0][0]) +"
        ) : source.fragmentSource
        let program = WPEShaderProgram(name: "singular-inverse", vertexSource: vertexSource,
                                       fragmentSource: fragmentSource, isBuiltin: false)
        let pass = WPEPreparedRenderPass(pass: original.pass.replacingTarget(.scene), shader: program,
                                         textureBindings: [:], comboValues: [:], uniformValues: [:])
        let request = try #require(try WPEMetalRenderExecutor.makeCompileRequest(for: pass, recordFailure: false))
        let result = try fixture.executor.shaderCompiler.compile(request.replacingVertexExecution(.authoredObjectQuad))
        let vertex = try #require(result.vertexStage)
        #expect((fragment ? result.uniformLayout : vertex.uniformLayout).contains { $0.name == name && $0.materialName == nil })
        let geometry = WPERenderLayerGeometry(origin: SIMD3(2, 2, 0), scale: SIMD3(1, 0, 1), angles: SIMD3(0, 0, 0.17),
                                              alignment: .center, size: CGSize(width: 2, height: 2), alpha: 1, color: SIMD3(repeating: 1), brightness: 1)
        let layer = WPERenderLayer(objectID: "singular", objectName: "singular", imagePath: "image", materialPath: nil,
                                   geometry: geometry, compositeA: "a", compositeB: "b", localFBOs: [], passes: [pass.pass])
        let camera = WPEMetalCameraUniforms(orthogonalProjection: .init(width: 4, height: 4, auto: false), sceneCamera: .defaultCamera)
        let output = try #require(fixture.device.makeTexture(descriptor: .texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 4, height: 4, mipmapped: false)))
        let frame = WPEMetalFrameState(output: output, sceneSize: camera.renderSize, cameraUniforms: camera)
        #expect(fixture.executor.authoredVertexRejection(for: pass, result: result, layer: layer,
                                                         frameState: frame, effectTextureProjection: { nil }) == .invalidMatrix(name))
        if !fragment {
            #expect(result.shaderInterface?.isVertexUniformProvenUnreferenced(name) == false)
            let unusedProgram = WPEShaderProgram(name: "singular-unused-inverse", vertexSource: declaration + source.vertexSource,
                                                 fragmentSource: source.fragmentSource, isBuiltin: false)
            let unusedPass = WPEPreparedRenderPass(pass: pass.pass, shader: unusedProgram,
                                                   textureBindings: [:], comboValues: [:], uniformValues: [:])
            let unusedRequest = try #require(try WPEMetalRenderExecutor.makeCompileRequest(for: unusedPass, recordFailure: false))
            let unusedResult = try fixture.executor.shaderCompiler.compile(unusedRequest.replacingVertexExecution(.authoredObjectQuad))
            let pipeline = WPEPreparedRenderPipeline(layers: [.init(graphLayer: layer, passes: [unusedPass])])
            let runtime = WPEMetalRuntimeUniforms(time: 0, daytime: 0.5, brightness: 1, pointerPosition: SIMD2(repeating: 0.5))
            fixture.executor.frameUniformContext = pipeline.addingMetalRuntimeUniforms(runtime, camera: camera).frameUniforms
            #expect(unusedResult.shaderInterface?.isVertexUniformProvenUnreferenced(name) == true)
            #expect(fixture.executor.authoredVertexRejection(for: unusedPass, result: unusedResult, layer: layer,
                                                             frameState: frame, effectTextureProjection: { nil }) == nil)
        }
    }

    @Test func parallaxDrawProjectionSkipsPassesWhoseFragmentReadsModelInputs() throws {
        let fixture = try fixture(prewarmed: true)
        let original = fixture.pipeline.layers[0].passes[0]
        let source = try #require(original.shader)
        let program = WPEShaderProgram(name: "parallax-fragment-mvp", vertexSource: source.vertexSource,
                                       fragmentSource: """
                                       uniform mat4 g_ModelViewProjectionMatrix;
                                       varying vec4 v_TexCoord;
                                       void main() {
                                           gl_FragColor = vec4(v_TexCoord.zw, 0, 1) + g_ModelViewProjectionMatrix[0] * 0.00001;
                                       }
                                       """,
                                       isBuiltin: false)
        let pass = WPEPreparedRenderPass(pass: original.pass.replacingTarget(.scene), shader: program,
                                         textureBindings: [:], comboValues: [:], uniformValues: [:])
        let request = try #require(try WPEMetalRenderExecutor.makeCompileRequest(for: pass, recordFailure: false))
        let result = try fixture.executor.shaderCompiler.compile(request.replacingVertexExecution(.authoredObjectQuad))
        fixture.executor.authoredShaderResultByPassID[pass.id] = result
        fixture.executor.seedTranslatedShaderCache([(request.replacingVertexExecution(.authoredObjectQuad).translationCacheKey, result)])
        let geometry = WPERenderLayerGeometry(origin: SIMD3(208, 84, 0), scale: SIMD3(1.2, 0.8, 1), angles: SIMD3(0, 0, 0.17),
                                              alignment: .center, size: CGSize(width: 192, height: 192), alpha: 1,
                                              color: SIMD3(repeating: 1), brightness: 1)
        let layer = WPERenderLayer(objectID: "root", objectName: "root", imagePath: "image", materialPath: nil, geometry: geometry,
                                   compositeA: "a", compositeB: "b", localFBOs: [], passes: [pass.pass], parallaxDepth: SIMD2(repeating: 1))
        let pipeline = WPEPreparedRenderPipeline(layers: [.init(graphLayer: layer, passes: [pass])])
        let camera = WPEMetalCameraUniforms(orthogonalProjection: .init(width: 384, height: 192, auto: false),
                                            sceneCamera: .defaultCamera, perspectiveOverrideFOVDegrees: 30)
        let runtime = WPEMetalRuntimeUniforms(time: 0, daytime: 0.5, brightness: 1, pointerPosition: SIMD2(repeating: 0.5))
        let base = pipeline.addingMetalRuntimeUniforms(runtime, camera: camera).frameUniforms
        var context = base
        fixture.executor.applyingAuthoredRootParallaxDrawProjection(to: &context, pipeline: pipeline, camera: camera,
                                                                    parallax: .init(smoothed: .zero, amount: 0.5, influence: 0), sceneSize: camera.renderSize)
        #expect(context.parallaxDrawMatrixPassIDs.isEmpty)
        #expect(context.value(named: "g_ModelViewProjectionMatrix", passID: pass.id) == base.value(named: "g_ModelViewProjectionMatrix", passID: pass.id))
    }

    @Test func effectProjectionRejectsPerspectiveObjects() throws {
        let fixture = try fixture(prewarmed: true, effectProjection: true)
        let pass = fixture.pipeline.layers[0].passes[0]
        let layer = fixture.pipeline.layers[0].graphLayer
        let texture = try #require(fixture.device.makeTexture(descriptor: .texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 4, height: 4, mipmapped: false)))
        let camera = WPEMetalCameraUniforms(orthogonalProjection: .init(width: 4, height: 4, auto: false), sceneCamera: .defaultCamera,
                                            perspectiveOverrideFOVDegrees: 30, perspectiveObjectIDs: [layer.id])
        #expect(camera.usesObjectPerspective(objectID: layer.id))
        let flat = WPEMetalCameraUniforms(orthogonalProjection: .init(width: 4, height: 4, auto: false), sceneCamera: .defaultCamera,
                                          perspectiveOverrideFOVDegrees: 30)
        for (uniforms, expected) in [(flat, nil), (camera, WPEAuthoredVertexRejection.unverifiedEffectProjection3D)] {
            let frame = WPEMetalFrameState(output: texture, sceneSize: CGSize(width: 4, height: 4), cameraUniforms: uniforms)
            let rejection = fixture.executor.authoredVertexRejection(for: pass, result: fixture.result, layer: layer, frameState: frame,
                                                                     effectTextureProjection: { matrix_identity_double4x4 })
            #expect(rejection == expected)
        }
    }

    /// Captured 9000542 probe-clock source; its missing common.h uses the actual builder fallback.
    private static let localTransformProbeVertex = """
    // [COMBO] {"material":"ui_editor_properties_mode","combo":"MODE","type":"options","default":0,"options":{"Vertex":1,"UV":0}}
    #include "common.h"
    uniform mat4 g_ModelViewProjectionMatrix;
    uniform vec2 g_Offset; // {"material":"offset","default":"0 0"}
    uniform vec2 g_Scale; // {"material":"scale","default":"1 1"}
    uniform float g_Direction; // {"material":"angle","default":0}
    attribute vec3 a_Position;
    attribute vec2 a_TexCoord;
    varying vec2 v_TexCoord;
    vec2 applyFx(vec2 v) {
        v = rotateVec2(v - CAST2(0.5), -g_Direction);
        return (v + g_Offset) * g_Scale + CAST2(0.5);
    }
    void main() {
        vec3 position = a_Position;
    #if MODE == 1
        position.xy = applyFx(position.xy);
    #endif
        gl_Position = mul(vec4(position, 1.0), g_ModelViewProjectionMatrix);
        v_TexCoord = a_TexCoord;
    #if MODE == 0
        v_TexCoord = applyFx(v_TexCoord);
    #endif
    }
    """

    private struct Fixture {
        let device: MTLDevice
        let executor: WPEMetalRenderExecutor
        let pipeline: WPEPreparedRenderPipeline
        let result: WPEShaderCompileResult
    }

    private func publicationPipeline(_ fixture: Fixture, includingTail: Bool = false) -> (WPEPreparedRenderPipeline, WPEMetalCameraUniforms) {
        let original = fixture.pipeline.layers[0].passes[0]
        let copy = fixture.pipeline.layers[0].passes[1]
        let identity = WPERenderEffectPassIdentity(objectID: "draw", authoredEffectID: "probe", authoredEffectPath: "test/probe.json",
                                                   effectPassIndex: 0, authoredOverrideID: nil)
        let effect = WPERenderPass(id: original.id, phase: .effect(file: "test/probe.json"), shader: original.pass.shader,
                                   source: .fbo("a"), target: .layerComposite(name: "b"), textures: [:], binds: [:], constants: [:], combos: [:],
                                   authoredJSON: .init(materialPass: .object(["cullmode": .string("nocull")]), effectIdentity: identity),
                                   blending: "disabled", cullMode: "nocull", depthTest: "disabled", depthWrite: "disabled")
        let base = WPERenderPass(id: "base", phase: .material, shader: "solidlayer", source: .asset("unused"),
                                 target: .layerComposite(name: "a"), textures: [:], binds: [:], constants: [:], combos: [:],
                                 blending: "disabled", cullMode: "nocull", depthTest: "disabled", depthWrite: "disabled")
        let preparedBase = WPEPreparedRenderPass(pass: base, shader: .init(name: "solidlayer", vertexSource: "", fragmentSource: "", isBuiltin: true),
                                                 textureBindings: [:], comboValues: [:], uniformValues: [:])
        let preparedEffect = WPEPreparedRenderPass(pass: effect, shader: original.shader, textureBindings: [0: .fbo("a")], comboValues: [:], uniformValues: [:])
        let tailIdentity = WPERenderEffectPassIdentity(objectID: "draw", authoredEffectID: "tail", authoredEffectPath: "test/tail.json",
                                                       effectPassIndex: 0, authoredOverrideID: nil)
        let tail = WPERenderPass(id: "tail", phase: .effect(file: "test/tail.json"), shader: original.pass.shader,
                                 source: .fbo("b"), target: .layerComposite(name: "a"), textures: [:], binds: [:], constants: [:], combos: [:],
                                 authoredJSON: .init(materialPass: .object(["cullmode": .string("nocull")]), effectIdentity: tailIdentity),
                                 blending: "disabled", cullMode: "nocull", depthTest: "disabled", depthWrite: "disabled")
        let preparedTail = WPEPreparedRenderPass(pass: tail, shader: original.shader, textureBindings: [0: .fbo("b")], comboValues: [:], uniformValues: [:])
        let passes = [preparedBase, preparedEffect] + (includingTail ? [preparedTail] : []) + [copy]
        let effects = [WPEEffectPublicationDescriptor.Effect(passID: effect.id, effectID: identity.stableEffectID)]
            + (includingTail ? [.init(passID: tail.id, effectID: tailIdentity.stableEffectID)] : [])
        let geometry = WPERenderLayerGeometry(origin: SIMD3(2, 2, 0), scale: SIMD3(repeating: 1), angles: .zero,
                                              alignment: .center, size: CGSize(width: 2, height: 2), alpha: 1, color: SIMD3(repeating: 1), brightness: 1)
        let graph = WPERenderLayer(objectID: "draw", objectName: "draw", imagePath: "unused", materialPath: nil, geometry: geometry,
                                   compositeA: "a", compositeB: "b", localFBOs: [], passes: passes.map(\.pass))
        let descriptor = WPEEffectPublicationDescriptor(basePassID: base.id, effects: effects,
                                                        copyPassID: copy.id, sourceExtent: nil, staticParentModel: nil, scope: .nativeSolidChain, baseSceneBlending: "normal")
        let pipeline = WPEPreparedRenderPipeline(layers: [.init(graphLayer: graph, passes: passes, effectPublication: descriptor)])
        return (pipeline, .init(orthogonalProjection: .init(width: 4, height: 4, auto: false), sceneCamera: .defaultCamera))
    }

    private func fixture(prewarmed: Bool, effectProjection: Bool = false) throws -> Fixture {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let vertexSource = """
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        uniform mat4 g_ModelViewProjectionMatrix;
        varying vec4 v_TexCoord;
        void main() {
            gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1);
            v_TexCoord = vec4(a_TexCoord, 0.375 + 0.25 * a_TexCoord);
        }
        """
        let effectVertex = "#define mul(v,m) ((m)*(v))\n" + vertexSource.replacingOccurrences(of: "uniform mat4 g_ModelViewProjectionMatrix;", with: "uniform mat4 g_ModelViewProjectionMatrix;\nuniform mat4 g_EffectModelViewProjectionMatrix;")
            .replacingOccurrences(of: "0.375 + 0.25 * a_TexCoord", with: "0.5 + 0.25 * mul(vec4(a_Position,1.0),g_EffectModelViewProjectionMatrix).xy")
        let program = WPEShaderProgram(name: "linked-dispatch-test", vertexSource: effectProjection ? effectVertex : vertexSource, fragmentSource: """
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
        executor.seedTranslatedShaderCache([(request.replacingVertexExecution(.authoredFullscreen).translationCacheKey, result)])
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
