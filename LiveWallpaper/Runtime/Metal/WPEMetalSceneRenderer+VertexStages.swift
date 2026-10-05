#if !LITE_BUILD
import Foundation
import LiveWallpaperProWPE
import Metal

struct WPEAuthoredShaderRequestIdentity: Hashable {
    let preprocessing: WPEShaderPreprocessMemoKey
    let inputSlots: Set<Int>
    let output: Bool
    let execution: WPEVertexExecution
}

struct WPEAuthoredPassPrewarmVariant {
    let pass: WPEPreparedRenderPass
    let vertexExecution: WPEVertexExecution
}

extension WPEMetalRenderExecutor {
    /// Runtime-created passes have fresh IDs but may share an already compiled
    /// stage pair. Adopt only the complete content/execution/PMA cache key;
    /// dispatch still checks the actual target PSO and all runtime inputs.
    func adoptPrewarmedAuthoredShaders(for pipeline: WPEPreparedRenderPipeline, camera: WPEMetalCameraUniforms) {
        for layer in pipeline.layers {
            for pass in layer.passes where pass.shader?.isBuiltin == false {
                let execution = Self.authoredVertexExecution(for: pass, layer: layer.graphLayer, camera: camera)
                guard let identity = Self.authoredShaderRequestIdentity(for: pass, execution: execution) else { continue }
                let key: String
                if let cached = authoredRequestKeyByIdentity[identity] {
                    key = cached
                } else if let request = try? Self.makeCompileRequest(for: pass, recordFailure: false, allowPreprocessing: false) {
                    key = request.replacingVertexExecution(execution).translationCacheKey
                    authoredRequestKeyByIdentity[identity] = key
                } else {
                    authoredRequestKeyByPassID.removeValue(forKey: pass.id)
                    authoredShaderResultByPassID.removeValue(forKey: pass.id)
                    authoredVertexFailureByPassID[pass.id] = "authored-request-not-prepared"
                    continue
                }
                if authoredRequestKeyByPassID[pass.id] == key,
                   authoredShaderResultByPassID[pass.id] != nil || translatedShaderCache[key] == nil {
                    continue
                }
                authoredRequestKeyByPassID[pass.id] = key
                authoredShaderResultByPassID.removeValue(forKey: pass.id)
                authoredVertexFailureByPassID.removeValue(forKey: pass.id)
                guard let result = translatedShaderCache[key] else {
                    authoredVertexFailureByPassID[pass.id] = "authored-stage-not-prepared"
                    continue
                }
                authoredShaderResultByPassID[pass.id] = result
            }
        }
    }

    static func authoredVertexExecution(
        for pass: WPEPreparedRenderPass, layer: WPERenderLayer, camera: WPEMetalCameraUniforms
    ) -> WPEVertexExecution {
        if pass.publicationVertexRole != .localEffect, case .scene = pass.pass.target,
           layer.geometry != .identity, canSupplyAuthoredObjectQuad(layer: layer, camera: camera) {
            return .authoredObjectQuad
        }
        return .authoredFullscreen
    }

    func authoredPrewarmRequest(for pass: WPEPreparedRenderPass, execution: WPEVertexExecution) -> WPEShaderCompileRequest? {
        guard let request = try? Self.makeCompileRequest(for: pass, recordFailure: false),
              let identity = Self.authoredShaderRequestIdentity(for: pass, execution: execution) else { return nil }
        let authored = request.replacingVertexExecution(execution)
        authoredRequestKeyByIdentity[identity] = authored.translationCacheKey
        return authored
    }

    static func authoredPrewarmVariants(for layer: WPEPreparedRenderLayer, camera: WPEMetalCameraUniforms) -> [WPEAuthoredPassPrewarmVariant] {
        layer.passes.map { pass in
            .init(pass: pass, vertexExecution: authoredVertexExecution(for: pass, layer: layer.graphLayer, camera: camera))
        } + layer.effectPublicationPrewarmPasses(camera: camera).map { pass in
            .init(pass: pass, vertexExecution: authoredVertexExecution(for: pass,
                                                                       layer: layer.graphLayer.replacingPasses([pass.pass]), camera: camera))
        }
    }

