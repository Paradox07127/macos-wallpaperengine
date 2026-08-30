#if !LITE_BUILD
import AppKit
import LiveWallpaperCore
import LiveWallpaperProWPE
import MetalKit

/// Load-time PSO prewarm signatures. Must match `dispatchCustomShader`'s vertex
/// / color / depth choice — a miss is only a first-frame compile, never a
/// wrong pipeline, but the previous `{nil, object_quad} × scene color ×
/// .invalid depth` set missed FBO formats, depth, skew, and shape quads.
enum WPETranslatedPipelinePrewarmPlan {
    static func vertexNames(
        target: WPERenderTarget,
        shapePointCount: Int?,
        objectQuadAtRest: Bool,
        parallaxMayEnableObjectQuad: Bool,
        skewVertex: Bool,
        usesPerspectiveProjection: Bool
    ) -> [String?] {
        let sceneTarget: Bool
        if case .scene = target {
            sceneTarget = true
        } else {
            sceneTarget = false
        }
        let shapeEligible = sceneTarget && shapePointCount == 4
        var names: [String?] = []
        if shapeEligible && !usesPerspectiveProjection {
            names.append("wpe_shape_quad_vertex")
            names.append("wpe_object_quad_vertex")
        } else if objectQuadAtRest {
            if skewVertex {
                names.append("wpe_skew_object_quad_vertex")
            }
            names.append("wpe_object_quad_vertex")
        } else {
            names.append(nil)
            if parallaxMayEnableObjectQuad {
                if skewVertex {
                    names.append("wpe_skew_object_quad_vertex")
                }
                names.append("wpe_object_quad_vertex")
            }
        }
        var seen = Set<String>()
        return names.filter { seen.insert($0 ?? "").inserted }
    }

    static func colorPixelFormat(
        target: WPERenderTarget,
        localFBOs: [WPERenderFBO],
        sceneColorFormat: MTLPixelFormat,
        hdr: Bool
    ) -> MTLPixelFormat {
        switch target {
        case .scene, .layerComposite:
            return sceneColorFormat
        case .fbo(let name):
            let format = localFBOs.first(where: { $0.name == name })?.format ?? "rgba8888"
            return WPEMetalRenderTargetPool.pixelFormat(forFBOFormat: format, promoteLDRToHDR: hdr)
        }
    }

    static func depthPixelFormat(needsDepth: Bool) -> MTLPixelFormat {
        needsDepth ? .depth32Float : .invalid
    }
}

extension WPEMetalSceneRenderer {
    // MARK: - Loaded texture resource types

    enum WPELoadedTextureResource {
        case staticTexture(MTLTexture)
        case dynamicSource(WPEDynamicTextureSource)
    }

    /// Captured before fan-out so the off-actor lane never races on a shared dedup map.
    private struct WPETextureLoadJob: Sendable {
        let path: String
        let layerName: String
        let candidates: [String]
        /// Slot 0 must resolve. A missing auxiliary slot is unbound (dispatcher binds primary) rather than failing the scene.
        let isRequired: Bool
    }

    enum WPEParallelTextureResult: @unchecked Sendable { // MTLTexture is documented thread-safe; ferries it across the actor hop.
        case staticTexture(MTLTexture)
        case needsOnActor
        case skipped
    }

    // MARK: - Shader prewarm

