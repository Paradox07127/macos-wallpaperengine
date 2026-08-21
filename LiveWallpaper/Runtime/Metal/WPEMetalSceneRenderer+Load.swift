#if !LITE_BUILD
import AppKit
import LiveWallpaperCore
import LiveWallpaperProWPE
import MetalKit

extension WPEMetalSceneRenderer {
    // MARK: - Load entry point

    func load(on actor: isolated WPEDisplayRenderActor) async throws {
        guard !didLoad else { return }
        let descriptorSummary = "\(descriptor.workshopID) tier=\(descriptor.capabilityTier.rawValue) entry=\(descriptor.entryFile)"
        WPESceneDebugArtifacts.shared.beginSession(
            workshopID: descriptor.workshopID,
            descriptor: descriptorSummary
        )
        #if !LITE_BUILD && DEBUG
        WPECanonicalTraceRecorder.shared.beginScene(
            workshopID: descriptor.workshopID,
            projectJsonPath: projectManifestRootURL?.appendingPathComponent(descriptor.entryFile).path,
            descriptor: descriptorSummary
        )
        #endif
        loadGeneration &+= 1
        let generation = loadGeneration
        completedPresentGeneration = nil
        failedPresentGeneration = nil
        let scriptLoadToken = sceneScriptLoadState.begin(generation: generation)
        invalidateIntroPhaseAlign()
        debugStage("load.begin", descriptorSummary)
        do {
            try await performLoad(scriptLoadToken: scriptLoadToken, on: actor)
            try Task.checkCancellation()
            try checkCurrentSceneScriptLoad(scriptLoadToken)
            await staticTextureReloadTaskOwner.resume(generation: generation)
            loadDiagnostics = nil
            logMemoryAuditIfEnabled()
            WPESceneDebugArtifacts.shared.recordResolutionSummary(resolutionTracer.snapshot())
            WPESceneDebugArtifacts.shared.appendLog(
                "load() succeeded; rendered first texture; awaiting present",
                level: .notice
            )
            if let snapshot = cachedSnapshot {
                WPESceneDebugArtifacts.shared.recordFirstFrame(image: snapshot)
            }
            WPESceneDebugArtifacts.shared.endSession()
        } catch {
            let ownedFailedLoad = isCurrentSceneScriptLoad(scriptLoadToken)
            sceneScriptLoadState.retire(scriptLoadToken)
            if ownedFailedLoad { clearSceneScriptRuntimeState() }
            didLoad = false
            _ = await staticTextureReloadTaskOwner.quiesce()
            loadDiagnostics = diagnostic(for: error)
            logSceneFailureDiagnostics(error: error)
            WPESceneDebugArtifacts.shared.recordResolutionSummary(resolutionTracer.snapshot())
            WPESceneDebugArtifacts.shared.appendLog(
                "load() failed: \(error)",
                level: .error
            )
            if let snapshot = cachedSnapshot {
                WPESceneDebugArtifacts.shared.recordFirstFrame(image: snapshot)
            }
            WPESceneDebugArtifacts.shared.endSession()
            if let reason = Self.metalUnsupportedReason(for: error) {
                throw SceneRenderingError.metalRendererUnsupported(reason: reason)
            }
            throw error
        }
    }

    // MARK: - Failure diagnostics