    func readyEffectPublicationLayerIDs(
        in pipeline: WPEPreparedRenderPipeline, camera: WPEMetalCameraUniforms
    ) -> Set<String> {
        let declarations = pipeline.layers.flatMap(\.graphLayer.localFBOs)
        let colorFormat: MTLPixelFormat = camera.sceneHDR ? .rgba16Float : Self.outputPixelFormat
        return Set(pipeline.layers.compactMap { layer -> String? in
            let publicationPasses = layer.effectPublicationPrewarmPasses(camera: camera)
            guard let descriptor = layer.effectPublication,
                  !descriptor.effects.isEmpty,
                  Set(publicationPasses.filter { $0.shader?.isBuiltin == false }.map(\.id)) == Set(descriptor.effects.map(\.passID)) else { return nil }
            let variants = Self.authoredPrewarmVariants(for: layer, camera: camera)
            let required = variants.suffix(publicationPasses.count)
            let native = descriptor.scope == .nativeSolidChain ? required.filter {
                $0.pass.shader?.isBuiltin == true && WPEBuiltinShaderKind(normalizing: $0.pass.pass.shader) == .solidLayer
                    && $0.pass.renderContract.shaderAlpha.premultipliedOutput == false
            } : []
            guard native.count == publicationPasses.filter({ $0.shader?.isBuiltin == true }).count else { return nil }
            guard native.allSatisfy({ variant in
                let pass = variant.pass
                let targetFormat = WPETranslatedPipelinePrewarmPlan.colorPixelFormat(target: pass.pass.target,
                                                                                     declaredFBOs: declarations, sceneColorFormat: colorFormat, hdr: camera.sceneHDR)
                let depthFormat = WPETranslatedPipelinePrewarmPlan.depthPixelFormat(needsDepth: depthCache.needsAttachment(for: pass))
                return hasCachedPassPipelineState(passID: pass.id, variant: .solidLayerStraight,
                                                  objectQuad: variant.vertexExecution == .authoredObjectQuad, blendMode: pass.pass.blending,
                                                  alphaWritePolicy: pass.renderContract.attachment.alphaWritePolicy,
                                                  colorPixelFormat: targetFormat, depthPixelFormat: depthFormat,
                                                  nativeAlpha: pass.renderContract.nativeAlpha, blendContract: pass.renderContract.blend)
            }) else { return nil }
            guard variants.filter({ $0.pass.shader?.isBuiltin == false }).allSatisfy({ variant in
                let pass = variant.pass
                guard let identity = Self.authoredShaderRequestIdentity(for: pass, execution: variant.vertexExecution),
                      let key = authoredRequestKeyByIdentity[identity], let result = translatedShaderCache[key] else { return false }
                let targetFormat = WPETranslatedPipelinePrewarmPlan.colorPixelFormat(target: pass.pass.target,
                                                                                     declaredFBOs: declarations, sceneColorFormat: colorFormat, hdr: camera.sceneHDR)
                let depthFormat = WPETranslatedPipelinePrewarmPlan.depthPixelFormat(needsDepth: depthCache.needsAttachment(for: pass))
                return hasPrewarmedAuthoredPipeline(for: result, pass: pass, targetID: WPEMetalTargetID(target: pass.pass.target),
                                                    colorPixelFormat: targetFormat, depthPixelFormat: depthFormat)
            }) else { return nil }
            let terminalOnlyID = descriptor.groups.last?.last(where: { identity in
                layer.passes.first(where: { $0.id == identity.passID })?.pass.authoredJSON.effectPass?["target"] == nil
            })?.passID
            guard required
                .filter({ $0.pass.shader?.isBuiltin == false }).allSatisfy({ variant in
                    let needsLocalExecution = variant.pass.publicationVertexRole == .localEffect
                        && variant.pass.id != terminalOnlyID
                    guard variant.vertexExecution == .authoredObjectQuad || needsLocalExecution else { return true }
                    guard let identity = Self.authoredShaderRequestIdentity(for: variant.pass, execution: variant.vertexExecution),
                          let key = authoredRequestKeyByIdentity[identity], let result = translatedShaderCache[key],
                          result.vertexStage?.execution == variant.vertexExecution else { return false }
                    let needsPositionProof = result.vertexStage?.uniformLayout.contains {
                        $0.name == "g_ModelViewProjectionMatrix" && $0.materialName == nil
                            && result.shaderInterface?.isVertexUniformProvenUnreferenced($0.name) != true
                    } == true
                    return variant.vertexExecution != .authoredFullscreen || !needsPositionProof || result.fullscreenMVPPositionOnly
                        || (variant.pass.publicationVertexRole == .localEffect && result.localEffectMVPPositionOnly)
                }) else { return nil }
            return layer.graphLayer.objectID
        })
    }
}

