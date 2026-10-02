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
        fixture.executor.authoredShaderResultByPassID[pass.id] = try fixture.executor.shaderCompiler.compile(request.replacingVertexExecution(.authoredObjectQuad))
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
            fixture.executor.authoredShaderResultByPassID[pass.id] = try fixture.executor.shaderCompiler.compile(request.replacingVertexExecution(.authoredObjectQuad))
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
        let program = WPEShaderProgram(name: "singular-inverse", vertexSource: (fragment ? "" : declaration) + source.vertexSource,
                                       fragmentSource: (fragment ? declaration : "") + source.fragmentSource, isBuiltin: false)
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
        fixture.executor.authoredShaderResultByPassID[pass.id] = try fixture.executor.shaderCompiler.compile(request.replacingVertexExecution(.authoredObjectQuad))
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

    private struct Fixture {
        let device: MTLDevice
        let executor: WPEMetalRenderExecutor
        let pipeline: WPEPreparedRenderPipeline
        let result: WPEShaderCompileResult
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
