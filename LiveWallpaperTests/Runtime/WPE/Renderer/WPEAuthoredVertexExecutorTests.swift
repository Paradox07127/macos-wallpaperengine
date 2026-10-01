#if !LITE_BUILD && DEBUG
import CoreGraphics
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
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
        let geometry = WPERenderLayerGeometry(origin: .zero, scale: SIMD3(repeating: 1), angles: .zero, alignment: .center,
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