    func prewarmCustomShaders(
        for pipeline: WPEPreparedRenderPipeline,
        on actor: isolated WPEDisplayRenderActor
    ) async {
        // Must pre-compile before first-frame encode: inline compile during an open encoder corrupts the pass (3660962877 black + green quad).
        let generation = loadGeneration
        debugStage("shader.prewarm", "begin")

        var requestsByKey: [String: WPEShaderCompileRequest] = [:]
        for layer in pipeline.layers {
            for pass in layer.passes where pass.shader?.isBuiltin == false {
                guard let request = try? WPEMetalRenderExecutor.makeCompileRequest(for: pass, recordFailure: false) else { continue }
                requestsByKey[request.translationCacheKey] = request
            }
        }
        let allRequests = Array(requestsByKey.values)
        guard !allRequests.isEmpty, loadGeneration == generation else {
            debugStage("shader.prewarm.done", "passes=0")
            return
        }

        let partition = executor.partitionTranslatedShaderPrewarmRequests(allRequests)
        let requests = partition.missing

        let compiler = executor.shaderCompiler
        let width = max(2, min(4, ProcessInfo.processInfo.activeProcessorCount / 2))

        let compiled: [(key: String, result: WPEShaderCompileResult)]
        do {
            compiled = try await withThrowingTaskGroup(
                of: (key: String, result: WPEShaderCompileResult)?.self
            ) { group in
                var next = 0
                func spawn() -> Bool {
                    guard next < requests.count else { return false }
                    let request = requests[next]
                    next += 1
                    group.addTask(priority: .userInitiated) {
                        try Task.checkCancellation()
                        // Leave unsupported shaders uncached so the real first-frame compile records them.
                        guard let result = try? compiler.compile(request, recordFailure: false) else {
                            return nil
                        }
                        return (key: request.translationCacheKey, result: result)
                    }
                    return true
                }
                for _ in 0..<width where spawn() {}
                var collected: [(key: String, result: WPEShaderCompileResult)] = []
                while let entry = try await group.next() {
                    if loadGeneration != generation {
                        group.cancelAll()
                        break
                    }
                    if let entry { collected.append(entry) }
                    _ = spawn()
                }
                return collected
            }
        } catch {
            // Superseded load cancelled the group mid-drain; drop the partial results.
            debugStage("shader.prewarm.cancelled", "\(error)")
            return
        }

        guard loadGeneration == generation else { return }
        executor.seedTranslatedShaderCache(compiled)
        let warmed = partition.cached + compiled
        debugStage(
            "shader.prewarm.done",
            "cacheHits=\(partition.cached.count) compiled=\(compiled.count) total=\(allRequests.count)"
        )

        // Pre-build pipeline states too. Over-/under-prediction only changes cache-hit rate, never correctness.
        var resultByKey: [String: WPEShaderCompileResult] = [:]
        for entry in warmed { resultByKey[entry.key] = entry.result }
        let sceneColorFormat: MTLPixelFormat = cameraUniforms.sceneHDR
            ? .rgba16Float
            : WPEMetalRenderExecutor.outputPixelFormat
        let hdr = cameraUniforms.sceneHDR
        let prewarmDevice = executor.textureSourceDevice
        var pipelinePrewarms: [WPEMetalRenderExecutor.WPETranslatedPipelinePrewarm] = []
        var seenPipelineKeys = Set<String>()
        var passIDSeeds: [(passID: String, result: WPEShaderCompileResult)] = []
        for layer in pipeline.layers {
            for pass in layer.passes where pass.shader?.isBuiltin == false {
                guard let request = try? WPEMetalRenderExecutor.makeCompileRequest(for: pass, recordFailure: false),
                      let result = resultByKey[request.translationCacheKey] else { continue }
                passIDSeeds.append((passID: pass.id, result: result))
                let blend = pass.pass.blending
                let alphaWritePolicy = WPEMetalAlphaWritePolicy.resolve(
                    targetID: WPEMetalTargetID(target: pass.pass.target),
                    blendMode: blend
                )
                let colorPixelFormat = WPETranslatedPipelinePrewarmPlan.colorPixelFormat(
                    target: pass.pass.target,
                    localFBOs: layer.graphLayer.localFBOs,
                    sceneColorFormat: sceneColorFormat,
                    hdr: hdr
                )
                let depthPixelFormat = WPETranslatedPipelinePrewarmPlan.depthPixelFormat(
                    needsDepth: executor.depthCache.needsAttachment(for: pass)
                )
                for vertexName in prewarmVertexNames(for: pass, layer: layer.graphLayer) {
                    let dedup = "\(ObjectIdentifier(result.library))|\(vertexName ?? result.vertexFunctionName)|\(result.fragmentFunctionName)|\(blend.lowercased())|\(alphaWritePolicy)|\(colorPixelFormat.rawValue)|\(depthPixelFormat.rawValue)"
                    guard seenPipelineKeys.insert(dedup).inserted else { continue }
                    pipelinePrewarms.append(.init(
                        device: prewarmDevice,
                        result: result,
                        vertexName: vertexName,
                        blendMode: blend,
                        alphaWritePolicy: alphaWritePolicy,
                        colorPixelFormat: colorPixelFormat,
                        depthPixelFormat: depthPixelFormat
                    ))
                }
            }
        }
        guard loadGeneration == generation else { return }
        executor.seedCompiledShaderResultsByPassID(passIDSeeds)
        guard !pipelinePrewarms.isEmpty else {
            debugStage("pipeline.prewarm.done", "combos=0")
            return
        }
        // Off the render thread: captures only the `@unchecked Sendable` prewarm requests, never the executor.
        let pipeWidth = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 1))
        let built: [WPEMetalRenderExecutor.WPEPrewarmedPipeline] = await withTaskGroup(
            of: WPEMetalRenderExecutor.WPEPrewarmedPipeline?.self
        ) { group in
            var next = 0
            func spawn() -> Bool {
                guard next < pipelinePrewarms.count else { return false }
                let prewarm = pipelinePrewarms[next]
                next += 1
                group.addTask(priority: .userInitiated) {
                    WPEMetalRenderExecutor.buildTranslatedPipeline(prewarm)
                }
                return true
            }
            for _ in 0..<pipeWidth where spawn() {}
            var collected: [WPEMetalRenderExecutor.WPEPrewarmedPipeline] = []
            while let entry = await group.next() {
                if loadGeneration != generation {
                    group.cancelAll()
                    break
                }
                if let entry { collected.append(entry) }
                _ = spawn()
            }
            return collected
        }
        guard loadGeneration == generation else { return }
        executor.seedTranslatedPipelines(built)
        debugStage("pipeline.prewarm.done", "combos=\(pipelinePrewarms.count) built=\(built.count)")
    }

    /// Vertex names the first-frame encode of this pass can actually select.
    /// Parallax can flip identity scene layers onto the object quad after load,
    /// so those passes prewarm both `nil` (fullscreen) and the object quad.
    func prewarmVertexNames(
        for pass: WPEPreparedRenderPass,
        layer: WPERenderLayer
    ) -> [String?] {
        WPETranslatedPipelinePrewarmPlan.vertexNames(
            target: pass.pass.target,
            shapePointCount: layer.geometry.shapePoints?.count,
            objectQuadAtRest: executor.usesObjectQuadGeometry(for: pass, layer: layer),
            parallaxMayEnableObjectQuad: {
                guard case .scene = pass.pass.target else { return false }
                return layer.geometry == .identity
                    && layer.parallaxDepth != SIMD2<Double>(0, 0)
            }(),
            skewVertex: prewarmIncludesSkewVertex(pass),
            usesPerspectiveProjection: cameraUniforms.usesPerspectiveProjection
        )
    }

    /// MODE=1 skew can start with zero authored params and animate in; encode
    /// then switches vertex, so prewarm the skew vertex whenever MODE=1.
    func prewarmIncludesSkewVertex(_ pass: WPEPreparedRenderPass) -> Bool {
        if executor.isVertexSkewPass(pass) { return true }
        let shader = pass.pass.shader
            .replacingOccurrences(of: "\\", with: "/")
            .lowercased()
        let isSkew = shader == "effects/skew" || shader.hasSuffix("/effects/skew")
        let mode = pass.comboValues["MODE"] ?? pass.pass.combos["MODE"] ?? 0
        return isSkew && mode == 1
    }

    // MARK: - Bulk texture loading

    func loadTextures(
        for pipeline: WPEPreparedRenderPipeline,
        on actor: isolated WPEDisplayRenderActor
    ) async throws {
        loadedTextures = [:]
        dynamicTextureSources = [:]
        resetTextureCacheBudgetState()

        var jobs: [WPETextureLoadJob] = []
        var seen = Set<String>()
        for layer in pipeline.layers {
            let layerName = layer.graphLayer.objectName
            if layer.passes.isEmpty {
                if let path = externalTexturePath(for: .image(layer.graphLayer.imagePath)),
                   seen.insert(path).inserted {
                    jobs.append(WPETextureLoadJob(
                        path: path,
                        layerName: layerName,
                        candidates: textureCandidates(for: path),
                        isRequired: true
                    ))
                }
                continue
            }
            for preparedPass in layer.passes {
                for role in textureReferenceRoles(for: preparedPass) {
                    if let path = externalTexturePath(for: role.reference),
                       // Synthetic text paths are graph routing tokens; the glyph pass has no disk texture.
                       !WPETextLayerSynthesis.isTargetPath(path),
                       seen.insert(path).inserted {
                        jobs.append(WPETextureLoadJob(
                            path: path,
                            layerName: layerName,
                            candidates: textureCandidates(for: path),
                            isRequired: role.isRequired
                        ))
                    }
                }
            }
        }
        guard !jobs.isEmpty else { return }

        // Snapshot generation so a mid-flight reload cannot write a stale texture into the new load.
        let generation = loadGeneration
        let resolver = resourceResolver
        let loader = textureLoader
        let threshold = Self.lazyAnimationRawByteThreshold
        if !didLatchTextureCap {
            latchedTextureCap = upscalePlan.maxSourceTextureEdge
            didLatchTextureCap = true
        }
        let maxSourceEdge = latchedTextureCap
        let width = max(2, min(4, ProcessInfo.processInfo.activeProcessorCount / 2))

        try await withThrowingTaskGroup(of: (Int, WPEParallelTextureResult).self) { group in
            var nextIndex = 0
            func spawnNext() -> Bool {
                guard nextIndex < jobs.count else { return false }
                let index = nextIndex
                nextIndex += 1
                let job = jobs[index]
                group.addTask(priority: .userInitiated) {
                    do {
                        let result = try await Self.resolveStaticTextureOrDefer(
                            relativePath: job.path,
                            label: "WPE texture \(job.path)",
                            candidates: job.candidates,
                            resolver: resolver,
                            loader: loader,
                            streamingThreshold: threshold,
                            maxSourceEdge: maxSourceEdge
                        )
                        return (index, result)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        // A broken auxiliary slot must not kill the scene; encode binds the primary instead.
                        guard job.isRequired else { return (index, .skipped) }
                        throw WPEMetalTextureLoadContextError(layerName: job.layerName, path: job.path, underlying: error)
                    }
                }
                return true
            }

            for _ in 0..<width where spawnNext() {}

            while let (index, result) = try await group.next() {
                try Task.checkCancellation()
                guard loadGeneration == generation else {
                    group.cancelAll()
                    return
                }
                switch result {
                case .staticTexture(let texture):
                    recordLoadedStaticTexture(
                        path: jobs[index].path,
                        layerName: jobs[index].layerName,
                        candidates: jobs[index].candidates,
                        texture: texture
                    )
                case .skipped:
                    Logger.warning(
                        "Scene \(descriptor.workshopID) auxiliary texture '\(jobs[index].path)'"
                            + " (layer \(jobs[index].layerName)) did not resolve; the slot renders unbound",
                        category: .wpeRender
                    )
                case .needsOnActor:
                    // Video / multi-frame / heavy-streaming construction is actor-isolated; reuse the serial resolver.
                    try await loadDynamicTextureOnActor(
                        path: jobs[index].path,
                        layerName: jobs[index].layerName,
                        publicationAllowed: { [weak self] in
                            self?.loadGeneration == generation
                        },
                        on: actor
                    )
                }
                _ = spawnNext()
            }
        }
    }

    nonisolated static func resolveStaticTextureOrDefer(
        relativePath: String,
        label: String,
        candidates: [String],
        resolver: WPEMultiRootResourceResolver,
        loader: WPEMetalTextureLoader,
        streamingThreshold: Int,
        maxSourceEdge: Int? = nil
    ) async throws -> WPEParallelTextureResult {
        try Task.checkCancellation()
        var lastError: Error?
        for candidate in candidates {
            try Task.checkCancellation()
            do {
                if shouldTryTexturePayload(candidate) {
                    do {
                        if detectHeavyStreaming(candidate, resolver: resolver, threshold: streamingThreshold) {
                            return .needsOnActor
                        }
                        // Decode only the levels this upload reads; video and
                        // animation payloads are built before the scope applies.
                        let payload = try resolver.resolveTexturePayload(
                            relativePath: candidate,
                            scope: WPEMetalTextureLoader.mipInflateScope(maxSourceEdge: maxSourceEdge)
                        )
                        try Task.checkCancellation()
                        if payload.videoPayload != nil || payload.animationTrack != nil {
                            return .needsOnActor
                        }
                        return .staticTexture(try await loader.makeTexture(
                            from: payload, label: label, maxSourceEdge: maxSourceEdge
                        ))
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        lastError = error
                    }
                }
                let resolved = try resolver.resolveImage(
                    relativePath: candidate,
                    maxSourceEdge: maxSourceEdge
                )
                try Task.checkCancellation()
                return .staticTexture(try await loader.makeTexture(
                    from: resolved.image,
                    label: label,
                    maxSourceEdge: maxSourceEdge,
                    sourcePixelSize: (resolved.sourcePixelWidth, resolved.sourcePixelHeight)
                ))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        try Task.checkCancellation()
        throw lastError ?? WPEMetalRenderExecutorError.missingTexture(.image(relativePath))
    }

    /// GPU residency the eager path would create for a multi-frame `.tex`: one
    /// texture per image the frame schedule actually references, billed with the
    /// same estimator as the texture-cache LRU. `totalUncompressedImageBytes`
    /// instead sums every container image at its stored payload size, so it
    /// over-counts unreferenced images and mis-counts padded/absent mip levels.
    nonisolated static func eagerAnimationGPUBytes(of payload: WPETexStreamingPayload) -> Int {
        guard let format = payload.info.format else { return payload.totalUncompressedImageBytes }
        let referenced = payload.frames.isEmpty
            ? Set(payload.compressedImages.indices)
            : Set(payload.frames.map(\.imageID))
        return referenced.reduce(0) { total, imageID in
            guard payload.compressedImages.indices.contains(imageID) else { return total }
            let image = payload.compressedImages[imageID]
            let mipmap = image.payloads.first
            return total + format.expectedByteCount(
                width: mipmap?.width ?? image.width,
                height: mipmap?.height ?? image.height
            )
        }
    }

    /// The lazy source binds an axis-aligned frame crop. A TEXS frame with
    /// cross-axis basis terms requires the full atlas plus its authored
    /// transform; routing it through the cropped representation would discard
    /// rotation/shear and then falsely report identity to the shader.
    nonisolated static func shouldUseLazyAnimationRepresentation(
        _ payload: WPETexStreamingPayload,
        threshold: Int
    ) -> Bool {
        let requiresAtlasSampling = payload.frames.contains { frame in
            guard let descriptor = frame.samplingDescriptor else { return false }
            return descriptor.rotation.y != 0 || descriptor.rotation.z != 0
        }
        return !requiresAtlasSampling && eagerAnimationGPUBytes(of: payload) > threshold
    }

    private nonisolated static func detectHeavyStreaming(
        _ candidate: String,
        resolver: WPEMultiRootResourceResolver,
        threshold: Int
    ) -> Bool {
        let ext = (candidate as NSString).pathExtension.lowercased()
        let probeCandidates: [String]
        if ext == "tex" {
            probeCandidates = [candidate]
        } else if ext.isEmpty {
            let stripped = (candidate as NSString).deletingPathExtension
            probeCandidates = [candidate, "materials/\(stripped).tex"]
        } else {
            return false
        }
        for probe in probeCandidates {
            guard let payload = try? resolver.resolveStreamingTexturePayload(relativePath: probe) else {
                continue
            }
            if shouldUseLazyAnimationRepresentation(payload, threshold: threshold) {
                return true
            }
        }
        return false
    }

    func loadDynamicTextureOnActor(
        path: String,
        layerName: String,
        publicationAllowed: () async -> Bool = { true },
        on actor: isolated WPEDisplayRenderActor
    ) async throws {
        do {
            let resource = try await makeTextureResource(
                relativePath: path,
                label: "WPE texture \(path)",
                maxSourceEdge: latchedTextureCap,
                on: actor
            )
            // `publicationAllowed` is an async hop; re-check after it resumes so a cancel during the hop does not publish.
            guard await publicationAllowed() else { throw CancellationError() }
            try Task.checkCancellation()
            switch resource {
            case .staticTexture(let texture):
                recordLoadedStaticTexture(
                    path: path,
                    layerName: layerName,
                    candidates: textureCandidates(for: path),
                    texture: texture
                )
            case .dynamicSource(let source):
                forgetStaticTextureCacheRecord(path)
                dynamicTextureSources[path] = source
                if let texture = source.texture(at: lastRuntimeUniforms?.time ?? 0) {
                    loadedTextures[path] = texture
                } else if loadedTextures[path] == nil {
                    loadedTextures[path] = try makeDynamicPlaceholderTexture(label: "\(path) placeholder")
                }
            }
        } catch is CancellationError {
            // Keep cancellation transparent; wrapping it would defeat the session's `catch is CancellationError`.
            throw CancellationError()
        } catch {
            throw WPEMetalTextureLoadContextError(layerName: layerName, path: path, underlying: error)
        }
    }

    // MARK: - Texture references & resource construction

    func externalTexturePath(for reference: WPETextureReference) -> String? {
        switch reference {
        case .image(let path), .asset(let path):
            return path
        case .fbo, .previous:
            return nil
        }
    }

    /// Tag before the external-only filter. Filtering first left an auxiliary at index 0, so a junk slot-4 image aborted the scene.
    func textureReferenceRoles(
        for pass: WPEPreparedRenderPass
    ) -> [(reference: WPETextureReference, isRequired: Bool)] {
        taggedTextureReferences(for: pass).filter { $0.reference.isExternalTextureReference }
    }

    func requiredTextureReferences(for pass: WPEPreparedRenderPass) -> [WPETextureReference] {
        textureReferenceRoles(for: pass).map(\.reference)
    }

    private func taggedTextureReferences(
        for pass: WPEPreparedRenderPass
    ) -> [(reference: WPETextureReference, isRequired: Bool)] {
        switch WPEBuiltinShaderKind(normalizing: pass.pass.shader) {
        case .solidColor?, .solidLayer?:
            return []

        case .compose?:
            let first = pass.textureBindings[0] ?? pass.pass.textures[0] ?? pass.pass.source
            let second = pass.textureBindings[1] ?? pass.pass.textures[1] ?? first
            return [(first, true), (second, false)]

        case .genericImage4?:
            let primary = pass.textureBindings[0] ?? pass.pass.textures[0] ?? pass.pass.source
            var refs: [(reference: WPETextureReference, isRequired: Bool)] = [(primary, true)]
            if let mask = pass.textureBindings[1] ?? pass.pass.textures[1] {
                refs.append((mask, false))
            }
            // generic4 MODEL materials put the PBR component map (emissive mask) in slot 2.
            if let componentMap = pass.textureBindings[2] ?? pass.pass.textures[2] {
                refs.append((componentMap, false))
            }
            // MDLV clip-group masks live in renderer-internal slots. They are not shader samplers; the puppet clip encoder resolves them per group.
            for slot in pass.textureBindings.keys.sorted()
                where WPERenderTargetNames.PuppetClip.isMaskBindingSlot(slot) {
                if let mask = pass.textureBindings[slot] {
                    refs.append((mask, false))
                }
            }
            return refs

        default:
            let reference = pass.pass.binds[0]
                ?? pass.textureBindings[0]
                ?? pass.pass.textures[0]
                ?? pass.pass.source
            var refs: [(reference: WPETextureReference, isRequired: Bool)] = [(reference, true)]
            // Match the dispatcher slot span. Stopping at 4 used to miss higher authored slots until encode.
            for slot in 1..<WPEShaderTranspiler.customTextureSlotCount {
                if let extra = pass.pass.binds[slot] ?? pass.textureBindings[slot] ?? pass.pass.textures[slot] {
                    refs.append((extra, false))
                }
            }
            return refs
        }
    }


    /// `maxSourceEdge` must stay nil for callers whose consumers do math on the
    /// texture's PHYSICAL dimensions — the particle sprite-grid divides atlas
    /// pixels by sidecar frame size, so a reduced-mip upload would halve its
    /// cols/rows. Only the plain scene-layer path passes a cap.
    func makeTextureResource(
        relativePath: String,
        label: String,
        colorSpace: WPEMetalColorSpace = .sRGB,
        maxSourceEdge: Int? = nil,
        on actor: isolated WPEDisplayRenderActor
    ) async throws -> WPELoadedTextureResource {
        try Task.checkCancellation()
        var lastError: Error?
        for candidate in textureCandidates(for: relativePath) {
            try Task.checkCancellation()
            do {
                if shouldTryTexturePayload(candidate) {
                    do {
                        if let streaming = try resolveStreamingPayloadIfHeavy(candidate) {
                            let source = try textureLoader.makeLazyAnimatedTextureSource(
                                from: streaming,
                                label: label
                            )
                            // Finished off-thread decode hops back into this actor immediately (pre-3c), not on the next frame tick.
                            source.onPrefetchComplete = { [weak actor] in
                                guard let actor else { return }
                                Task { await actor.harvestLazyPrefetches() }
                            }
                            Logger.info(
                                "WPE Metal lazy .tex animation '\(candidate)' raw=\(streaming.totalUncompressedImageBytes)B frames=\(streaming.frames.count)",
                                category: .screenManager
                            )
                            return .dynamicSource(source)
                        }

                        // Same scope as the parallel lane: narrow the decode to
                        // the levels `makeTexture` below will upload. The video
                        // and animation branches are built before it applies.
                        let payload = try resourceResolver.resolveTexturePayload(
                            relativePath: candidate,
                            scope: WPEMetalTextureLoader.mipInflateScope(maxSourceEdge: maxSourceEdge)
                        )
                        try Task.checkCancellation()

                        if payload.videoPayload != nil {
                            let source = try await makeVideoTextureSource(from: payload, on: actor)
                            try Task.checkCancellation()
                            return .dynamicSource(source)
                        }
                        if payload.animationTrack != nil {
                            let source = try await textureLoader.makeAnimatedTextureSource(
                                from: payload,
                                label: label
                            )
                            attachAtlasProvider(
                                to: source,
                                eagerPayload: payload,
                                candidate: candidate,
                                label: label
                            )
                            return .dynamicSource(source)
                        }

                        return .staticTexture(try await textureLoader.makeTexture(
                            from: payload,
                            label: label,
                            colorSpace: colorSpace,
                            maxSourceEdge: maxSourceEdge
                        ))
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        lastError = error
                    }
                }
                let resolved = try resourceResolver.resolveImage(
                    relativePath: candidate,
                    maxSourceEdge: maxSourceEdge
                )
                try Task.checkCancellation()
                return .staticTexture(try await textureLoader.makeTexture(
                    from: resolved.image,
                    label: label,
                    colorSpace: colorSpace,
                    maxSourceEdge: maxSourceEdge,
                    sourcePixelSize: (resolved.sourcePixelWidth, resolved.sourcePixelHeight)
                ))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        try Task.checkCancellation()
        throw lastError ?? WPEMetalRenderExecutorError.missingTexture(.image(relativePath))
    }

    /// Hands the eager animation the mmap-backed compressed `.tex` it was built from, so
    /// `.suspended` can drop its atlases and re-upload them on resume. Skipped for two
    /// payload shapes the restore path cannot reproduce: mip-chain uploads (only re-uploads
    /// level 0), and PNG/JPEG-in-`.tex` animations, whose atlases are rasterized CGImages —
    /// the streaming payload hands back the *encoded* bytes, which would upload as garbage.
    /// `WPETexDecoder.bridgeEncodedAnimatedImagePayload` is the only animated path that
    /// returns an empty top-level `mipmaps`, which is the tell.
    private func attachAtlasProvider(
        to source: WPETexAnimatedTextureSource,
        eagerPayload: WPETexTexturePayload,
        candidate: String,
        label: String
    ) {
        guard !eagerPayload.mipmaps.isEmpty,
              !WPEMetalTextureLoader.uploadsMipChain(scalingActive: false),
              let streaming = try? resourceResolver.resolveStreamingTexturePayload(relativePath: candidate),
              let provider = WPETexAnimatedAtlasProvider(
                  payload: streaming,
                  device: executor.textureSourceDevice,
                  label: label
              ) else { return }
        if !source.attachAtlasProvider(provider) {
            debugStage("tex.eager.provider-rejected", "candidate=\(candidate)")
        }
    }

    /// Lazy only when `.tex` GPU bytes clear the threshold. Tiny sheets stay eager so they do not pay per-frame decompress.
    private func resolveStreamingPayloadIfHeavy(_ candidate: String) throws -> WPETexStreamingPayload? {
        try Task.checkCancellation()
        let probeCandidates: [String]
        let ext = (candidate as NSString).pathExtension.lowercased()
        if ext == "tex" {
            probeCandidates = [candidate]
        } else if ext.isEmpty {
            let stripped = (candidate as NSString).deletingPathExtension
            probeCandidates = [candidate, "materials/\(stripped).tex"]
        } else {
            return nil
        }

        for probe in probeCandidates {
            try Task.checkCancellation()
            let payload: WPETexStreamingPayload
            do {
                payload = try resourceResolver.resolveStreamingTexturePayload(relativePath: probe)
            } catch is CancellationError {
                throw CancellationError()
            } catch let SceneResourceResolver.ResolveError.texture(decodeError) {
                switch decodeError {
                case .unsupportedAnimation, .unsupportedFormat:
                    debugStage(
                        "tex.lazy.skip",
                        "probe=\(probe) reason=\(decodeError)"
                    )
                    continue
                default:
                    debugStage(
                        "tex.lazy.skip",
                        "probe=\(probe) decodeError=\(decodeError)"
                    )
                    continue
                }
            } catch SceneResourceResolver.ResolveError.fileMissing,
                    SceneResourceResolver.ResolveError.unsupportedTexture {
                continue
            } catch {
                debugStage(
                    "tex.lazy.skip",
                    "probe=\(probe) error=\(error)"
                )
                continue
            }
            let gpuBytes = Self.eagerAnimationGPUBytes(of: payload)
            if !Self.shouldUseLazyAnimationRepresentation(
                payload,
                threshold: Self.lazyAnimationRawByteThreshold
            ) {
                let reason = payload.frames.contains { frame in
                    guard let descriptor = frame.samplingDescriptor else { return false }
                    return descriptor.rotation.y != 0 || descriptor.rotation.z != 0
                }
                    ? "cross-axis TEXS requires eager atlas sampling"
                    : "gpu=\(gpuBytes)B below threshold"
                debugStage(
                    "tex.lazy.skip",
                    "probe=\(probe) reason=\(reason)"
                )
                continue
            }
            debugStage(
                "tex.lazy.hit",
                "probe=\(probe) gpu=\(gpuBytes)B images=\(payload.compressedImages.count) frames=\(payload.frames.count)"
            )
            return payload
        }
        return nil
    }

    private func makeVideoTextureSource(
        from payload: WPETexTexturePayload,
        on actor: isolated WPEDisplayRenderActor
    ) async throws -> WPEVideoTextureSource {
        try Task.checkCancellation()
        guard let videoPayload = payload.videoPayload else {
            throw WPEMetalTextureLoaderError.malformedPayload("missing video payload")
        }
        // Disk cache keyed by workshop ID + content hash so launch GC can reclaim uninstalled scenes.
        let url = try await WPEVideoTextureDiskCache.shared.store(
            videoPayload.bytes,
            workshopID: descriptor.workshopID
        )
        do {
            try Task.checkCancellation()
            let outputPixelSize = await Self.videoOutputPixelSize(
                fileURL: url,
                drawableSize: surfaceDrawableSize,
                latchedTextureCap: latchedTextureCap
            )
            let source = try WPEVideoTextureSource(
                device: executor.textureSourceDevice,
                videoURL: url,
                commandQueue: executor.textureSourceCommandQueue,
                // Release the lease (keep the file); the cache owns lifetime now.
                onInvalidate: { staleURL in
                    Task.detached(priority: .utility) {
                        await WPEVideoTextureDiskCache.shared.release(staleURL)
                    }
                },
                outputPixelSize: outputPixelSize,
                decoderAdmission: .shared
            )
            return source
        } catch {
            await WPEVideoTextureDiskCache.shared.release(url)
            throw error
        }
    }

    static func videoOutputPixelSize(
        fileURL: URL,
        drawableSize: CGSize,
        latchedTextureCap: Int?
    ) async -> CGSize? {
        guard let maxEdge = WPEVideoOutputCap.maxOutputEdge(
            drawableSize: drawableSize,
            latchedTextureCap: latchedTextureCap
        ) else {
            return nil
        }
        guard let source = await WPEVideoOutputCap.sourceDisplaySize(fileURL: fileURL) else {
            return nil
        }
        return WPEVideoOutputCap.clampedPixelSize(source: source, maxEdge: maxEdge)
    }

    func makeDynamicPlaceholderTexture(label: String) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: WPEMetalRenderExecutor.outputPixelFormat,
            width: 1,
            height: 1,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = executor.textureSourceDevice.makeTexture(descriptor: descriptor) else {
            throw WPEMetalTextureLoaderError.textureAllocationFailed
        }
        texture.label = label
        WPEMetalTextureMetadataRegistry.shared.register(texture: texture)
        var pixel: UInt32 = 0
        texture.replace(
            region: MTLRegionMake2D(0, 0, 1, 1),
            mipmapLevel: 0,
            withBytes: &pixel,
            bytesPerRow: 4
        )
        return texture
    }

    // MARK: - Static texture cache & LRU budget

    func recordLoadedStaticTexture(
        path: String,
        layerName: String,
        candidates: [String],
        texture: MTLTexture
    ) {
        loadedTextures[path] = texture
        staticTexturePlaceholderPaths.remove(path)
        staticTextureReloadThrottles.removeValue(forKey: path)
        let bytes = Self.textureResidentBytes(for: texture)
        staticTextureCacheRecords[path] = StaticTextureCacheRecord(
            layerName: layerName,
            candidates: candidates,
            bytes: bytes
        )
        staticTextureRecordsEpoch += 1
        if textureCacheBudgetBytesInUse != nil {
            textureCacheLRU.admit(path, bytes: bytes)
        }
    }

    private func forgetStaticTextureCacheRecord(_ path: String) {
        staticTextureCacheRecords.removeValue(forKey: path)
        staticTexturePlaceholderPaths.remove(path)
        staticTextureReloadThrottles.removeValue(forKey: path)
        staticTextureRecordsEpoch += 1
        textureCacheLRU.remove(path)
    }

    private func resetTextureCacheBudgetState() {
        staticTextureCacheRecords.removeAll(keepingCapacity: false)
        staticTexturePlaceholderPaths.removeAll(keepingCapacity: false)
        staticTextureReloadThrottles.removeAll(keepingCapacity: false)
        cachedActiveStaticPaths.removeAll(keepingCapacity: false)
        cachedActiveStaticSignature = nil
        staticTextureRecordsEpoch += 1
        textureCacheLRU.removeAll()
        textureCacheBudgetBytesInUse = nil
    }

    private func activateTextureCacheBudget(_ budgetBytes: Int) {
        guard textureCacheBudgetBytesInUse != budgetBytes else { return }
        textureCacheLRU = WPEMetalTextureCacheLRU(budgetBytes: budgetBytes)
        textureCacheBudgetBytesInUse = budgetBytes
        for (path, record) in staticTextureCacheRecords
        where loadedTextures[path] != nil && !staticTexturePlaceholderPaths.contains(path) {
            textureCacheLRU.admit(path, bytes: record.bytes)
        }
    }

    private func deactivateTextureCacheBudget() {
        guard textureCacheBudgetBytesInUse != nil else { return }
        textureCacheBudgetBytesInUse = nil
        textureCacheLRU.removeAll()
        // Budget off mid-session: reload evicted textures so the eager-resident invariant holds again.
        for path in staticTextureCacheRecords.keys where loadedTextures[path] == nil {
            scheduleStaticTextureReload(for: path)
        }
    }

    private func activeStaticTexturePaths(for pipeline: WPEPreparedRenderPipeline) -> Set<String> {
        var hasher = Hasher()
        hasher.combine(loadGeneration)
        hasher.combine(staticTextureRecordsEpoch)
        hasher.combine(pipeline.layers.count)
        for layer in pipeline.layers {
            hasher.combine(layer.graphLayer.objectID)
            hasher.combine(layer.graphLayer.visible)
            hasher.combine(layer.passes.count)
        }
        let signature = hasher.finalize()
        if signature == cachedActiveStaticSignature {
            return cachedActiveStaticPaths
        }
        let paths = activeExternalTexturePaths(for: pipeline).filter { staticTextureCacheRecords[$0] != nil }
        cachedActiveStaticPaths = paths
        cachedActiveStaticSignature = signature
        return paths
    }

    private func activeExternalTexturePaths(for pipeline: WPEPreparedRenderPipeline) -> Set<String> {
        var paths = Set<String>()
        for layer in pipeline.layers {
            // Pass-less visible image layers still encodeCopy, so their texture must stay protected.
            if layer.passes.isEmpty {
                if layer.graphLayer.visible,
                   let path = externalTexturePath(for: .image(layer.graphLayer.imagePath)) {
                    paths.insert(path)
                }
                continue
            }
            for pass in layer.passes {
                // Hidden layers still encode composite/FBO (dependents may sample them); only scene draw is skipped.
                if !layer.graphLayer.visible {
                    switch pass.pass.target {
                    case .scene:
                        continue
                    case .layerComposite, .fbo:
                        break
                    }
                }
                for reference in requiredTextureReferences(for: pass) {
                    if let path = externalTexturePath(for: reference) {
                        paths.insert(path)
                    }
                }
            }
        }
        return paths
    }

    private func ensureActiveStaticTexturesResident(_ activePaths: Set<String>) throws {
        for path in activePaths {
            if loadedTextures[path] == nil {
                loadedTextures[path] = try makeDynamicPlaceholderTexture(label: "\(path) static placeholder")
                staticTexturePlaceholderPaths.insert(path)
            }
            if staticTexturePlaceholderPaths.contains(path) {
                scheduleStaticTextureReload(for: path)
            }
        }
    }

    private func touchStaticTextureCache(paths: Set<String>) {
        for path in paths {
            textureCacheLRU.touch(path)
        }
    }

    private func evictInactiveStaticTextures(protecting protected: Set<String>) {
        let evicted = textureCacheLRU.evictOverBudget(protecting: protected)
        for path in evicted {
            loadedTextures.removeValue(forKey: path)
            staticTexturePlaceholderPaths.remove(path)
            Logger.info("[WPE.texture-cache] evicted static texture path=\(path)", category: .wpeRender)
        }
    }

    /// Shares `WPEMetalTextureByteEstimator` with the memory-audit census so
    /// diagnostics and the LRU budget count the same bytes.
    static func textureResidentBytes(for texture: MTLTexture) -> Int {
        WPEMetalTextureByteEstimator.estimatedBytes(of: texture)
    }

    // MARK: - Per-frame textures

    func texturesForCurrentFrame(
        time: TimeInterval,
        pipeline: WPEPreparedRenderPipeline,
        frameSlot: Int
    ) throws -> [String: MTLTexture] {
        // Collected in the same walk that ticks the sources: a video source that just
        // decoded a frame hands back the texture its conversion pass will write, and that
        // pass must be encoded into this frame's scene command buffer before any pass samples
        // it. Load-time decodes (a still frame published from `init`) are caught here too —
        // still staged on the first frame that walks the dictionary.
        var stagedWork: [any WPEDynamicTextureSource] = []
        var samplingDescriptors: [String: WPETexSpriteSamplingDescriptor] = [:]
        samplingDescriptors.reserveCapacity(dynamicTextureSources.count)
        for (path, source) in dynamicTextureSources {
            if let texture = source.texture(at: time, frameSlot: frameSlot) {
                loadedTextures[path] = texture
                if let descriptor = source.samplingDescriptor(at: time, frameSlot: frameSlot) {
                    samplingDescriptors[path] = descriptor
                }
            }
            if source.hasStagedFrameWork {
                stagedWork.append(source)
            }
        }
        loadedTextureSamplingDescriptors = samplingDescriptors
        executor.stageTextureWork(stagedWork)

        // Skip the active-path walk unless the budget is/was on or a placeholder still awaits reload.
        if textureCacheBudgetBytesResolved != nil
            || textureCacheBudgetBytesInUse != nil
            || !staticTexturePlaceholderPaths.isEmpty {
            let activeStaticPaths = activeStaticTexturePaths(for: pipeline)
            try ensureActiveStaticTexturesResident(activeStaticPaths)
            if let budgetBytes = textureCacheBudgetBytesResolved {
                activateTextureCacheBudget(budgetBytes)
                touchStaticTextureCache(paths: activeStaticPaths)
                evictInactiveStaticTextures(protecting: activeStaticPaths)
            } else {
                deactivateTextureCacheBudget()
            }
        }
        return loadedTextures
    }

    /// `.suspended` releases the eager animation atlases, but `loadedTextures`
    /// still holds the last atlas each source handed out — without dropping
    /// those bindings the release frees nothing. The first resumed frame
    /// re-populates them from the restored atlases before encode reads the map.
    func purgeReleasedAnimatedTextureBindings() {
        for (path, source) in dynamicTextureSources {
            guard let animated = source as? WPETexAnimatedTextureSource,
                  animated.hasReleasedAtlases else { continue }
            loadedTextures.removeValue(forKey: path)
        }
    }

    func releaseDynamicTextureSources() {
        executor.stageTextureWork([])
        dynamicTextureSources.values.forEach { $0.invalidate() }
        dynamicTextureSources.removeAll()
        loadedTextures.removeAll()
        loadedTextureSamplingDescriptors.removeAll()
        resetTextureCacheBudgetState()
    }

    private func shouldTryTexturePayload(_ path: String) -> Bool {
        Self.shouldTryTexturePayload(path)
    }

    /// `nonisolated` twin for the off-actor lane: same `.tex`-vs-raster decision as the on-actor path.
    private nonisolated static func shouldTryTexturePayload(_ path: String) -> Bool {
        let extensionName = (path as NSString).pathExtension.lowercased()
        return !knownRawImageExtensions.contains(extensionName)
    }

    /// ImageIO raster extensions taken at face value. A name that merely contains a dot still goes through the materials/ fallback.
    nonisolated static let knownRawImageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "tga", "dds", "bmp", "gif", "webp"
    ]

    // MARK: - Path candidate resolution

    func textureCandidates(for path: String) -> [String] {
        let extensionName = (path as NSString).pathExtension.lowercased()
        if extensionName == "tex" || extensionName == "json" {
            return [path]
        }
        if !extensionName.isEmpty, Self.knownRawImageExtensions.contains(extensionName) {
            // Converted sources live as `<name>.<ext>.tex`; try literal, converted, and `materials/`.
            var candidates = [path, "\(path).tex"]
            let anchored = ["materials/", "models/", "shaders/", "fonts/",
                            "scripts/", "particles/", "sounds/", "scenes/", "../", "_"]
            if !anchored.contains(where: path.hasPrefix) {
                candidates.append("materials/\(path)")
                candidates.append("materials/\(path).tex")
            }
            return candidates
        }

        if let dependency = dependencyReference(path) {
            let child = dependency.childPath
            if child.contains("/") {
                return [
                    path,
                    "\(path).tex",
                    "\(path).png",
                    "\(path).jpg",
                    "\(path).jpeg"
                ]
            }
            let prefix = "../\(dependency.workshopID)"
            return [
                "\(prefix)/materials/\(child).tex",
                "\(prefix)/materials/\(child).png",
                "\(prefix)/materials/\(child).jpg",
                "\(prefix)/materials/\(child).jpeg",
                path
            ]
        }

        if path.hasPrefix("_"), !path.hasPrefix("__") {
            return [path]
        }

        if path.contains("/") {
            let anchoredPrefixes = ["materials/", "models/", "shaders/", "fonts/", "scripts/", "particles/", "sounds/", "scenes/"]
            if anchoredPrefixes.contains(where: path.hasPrefix) {
                var candidates = [
                    path,
                    "\(path).tex",
                    "\(path).png",
                    "\(path).jpg",
                    "\(path).jpeg"
                ]
                // `models/` is not exclusive for material texture slots (3589454154 asteroid/ring: `models/foo/diffuse` → `materials/models/foo/diffuse.tex`).
                if path.hasPrefix("models/") {
                    candidates.insert(contentsOf: [
                        "materials/\(path).tex",
                        "materials/\(path).png",
                        "materials/\(path).jpg",
                        "materials/\(path).jpeg"
                    ], at: 0)
                }
                return candidates
            }
            return [
                "materials/\(path).tex",
                "materials/\(path).png",
                "materials/\(path).jpg",
                "materials/\(path).jpeg",
                path,
                "\(path).tex",
                "\(path).png",
                "\(path).jpg",
                "\(path).jpeg"
            ]
        }

        return [
            "materials/\(path).tex",
            "materials/\(path).png",
            "materials/\(path).jpg",
            "materials/\(path).jpeg",
            path
        ]
    }

    private func dependencyReference(_ relativePath: String) -> (workshopID: String, childPath: String)? {
        guard relativePath.hasPrefix("../") else { return nil }
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[0] == ".." else { return nil }
        return (String(parts[1]), parts.dropFirst(2).joined(separator: "/"))
    }

    // MARK: - Load diagnostics

    func diagnostic(for error: Error) -> SceneLoadDiagnostic {
        diagnostic(for: error, fallbackPath: nil, layerName: "scene")
    }

    func diagnostic(
        for error: Error,
        fallbackPath: String?,
        layerName: String
    ) -> SceneLoadDiagnostic {
        switch error {
        case let context as WPEMetalTextureLoadContextError:
            return diagnostic(
                for: context.underlying,
                fallbackPath: context.path,
                layerName: context.layerName
            )
        case let executorError as WPEMetalRenderExecutorError:
            switch executorError {
            case .unsupportedShader(let name):
                return .materialUnresolved(layer: layerName, reason: String(localized: "Shader \"\(name)\" is not supported by the Metal renderer yet.", bundle: .appLanguage, comment: "Scene load diagnostic. Placeholder is the shader name."))
            case .shaderTranslatorUnavailable(let name, let reason):
                return .materialUnresolved(
                    layer: layerName,
                    reason: String(localized: "Shader \"\(name)\" needs the WPE GLSL translator: \(reason)", bundle: .appLanguage, comment: "Scene load diagnostic. Placeholders are the shader name and the translator failure.")
                )
            case .pipelineStateBuildFailed(let name, let detail):
                return .materialUnresolved(
                    layer: layerName,
                    reason: String(localized: "Metal pipeline for \"\(name)\" failed to build: \(detail)", bundle: .appLanguage, comment: "Scene load diagnostic. Placeholders are the pipeline name and the Metal error.")
                )
            case .renderTargetDimensionsExceedDeviceLimit(let targetName, let width, let height, let limit):
                return .materialUnresolved(
                    layer: layerName,
                    reason: String(localized: "Render target \"\(targetName)\" is \(width)x\(height), exceeding this device's \(limit)x\(limit) Metal texture limit.", bundle: .appLanguage, comment: "Scene load diagnostic. Placeholders are the target name, its width and height, then the device texture limit twice.")
                )
            case .missingTexture(let reference):
                switch reference {
                case .image(let path), .asset(let path):
                    return .fileMissing(layer: layerName, path: path)
                case .fbo(let name):
                    // Named RT, not a file. Unwritten declared FBOs are zero-filled; reaching here is an undeclared target (graph/transpile bug).
                    return .materialUnresolved(
                        layer: layerName,
                        reason: String(localized: "Render target \"\(name)\" is not produced by any pass.", bundle: .appLanguage, comment: "Scene load diagnostic. Placeholder is the render target name.")
                    )
                case .previous:
                    return .materialUnresolved(layer: layerName, reason: String(localized: "Previous-frame effects (motion blur, feedback) are not yet supported.", bundle: .appLanguage, comment: "Scene load diagnostic."))
                }
            case .noRenderablePasses:
                return .materialUnresolved(layer: layerName, reason: String(localized: "Scene contains no renderable passes.", bundle: .appLanguage, comment: "Scene load diagnostic."))
            case .commandQueueUnavailable, .libraryUnavailable, .pipelineUnavailable, .commandBufferFailed:
                return .other(layer: layerName, message: executorError.errorDescription ?? String(localized: "Metal renderer failed.", bundle: .appLanguage, comment: "Scene load diagnostic fallback when the executor error carries no description."))
            }
        case let loaderError as WPEMetalTextureLoaderError:
            switch loaderError {
            case .unsupportedFormat, .unsupportedCompressedFormat, .malformedPayload, .textureAllocationFailed:
                return .other(layer: layerName, message: loaderError.errorDescription ?? String(localized: "Texture upload failed.", bundle: .appLanguage, comment: "Scene load diagnostic fallback when the texture loader error carries no description."))
            }
        case let resolveError as SceneResourceResolver.ResolveError:
            switch resolveError {
            case .fileMissing:
                return .fileMissing(layer: layerName, path: fallbackPath ?? descriptor.entryFile)
            case .pathEscape:
                return .crossPackageReference(layer: layerName, path: fallbackPath ?? descriptor.entryFile)
            case .materialUnresolved(let reason):
                return .materialUnresolved(layer: layerName, reason: reason)
            case .texture(let texError):
                return .texture(layer: layerName, error: texError)
            case .unsupportedTexture:
                return .legacyUnsupportedTexture(layer: layerName)
            case .decodeFailed:
                return .other(
                    layer: layerName,
                    message: String(
                        localized: "A texture or image file is corrupted and cannot be decoded.",
                        defaultValue: "A texture or image file is corrupted and cannot be decoded.",
                        bundle: .appLanguage, comment: "Wallpaper Engine fallback diagnostic when a texture decode fails because the file is corrupt."
                    )
                )
            }
        default:
            return .other(layer: layerName, message: error.localizedDescription)
        }
    }
}

private extension WPETextureReference {
    var isExternalTextureReference: Bool {
        switch self {
        case .image, .asset:
            return true
        case .fbo, .previous:
            return false
        }
    }
}
#endif