extension WPEMetalSceneRenderer {
    /// Compile and build authored pairs before any frame encoder is opened.
    /// Failures are retained as explicit admission reasons; the legacy result stays available.
    func prewarmAuthoredVertexShaders(for pipeline: WPEPreparedRenderPipeline,
                                      on _: isolated WPEDisplayRenderActor) async -> Set<String> {
        guard !Task.isCancelled else { return [] }
        let generation = loadGeneration
        var requestByKey: [String: WPEShaderCompileRequest] = [:]
        var candidates: [(pass: WPEPreparedRenderPass, key: String)] = []
        for layer in pipeline.layers {
            for variant in WPEMetalRenderExecutor.authoredPrewarmVariants(for: layer, camera: cameraUniforms) where variant.pass.shader?.isBuiltin == false {
                guard !Task.isCancelled else { return [] }
                let pass = variant.pass
                guard let authored = executor.authoredPrewarmRequest(for: pass, execution: variant.vertexExecution) else { continue }
                requestByKey[authored.translationCacheKey] = authored
                candidates.append((pass, authored.translationCacheKey))
            }
        }
        let partition = executor.partitionTranslatedShaderPrewarmRequests(Array(requestByKey.values))
        let compiler = executor.shaderCompiler
        let width = max(2, min(4, ProcessInfo.processInfo.activeProcessorCount / 2))
        let entries = await withTaskGroup(of: AuthoredVertexPrewarmOutcome.self) { group in
            var next = 0
            func spawn() -> Bool {
                guard next < partition.missing.count, !Task.isCancelled else { return false }
                let request = partition.missing[next]; next += 1
                group.addTask {
                    if Task.isCancelled {
                        return .init(key: request.translationCacheKey, result: nil, reason: "prewarm-cancelled")
                    }
                    // Detach: task-group children inherit the render actor (Swift 6),
                    // which would serialize the compiles.
                    return await Task.detached(priority: .userInitiated) {
                        do {
                            return try .init(key: request.translationCacheKey, result: compiler.compile(request, recordFailure: false), reason: nil)
                        } catch {
                            return .init(key: request.translationCacheKey, result: nil, reason: String(describing: error))
                        }
                    }.value
                }
                return true
            }
            for _ in 0 ..< width where spawn() {}
            var outputs: [AuthoredVertexPrewarmOutcome] = []
            while let entry = await group.next() {
                if loadGeneration != generation || Task.isCancelled {
                    group.cancelAll(); break
                }
                outputs.append(entry); _ = spawn()
            }
            return outputs
        }
        guard loadGeneration == generation, !Task.isCancelled else { return [] }
        let successful = entries.compactMap { entry in entry.result.map { (key: entry.key, result: $0) } }
        executor.seedTranslatedShaderCache(successful)
        let results = Dictionary((partition.cached + successful).map { ($0.key, $0.result) }, uniquingKeysWith: { first, _ in first })
        let reasons = Dictionary(entries.compactMap { entry in entry.reason.map { (entry.key, $0) } }, uniquingKeysWith: { first, _ in first })
        let declarations = pipeline.layers.flatMap(\.graphLayer.localFBOs)
        let colorFormat: MTLPixelFormat = cameraUniforms.sceneHDR ? .rgba16Float : WPEMetalRenderExecutor.outputPixelFormat
        for layer in pipeline.layers where layer.effectPublication?.scope == .nativeSolidChain {
            for variant in WPEMetalRenderExecutor.authoredPrewarmVariants(for: layer, camera: cameraUniforms)
                where variant.pass.shader?.isBuiltin == true && WPEBuiltinShaderKind(normalizing: variant.pass.pass.shader) == .solidLayer
                && variant.pass.renderContract.shaderAlpha.premultipliedOutput == false {
                guard !Task.isCancelled else { return [] }
                let pass = variant.pass
                let targetFormat = WPETranslatedPipelinePrewarmPlan.colorPixelFormat(target: pass.pass.target,
                                                                                     declaredFBOs: declarations, sceneColorFormat: colorFormat, hdr: cameraUniforms.sceneHDR)
                let depthFormat = WPETranslatedPipelinePrewarmPlan.depthPixelFormat(needsDepth: executor.depthCache.needsAttachment(for: pass))
                let objectQuad = variant.vertexExecution == .authoredObjectQuad
                _ = try? executor.passPipelineState(passID: pass.id, variant: .solidLayerStraight, objectQuad: objectQuad,
                                                    vertexName: objectQuad ? "wpe_object_quad_vertex" : "wpe_fullscreen_vertex", fragmentName: "wpe_solidlayer_straight_fragment",
                                                    blendMode: pass.pass.blending,
                                                    alphaWritePolicy: pass.renderContract.attachment.alphaWritePolicy,
                                                    colorPixelFormat: targetFormat, depthPixelFormat: depthFormat,
                                                    nativeAlpha: pass.renderContract.nativeAlpha, blendContract: pass.renderContract.blend)
            }
        }
        var prewarms: [WPEMetalRenderExecutor.WPETranslatedPipelinePrewarm] = []
        var seen = Set<String>()
        for (pass, key) in candidates {
            guard !Task.isCancelled else { return [] }
            guard let result = results[key] else { continue }
            let targetFormat = WPETranslatedPipelinePrewarmPlan.colorPixelFormat(target: pass.pass.target,
                                                                                 declaredFBOs: declarations, sceneColorFormat: colorFormat, hdr: cameraUniforms.sceneHDR)
            let depthFormat = WPETranslatedPipelinePrewarmPlan.depthPixelFormat(needsDepth: executor.depthCache.needsAttachment(for: pass))
            let alpha = pass.renderContract.attachment.alphaWritePolicy
            let identity = "\(key)|\(pass.pass.blending)|\(alpha)|\(targetFormat.rawValue)|\(depthFormat.rawValue)"
            guard seen.insert(identity).inserted else { continue }
            prewarms.append(.init(device: executor.textureSourceDevice, defaultLibrary: executor.defaultLibrary,
                                  result: result, vertexName: nil, blendMode: pass.pass.blending, alphaWritePolicy: alpha,
                                  colorPixelFormat: targetFormat, depthPixelFormat: depthFormat))
        }
        // Pipeline construction is bounded too; never start one task per pass.
        let built = await withTaskGroup(of: WPEMetalRenderExecutor.WPEPrewarmedPipeline?.self) { group in
            var next = 0
            func spawn() -> Bool {
                guard next < prewarms.count, !Task.isCancelled else { return false }
                let prewarm = prewarms[next]; next += 1
                group.addTask {
                    guard !Task.isCancelled else { return nil }
                    // Detach: task-group children inherit the render actor (Swift 6).
                    return await Task.detached(priority: .userInitiated) {
                        WPEMetalRenderExecutor.buildTranslatedPipeline(prewarm)
                    }.value
                }
                return true
            }
            for _ in 0 ..< width where spawn() {}
            var outputs: [WPEMetalRenderExecutor.WPEPrewarmedPipeline] = []
            while let entry = await group.next() {
                if loadGeneration != generation || Task.isCancelled {
                    group.cancelAll(); break
                }
                if let entry {
                    outputs.append(entry)
                }; _ = spawn()
            }
            return outputs
        }
        guard loadGeneration == generation, !Task.isCancelled else { return [] }
        executor.seedTranslatedPipelines(built)
        debugStage("vertex.prewarm.done", "pairs=\(results.count) failures=\(reasons.count) pipelines=\(built.count)")
        return executor.readyEffectPublicationLayerIDs(in: pipeline, camera: cameraUniforms)
    }

    private struct AuthoredVertexPrewarmOutcome: @unchecked Sendable {
        let key: String
        let result: WPEShaderCompileResult?
        let reason: String?
    }
}
#endif