    private static func metalUnsupportedReason(for error: Error) -> String? {
        switch error {
        case let context as WPEMetalTextureLoadContextError:
            return metalUnsupportedReason(for: context.underlying)
        case let executorError as WPEMetalRenderExecutorError:
            switch executorError {
            case .shaderTranslatorUnavailable(let name, let reason):
                return "shader '\(name)': \(reason)"
            case .unsupportedShader(let name):
                return "shader '\(name)' unsupported by Metal renderer"
            case .unsupportedTarget:
                return "unsupported Metal render target"
            case .pipelineStateBuildFailed(let name, let detail):
                return "Metal pipeline '\(name)' rejected (likely stage_in mismatch): \(detail)"
            case .renderTargetDimensionsExceedDeviceLimit(let targetName, let width, let height, let limit):
                return "render target '\(targetName)' is \(width)x\(height), exceeding this device's \(limit)x\(limit) Metal texture limit"
            case .missingTexture(let reference):
                switch reference {
                case .previous:
                    return "previous-frame texture unavailable for this pass — no prior frame was rendered for its target"
                case .fbo(let name):
                    return "named FBO '\(name)' unresolved on Metal pass — likely cross-pass alias miss"
                case .image, .asset:
                    return nil
                }
            case .commandQueueUnavailable, .libraryUnavailable, .pipelineUnavailable, .commandBufferFailed, .noRenderablePasses:
                return nil
            }
        default:
            return nil
        }
    }

    private func logSceneFailureDiagnostics(error: Error) {
        let snapshot = resolutionTracer.snapshot()
        let workshopID = descriptor.workshopID
        Logger.error(
            "Scene \(workshopID) failed: \(error)",
            category: .screenManager
        )
        let counts = snapshot.resolvedByOrigin
        let dependencyCount = counts.reduce(0) { partial, entry in
            if case .dependency = entry.key { return partial + entry.value }
            return partial
        }
        Logger.notice(
            "Scene \(workshopID) resolution summary — events:\(snapshot.events.count) resolved:\(snapshot.resolvedCount) scene:\(counts[.scene, default: 0]) builtin:\(counts[.builtin, default: 0]) engineAssets:\(counts[.engineAssets, default: 0]) dependency:\(dependencyCount)",
            category: .screenManager
        )
        let missed = snapshot.missedRefs
        if !missed.isEmpty {
            let summary = missed.prefix(40)
                .map { "\($0.ref) → \($0.finalOutcome.debugLabel)" }
                .joined(separator: " | ")
            let suffix = missed.count > 40 ? " | +\(missed.count - 40) more" : ""
            Logger.notice(
                "Scene \(workshopID) misses (top 40 of \(missed.count)): \(summary)\(suffix)",
                category: .screenManager
            )
        }
    }

    // MARK: - Scene construction

