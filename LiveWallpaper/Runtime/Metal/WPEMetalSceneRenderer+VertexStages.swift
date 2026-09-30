#if !LITE_BUILD
import Foundation
import LiveWallpaperProWPE
import Metal

extension WPEMetalSceneRenderer {
    /// Compile and build authored pairs before any frame encoder is opened.
    /// Failures are retained as explicit admission reasons; the legacy result stays available.
    func prewarmAuthoredVertexShaders(for pipeline: WPEPreparedRenderPipeline,
                                      on _: isolated WPEDisplayRenderActor) async {
        guard !Task.isCancelled else { return }
        let generation = loadGeneration
        var requestByKey: [String: WPEShaderCompileRequest] = [:]
        var keyByPassID: [String: String] = [:]
        for layer in pipeline.layers {
            for pass in layer.passes where pass.shader?.isBuiltin == false {
                guard let request = try? WPEMetalRenderExecutor.makeCompileRequest(for: pass, recordFailure: false) else { continue }
                let authored = request.replacingVertexExecution(.authoredFullscreen)
                requestByKey[authored.translationCacheKey] = authored
                keyByPassID[pass.id] = authored.translationCacheKey
            }
        }
        let partition = executor.partitionTranslatedShaderPrewarmRequests(Array(requestByKey.values))
        let compiler = executor.shaderCompiler
        let width = max(2, min(4, ProcessInfo.processInfo.activeProcessorCount / 2))
        let entries = await withTaskGroup(of: AuthoredVertexPrewarmOutcome.self) { group in
            var next = 0
            func spawn() -> Bool {
                guard next < partition.missing.count else { return false }
                let request = partition.missing[next]; next += 1
                group.addTask {
                    if Task.isCancelled {
                        return .init(key: request.translationCacheKey, result: nil, reason: "prewarm-cancelled")
                    }
                    do {
                        return try .init(key: request.translationCacheKey, result: compiler.compile(request, recordFailure: false), reason: nil)
                    } catch {
                        return .init(key: request.translationCacheKey, result: nil, reason: String(describing: error))
                    }
                }
                return true
            }
            for _ in 0 ..< width where spawn() {}
            var outputs: [AuthoredVertexPrewarmOutcome] = []
            while let entry = await group.next() {
                if loadGeneration != generation {
                    group.cancelAll(); break
                }
                outputs.append(entry); _ = spawn()
            }
            return outputs
        }
        guard loadGeneration == generation, !Task.isCancelled else { return }
        let successful = entries.compactMap { entry in entry.result.map { (key: entry.key, result: $0) } }
        executor.seedTranslatedShaderCache(successful)
        let results = Dictionary((partition.cached + successful).map { ($0.key, $0.result) }, uniquingKeysWith: { first, _ in first })
        let reasons = Dictionary(entries.compactMap { entry in entry.reason.map { (entry.key, $0) } }, uniquingKeysWith: { first, _ in first })
        let declarations = pipeline.layers.flatMap(\.graphLayer.localFBOs)
        let colorFormat: MTLPixelFormat = cameraUniforms.sceneHDR ? .rgba16Float : WPEMetalRenderExecutor.outputPixelFormat
        var prewarms: [WPEMetalRenderExecutor.WPETranslatedPipelinePrewarm] = []
        var seen = Set<String>()
        for layer in pipeline.layers {
            for pass in layer.passes {
                guard let key = keyByPassID[pass.id] else { continue }
                guard let result = results[key] else {
                    executor.authoredVertexFailureByPassID[pass.id] = reasons[key] ?? "authored-stage-prewarm-unavailable"
                    continue
                }
                executor.authoredShaderResultByPassID[pass.id] = result
                let targetFormat = WPETranslatedPipelinePrewarmPlan.colorPixelFormat(target: pass.pass.target,
                                                                                     declaredFBOs: declarations, sceneColorFormat: colorFormat, hdr: cameraUniforms.sceneHDR)
                let depthFormat = WPETranslatedPipelinePrewarmPlan.depthPixelFormat(needsDepth: executor.depthCache.needsAttachment(for: pass))
                let alpha = WPEMetalAlphaWritePolicy.resolve(targetID: WPEMetalTargetID(target: pass.pass.target), blendMode: pass.pass.blending)
                let identity = "\(key)|\(pass.pass.blending)|\(alpha)|\(targetFormat.rawValue)|\(depthFormat.rawValue)"
                guard seen.insert(identity).inserted else { continue }
                prewarms.append(.init(device: executor.textureSourceDevice, defaultLibrary: executor.defaultLibrary,
                                      result: result, vertexName: nil, blendMode: pass.pass.blending, alphaWritePolicy: alpha,
                                      colorPixelFormat: targetFormat, depthPixelFormat: depthFormat))
            }
        }
        // Pipeline construction is bounded too; never start one task per pass.
        let built = await withTaskGroup(of: WPEMetalRenderExecutor.WPEPrewarmedPipeline?.self) { group in
            var next = 0
            func spawn() -> Bool {
                guard next < prewarms.count else { return false }
                let prewarm = prewarms[next]; next += 1
                group.addTask { WPEMetalRenderExecutor.buildTranslatedPipeline(prewarm) }
                return true
            }
            for _ in 0 ..< width where spawn() {}
            var outputs: [WPEMetalRenderExecutor.WPEPrewarmedPipeline] = []
            while let entry = await group.next() {
                if loadGeneration != generation {
                    group.cancelAll(); break
                }
                if let entry {
                    outputs.append(entry)
                }; _ = spawn()
            }
            return outputs
        }
        guard loadGeneration == generation, !Task.isCancelled else { return }
        executor.seedTranslatedPipelines(built)
        debugStage("vertex.prewarm.done", "pairs=\(results.count) failures=\(reasons.count) pipelines=\(built.count)")
    }

    private struct AuthoredVertexPrewarmOutcome: @unchecked Sendable {
        let key: String
        let result: WPEShaderCompileResult?
        let reason: String?
    }
}
#endif