    private func performLoad(
        scriptLoadToken: WPESceneScriptInstanceLimitToken,
        on actor: isolated WPEDisplayRenderActor
    ) async throws {
        let id = descriptor.workshopID

        debugStage("read.entry", "resolving \(descriptor.entryFile)")
        onProgress?(String(localized: "Reading scene", comment: "Scene load progress: parsing the scene package."))
        try Task.checkCancellation()
        let entryReader = entryResolver
        let sceneDescriptor = descriptor
        let sceneCacheRoot = projectManifestRootURL ?? cacheRootURL
        let parsedDocument = try await Task.detached(priority: .userInitiated) {
            let data = try entryReader.data(relativePath: sceneDescriptor.entryFile)
            let userValues = WallpaperEngineProjectPropertySchema.effectiveSceneValues(
                descriptor: sceneDescriptor,
                cacheRootURL: sceneCacheRoot
            )
            // Empty dump ⇒ project.json never loaded and every `{"user":K}` envelope used its baked literal.
            WPESceneDebugArtifacts.shared.recordNoteOnce(
                name: "user-properties.txt",
                contents: "manifestRoot: \(sceneCacheRoot.path)\ncount: \(userValues.count)\n"
                    + userValues.sorted { $0.key < $1.key }
                        .map { "\($0.key) = \($0.value)" }
                        .joined(separator: "\n")
            )
            return try WPESceneDocumentParser.parse(data: data, userValues: userValues)
        }.value
        try checkCurrentSceneScriptLoad(scriptLoadToken)
        // Promote text to image layers before the graph so paint order / effects / parallax share one graph. After-the-fact overlay cannot hide a later character.
        let textFonts = WPETextFontResolver(resolver: resourceResolver)
        textRenderPlans = WPETextRenderPlanner.plans(for: parsedDocument, fonts: textFonts)
        textFontResolver = textFonts
        let document = parsedDocument.appendingImageObjects(textRenderPlans.map(\.imageObject))
        debugStage("read.entry.done", "imageObjects=\(document.imageObjects.count) particles=\(document.particleObjects.count) text=\(document.textObjects.count) textLayers=\(textRenderPlans.count) sound=\(document.soundObjects.count)")
        let scriptInventory = WPESceneScriptInstanceInventory(document: document)
        if !scriptLoadToken.prepare(scriptInventory) {
            // Not a count cap — fires only when the load was already prepared or retired (interleaved reload).
            Logger.warning(
                "Scene \(id) script load token rejected its inventory of \(scriptInventory.total) runtimes"
                    + " (already prepared or retired); runtime scripts are disabled for this load",
                category: .wpeRender
            )
        }
        // Diagnostic only (2955378002: 676 bindings, 124 distinct). Every binding still gets its own runtime.
        let reuse = WPESceneScriptInstanceInventory.sourceReuse(in: document)
        debugStage(
            "scripts.inventory",
            "runtimes=\(scriptInventory.total) bindings=\(reuse.bindings) "
                + "distinct=\(reuse.distinct) maxRepeat=\(reuse.maxRepeat)"
        )
        try Task.checkCancellation()

        debugStage("graph.build", "begin")
        onProgress?(String(localized: "Building render graph", comment: "Scene load progress: building the render graph."))
        let cacheRoot = cacheRootURL
        let mounts = dependencyMounts
        let engineRoot = effectiveEngineAssetsRootURL
        let provider = sceneAssetProvider
        let graph = try await Task.detached(priority: .userInitiated) {
            let builder = provider.map {
                WPERenderGraphBuilder(primaryProvider: $0, dependencyMounts: mounts, engineAssetsRootURL: engineRoot)
            } ?? WPERenderGraphBuilder(cacheRootURL: cacheRoot, dependencyMounts: mounts, engineAssetsRootURL: engineRoot)
            return try builder.build(document: document)
        }.value
        try checkCurrentSceneScriptLoad(scriptLoadToken)
        debugStage("graph.build.done", "layers=\(graph.layers.count)")
        try Task.checkCancellation()

        debugStage("pipeline.build", "begin")
        onProgress?(String(localized: "Preparing render pipeline", comment: "Scene load progress: compiling Metal pipeline state."))
        let pipeline = try await Task.detached(priority: .userInitiated) {
            let builder = provider.map {
                WPERenderPipelineBuilder(primaryProvider: $0, dependencyMounts: mounts, engineAssetsRootURL: engineRoot)
            } ?? WPERenderPipelineBuilder(cacheRootURL: cacheRoot, dependencyMounts: mounts, engineAssetsRootURL: engineRoot)
            return try builder.build(graph: graph)
        }.value
        try checkCurrentSceneScriptLoad(scriptLoadToken)
        let passCount = pipeline.layers.reduce(0) { $0 + $1.passes.count }
        debugStage("pipeline.build.done", "passes=\(passCount)")
        for layer in pipeline.layers {
            for preparedPass in layer.passes {
                let p = preparedPass.pass
                let target: String = {
                    switch p.target {
                    case .scene: return "scene"
                    case .layerComposite(let n): return "comp:\(n)"
                    case .fbo(let n): return "fbo:\(n)"
                    }
                }()
                let source: String = {
                    switch p.source {
                    case .image(let v): return "img:\(v)"
                    case .asset(let v): return "asset:\(v)"
                    case .fbo(let v): return "fbo:\(v)"
                    case .previous: return "previous"
                    }
                }()
                let combos = p.combos.isEmpty
                    ? "-"
                    : p.combos.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
                debugStage(
                    "pipeline.pass",
                    "layer=\(layer.graphLayer.objectName) id=\(p.id) shader=\(p.shader) src=\(source) tgt=\(target) blend=\(p.blending) combos=\(combos)"
                )
            }
        }
        WPESceneDebugArtifacts.shared.recordPassList(pipeline)
        try Task.checkCancellation()

        renderGraph = graph
        renderPipeline = pipeline
        createdLayerTemplatesByImagePath = Self.createdLayerTemplatesByImagePath(pipeline)
        executor.invalidateStaticLayerCache()
        textureCacheBudgetBytesResolved = Self.textureCacheBudgetBytes
        hasAnimatedShaderPasses = Self.pipelineHasAnimatedPasses(pipeline)
        scenePropertyBindings = document.propertyBindings
        objectParentByID = document.objectParentByID
        ownVisibilityByID = document.ownVisibilityByID
        liveLayerVisibility = Dictionary(
            document.imageObjects.map { ($0.id, $0.visible) },
            uniquingKeysWith: { first, _ in first }
        )
        liveTextVisibility = Dictionary(
            document.textObjects.map { ($0.id, $0.visible) },
            uniquingKeysWith: { first, _ in first }
        )
        cameraUniforms = WPEMetalCameraUniforms(
            orthogonalProjection: document.general.orthogonalProjection,
            sceneCamera: document.camera,
            usesPerspectiveProjection: document.general.usesPerspectiveProjection,
            lightAmbientColor: document.general.lightAmbientColor,
            lightSkylightColor: document.general.lightSkylightColor,
            sceneHDR: document.general.hdr,
            bloom: document.general.bloom
        )
        // Perspective has no authored pixel canvas. Render at drawable size (4K cap, never below authored) so HUD text stays 1:1. Kill switch: WPEMetalPerspectiveNativeResolution -bool NO.
        if document.general.usesPerspectiveProjection,
           Self.perspectiveNativeResolutionEnabled {
            let drawable = surfaceDrawableSize
            let base = cameraUniforms.renderSize
            let cap = CGSize(width: 3840, height: 2160)
            var targetW = min(max(drawable.width, base.width), cap.width)
            var targetH = min(max(drawable.height, base.height), cap.height)
            // Clamp to the memory tier (HDR float16 counts double) so native-res + bloom do not OOM 8/16 GB Macs.
            let budget = WPEMemoryTier.current.perspectiveRenderPixelBudget(hdr: document.general.hdr)
            let pixels = Double(targetW * targetH)
            if pixels > budget {
                let shrink = (budget / pixels).squareRoot()
                targetW = max(base.width, (targetW * CGFloat(shrink)).rounded())
                targetH = max(base.height, (targetH * CGFloat(shrink)).rounded())
            }
            // MetalFX render-scale experiment: render below the drawable and let
            // the spatial scaler upscale at present. When the scaled target
            // drops to (or under) the authored base, the rebuild guard below
            // keeps renderSize at base — still eligible for scaler upscaling.
            if WPEMetalFXSpatialUpscaler.isExperimentEnabled {
                targetW = WPEMetalFXSpatialUpscaler.scaledDimension(targetW)
                targetH = WPEMetalFXSpatialUpscaler.scaledDimension(targetH)
            }
            if targetW > base.width + 1 || targetH > base.height + 1 {
                cameraUniforms = WPEMetalCameraUniforms(
                    orthogonalProjection: WPESceneOrthogonalProjection(
                        width: targetW, height: targetH, auto: false
                    ),
                    sceneCamera: document.camera,
                    usesPerspectiveProjection: true,
                    lightAmbientColor: document.general.lightAmbientColor,
                    lightSkylightColor: document.general.lightSkylightColor,
                    sceneHDR: document.general.hdr,
                    bloom: document.general.bloom
                )
            }
        }
        cameraParallaxSettings = document.general.cameraParallax
        // Rigid-subtree walk needs groups too: a clock text's chain runs through non-drawn hosts before the depth/origin ancestor.
        parallaxAuthoredDepthByObjectID = WPERenderGraphBuilder.authoredParallaxDepthByObjectID(document)
        var authoredOrigins: [String: SIMD2<Double>] = [:]
        for object in document.imageObjects { authoredOrigins[object.id] = SIMD2<Double>(object.origin.x, object.origin.y) }
        for object in document.textObjects { authoredOrigins[object.id] = SIMD2<Double>(object.origin.x, object.origin.y) }
        for object in document.particleObjects { authoredOrigins[object.id] = SIMD2<Double>(object.origin.x, object.origin.y) }
        for object in document.transformHostObjects { authoredOrigins[object.id] = SIMD2<Double>(object.origin.x, object.origin.y) }
        parallaxAuthoredOriginByObjectID = authoredOrigins
        executor.parallaxObjectParentByID = document.objectParentByID
        executor.parallaxHostDepthByObjectID = parallaxAuthoredDepthByObjectID
        executor.parallaxHostOriginByObjectID = authoredOrigins
        // Authored flag is shader-driven only. Script audio (`usesAudioAPI`) needs capture or the broker stays silent.
        sceneSupportsAudioProcessing = document.general.supportsAudioProcessing
            || WPESceneScriptInstanceInventory.usesAudioAPI(in: document)
        cameraParallaxSmoother.reset()
        sceneRenderSize = cameraUniforms.renderSize
        debugStage("camera", "renderSize=\(Int(sceneRenderSize.width))x\(Int(sceneRenderSize.height))")
        try checkCurrentSceneScriptLoad(scriptLoadToken)
        // Before any loader's `installSandbox`, so they see resolved `engine.userProperties` instead of the `?? WPESharedScriptState(...)` fallback.
        sceneScriptSharedState = WPESharedScriptState(
            sceneScriptLoadToken: scriptLoadToken,
            userProperties: currentSceneScriptUserProperties(),
            layers: Self.scriptLayerTable(for: document)
        )
        loadDynamicOriginScripts(from: document, scriptLoadToken: scriptLoadToken)
        loadEffectConstantScripts(from: pipeline, document: document, scriptLoadToken: scriptLoadToken)
        loadEffectVisibilityScripts(from: pipeline, scriptLoadToken: scriptLoadToken)

        // Child task on the actor, not `async let` (that would send `self` into a concurrent child). Awaited before the first sync render.
        let shaderWarmTask = Task { [actor] in
            await actor.prewarmShaders(pipeline: pipeline)
        }

        debugStage("textures.load", "begin (pipeline-driven)")
        onProgress?(String(localized: "Loading textures", comment: "Scene load progress: uploading textures."))
        try await loadTextures(for: pipeline, on: actor)
        try checkCurrentSceneScriptLoad(scriptLoadToken)
        indexOnDemandVideoLayers(pipeline: pipeline)
        debugStage("textures.load.done", "loaded=\(loadedTextures.count) dynamic=\(dynamicTextureSources.count)")
        dumpLoadedTexturesIfRequested()
        try Task.checkCancellation()

        debugStage("particles.load", "begin")
        onProgress?(String(localized: "Loading particle systems", comment: "Scene load progress: building particle systems."))
        await loadParticleSystems(from: document, on: actor)
        try checkCurrentSceneScriptLoad(scriptLoadToken)
        debugStage(
            "particles.load.done",
            "systems=\(particleSystems.count)"
        )
        try Task.checkCancellation()

        debugStage("text.load", "begin")
        onProgress?(String(localized: "Loading text pipeline", comment: "Scene load progress: building the text rendering pipeline."))
        beginSceneScriptVideoCommands()
        loadTextPipeline(from: document, scriptLoadToken: scriptLoadToken)
        debugStage("text.load.done", "objects=\(textObjects.count)")
        try Task.checkCancellation()

        // After textures so video sources exist; init() seeds visibility/alpha and suppresses auto-play on script-owned video.
        loadLayerScripts(from: document, scriptLoadToken: scriptLoadToken)
        // Hosts first (3509243656 MAIN n-body), then transform/text consumers. Seeding texts in loadTextPipeline ran consumers first and NaN-poisoned `time`.
        seedSceneScriptsAfterLoad(from: document, scriptLoadToken: scriptLoadToken)
        var scriptsAreBaked = resetSceneScriptsToBakedIfFailed(scriptLoadToken)
        do {
            try Task.checkCancellation()
            try checkCurrentSceneScriptLoad(scriptLoadToken)
        } catch {
            discardSceneScriptVideoCommands()
            throw error
        }
        try finishSceneScriptLoadVideoCommands(
            for: scriptLoadToken,
            scriptsAreBaked: &scriptsAreBaked
        )

        await shaderWarmTask.value
        try checkCurrentSceneScriptLoad(scriptLoadToken)
        prepareSceneScriptsForFirstFrame(
            scriptLoadToken,
            scriptsAreBaked: &scriptsAreBaked
        )
        debugStage("render.firstFrame", "begin")
        onProgress?(String(localized: "Rendering scene", comment: "Scene load progress: first frame is being drawn."))

        // First frame must be sync: snapshot/`renderedTexture` read back immediately after load(). Async would race the GPU.
        executor.synchronizeFrameCompletion = true
        let capture = beginGPUCaptureIfRequested()
        outputTexture = try renderCurrentFrame(inputs: makeFrameInputs())
        outputFrameProduction = latestFrameProduction
        capture?.stop()

        if let outputTexture {
            // Before finishFrame latches the trace; later recordPassOutputs would drop per-pass hashes.
            #if DEBUG
            dumpScenePassesIfRequested()
            #endif
            // Debug-only first-frame PNG/stats. Production skips this sync read-back (inspector uses captureLivePoster).
            if WPESceneDebugArtifacts.shared.isEnabled {
                cachedSnapshot = snapshotter.snapshot(from: outputTexture)
                let stats = WPEMetalTextureVisualStats.analyze(texture: outputTexture)
                if let stats {
                    WPESceneDebugArtifacts.shared.recordFirstFrameStats(stats)
                }
                #if !LITE_BUILD && DEBUG
                WPECanonicalTraceRecorder.shared.finishFrame(
                    outputTexture: outputTexture,
                    runtimeUniforms: lastRuntimeUniforms,
                    firstFrameStats: stats,
                    resolutionDiagnostics: resolutionTracer.snapshot()
                )
                #endif
            }
            dumpOutputTextureIfRequested(outputTexture)
        }
        didLoad = true
        // Steady-state: async unless a per-frame read-back is active or WPEMetalSerializeFrames is set.
        executor.synchronizeFrameCompletion = shouldSynchronizeFrames()
        applyPerformanceProfile(currentProfile)
        surfaceControl.setNeedsRedraw()
        debugStage("render.firstFrame.done", "size=\(outputTexture?.width ?? 0)x\(outputTexture?.height ?? 0) snapshot=\(cachedSnapshot == nil ? "none" : "saved")")
        if document.soundObjects.isEmpty {
            soundRuntime = nil
            pendingAudioStartupDocument = nil
        } else {
            pendingAudioStartupDocument = document
        }
        _ = id
    }

    // MARK: - Deferred audio startup

    /// After first present: `prepare(sounds:)` decodes off-actor (~300-900ms, silent). `play()` only after the generation is still current. Mute/volume re-applied just before `play()`.
    func beginDeferredAudioStartup() {
        guard let document = pendingAudioStartupDocument else { return }
        pendingAudioStartupDocument = nil
        // Engine-level keys share the layered map; the property filter drops them because they are not properties.
        presetAudioSettings = WPEEngineAudioSettings.parse(descriptor.presetSnapshot)
        let sounds = document.soundObjects
        guard !sounds.isEmpty else {
            soundRuntime = nil
            return
        }
        let runtime = WPESoundRuntime(resolver: resourceResolver)
        runtime.setMuted(pendingAudioMuted)
        runtime.setMasterVolume(effectiveAudioVolume)
        let generation = loadGeneration
        guard let actor = displayActor else { return }
        deferredAudioStartupTask?.cancel()
        deferredAudioStartupTask = Task.detached(priority: .userInitiated) { [actor] in
            _ = runtime.prepare(sounds: sounds)   // off-actor, decodes files; nothing audible yet
            // Publish on the actor. A reload bumps `generation` so stale audio is released, not leaked.
            await actor.publishDeferredAudio(runtime: runtime, generation: generation)
        }
    }

    static func scriptLayerTable(for document: WPESceneDocument) -> [WPESceneScriptLayerInfo] {
        var nameByID: [String: String] = [:]
        for object in document.imageObjects { nameByID[object.id] = object.name }
        for object in document.transformHostObjects { nameByID[object.id] = object.name }
        for object in document.textObjects { nameByID[object.id] = object.name }
        var layers: [WPESceneScriptLayerInfo] = []
        layers.reserveCapacity(nameByID.count)
        for object in document.imageObjects {
            layers.append(WPESceneScriptLayerInfo(
                id: object.id,
                name: object.name,
                size: SIMD2<Double>(Double(object.size?.width ?? 0), Double(object.size?.height ?? 0)),
                origin: SIMD2<Double>(object.origin.x, object.origin.y),
                originZ: object.origin.z,
                scale: object.scale,
                angles: object.angles,
                index: layers.count,
                parentName: object.parentObjectID.flatMap { nameByID[$0] }
            ))
        }
        for object in document.transformHostObjects {
            layers.append(WPESceneScriptLayerInfo(
                id: object.id,
                name: object.name,
                size: .zero,
                origin: SIMD2<Double>(object.origin.x, object.origin.y),
                originZ: object.origin.z,
                scale: object.scale,
                angles: object.angles,
                index: layers.count,
                parentName: object.parentObjectID.flatMap { nameByID[$0] }
            ))
        }
        for object in document.textObjects {
            layers.append(WPESceneScriptLayerInfo(
                id: object.id,
                name: object.name,
                size: object.boxSize ?? SIMD2<Double>(0, 0),
                origin: SIMD2<Double>(object.origin.x, object.origin.y),
                originZ: object.origin.z,
                scale: object.scale,
                angles: object.angles,
                index: layers.count,
                parentName: object.parentObjectID.flatMap { nameByID[$0] }
            ))
        }
        return layers
    }

    /// `defaults write com.loomscreen.pro WPEMemoryAuditLog -bool YES`. Census is registry-owned textures only; `device allocated` is the only true total.
    func logMemoryAuditIfEnabled() {
        guard UserDefaults.standard.bool(forKey: "WPEMemoryAuditLog") else { return }
        let census = WPEMetalTextureMetadataRegistry.shared.census()
        let contexts = WPESceneScriptContextBeacon.liveCount
        func mib(_ bytes: Int) -> String { String(format: "%.1f MiB", Double(bytes) / 1_048_576) }
        var lines = [
            "[MemoryAudit] scene=\(descriptor.workshopID)",
            "  GPU textures: \(census.count) live, \(mib(census.totalBytes)) owned",
            "  heap-aliased RTs: \(census.aliasCount), \(mib(census.aliasBytes)) logical "
                + "(upper bound on ONE shared heap — not an addend)"
        ]
        // Contexts share one JSVirtualMachine per batch worker. Rising without bound is the signal; the dispatcher is per renderer, so this many VMs per screen.
        lines.append("  JSContexts live: \(contexts) (sharing "
            + "\(sceneScriptBatchDispatcher.width) worker VMs on this renderer)")
        lines.append("  device allocated: \(mib(Int(executor.textureSourceDevice.currentAllocatedSize)))")
        // Largest offenders first so a truncated log still answers where the gigabytes went.
        for item in census.largest {
            lines.append(
                "    largest: \(item.label) \(item.width)x\(item.height) \(item.format) = \(mib(item.bytes))"
            )
        }
        for (category, bucket) in census.byCategory.sorted(by: { $0.value.bytes > $1.value.bytes }) {
            lines.append("    \(category): \(bucket.count)x → \(mib(bucket.bytes))")
        }
        Logger.notice(lines.joined(separator: "\n"), category: .wpeRender)
    }
}
#endif
