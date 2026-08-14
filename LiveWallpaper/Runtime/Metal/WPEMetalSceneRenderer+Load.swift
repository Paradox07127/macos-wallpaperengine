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

    /// Classifies a `performLoad()` failure that is specific to the Metal
    /// renderer. Returning a non-nil reason promotes the error to
    /// `SceneRenderingError.metalRendererUnsupported`, which surfaces to the
    /// user as the scene's load error.
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

    /// Dumps the resolved/missed resource tally to the persistent log so maintainers can `tail ~/Library/Logs/LiveWallpaper/runtime.log` and diagnose without having the DEBUG inspector window open.
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
        // project.json lives at the source folder for in-place scenes, the cache
        // dir for legacy ones — the property schema reads from here.
        let sceneCacheRoot = projectManifestRootURL ?? cacheRootURL
        let parsedDocument = try await Task.detached(priority: .userInitiated) {
            let data = try entryReader.data(relativePath: sceneDescriptor.entryFile)
            let userValues = WallpaperEngineProjectPropertySchema.effectiveSceneValues(
                descriptor: sceneDescriptor,
                cacheRootURL: sceneCacheRoot
            )
            // The resolved property set decides every `{"user":K,"value":V}` envelope in the
            // scene. An empty dump here means project.json never loaded and every envelope fell
            // back to its baked literal — indistinguishable from a wrong value without this.
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
        // Text becomes image layers BEFORE the graph is built, so paint order,
        // the effect chain, parallax and the parent chain all come from the one
        // graph. Keyed by the text object's own id, so `objectPaintOrder` drops
        // each label back where the author put it (a character drawn later
        // hides it, which an after-the-fact overlay could never do).
        let textFonts = WPETextFontResolver(resolver: resourceResolver)
        textRenderPlans = WPETextRenderPlanner.plans(for: parsedDocument, fonts: textFonts)
        textFontResolver = textFonts
        let document = parsedDocument.appendingImageObjects(textRenderPlans.map(\.imageObject))
        debugStage("read.entry.done", "imageObjects=\(document.imageObjects.count) particles=\(document.particleObjects.count) text=\(document.textObjects.count) textLayers=\(textRenderPlans.count) sound=\(document.soundObjects.count)")
        let scriptInventory = WPESceneScriptInstanceInventory(document: document)
        if !scriptLoadToken.prepare(scriptInventory) {
            // No longer a count cap (there isn't one) — this only fires when the
            // load was already prepared or retired, i.e. an interleaved reload.
            Logger.warning(
                "Scene \(id) script load token rejected its inventory of \(scriptInventory.total) runtimes"
                    + " (already prepared or retired); runtime scripts are disabled for this load",
                category: .wpeRender
            )
        }
        // Reuse figures say whether a script-heavy scene is real work or one source
        // pasted onto hundreds of objects (2955378002: 676 bindings, 124 distinct,
        // one repeated 430x). Diagnostic only — every binding gets its own runtime,
        // as Wallpaper Engine does.
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
        // Seed incremental-apply state. The graph builder already baked each
        // layer's authored `visible` into the pipeline, so these baselines
        // simply mirror it for later diffing in `applyScenePropertyPatch`.
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
        // Perspective scenes (orthogonalprojection:null) have no authored pixel
        // canvas — the fixed 1920×1080 fallback renders every panel/label at half
        // the density of a 4K display, then present upscales it to a blur. WPE
        // renders perspective natively, so its 8px HUD text is crisp where ours
        // mushed. Render perspective at the drawable resolution (capped 4K, never
        // below the authored size) so text pixels are 1:1 with the display.
        // Geometry is fov-based (resolution-independent) — only pixel density and
        // FBO cost change. Kill switch: WPEMetalPerspectiveNativeResolution -bool NO.
        if document.general.usesPerspectiveProjection,
           Self.perspectiveNativeResolutionEnabled {
            let drawable = surfaceDrawableSize
            let base = cameraUniforms.renderSize
            let cap = CGSize(width: 3840, height: 2160)
            var targetW = min(max(drawable.width, base.width), cap.width)
            var targetH = min(max(drawable.height, base.height), cap.height)
            // Clamp to the memory tier's pixel budget (HDR float16 counts double)
            // so native-res + HDR bloom don't stack into an OOM on 8/16 GB Macs.
            let budget = WPEMemoryTier.current.perspectiveRenderPixelBudget(hdr: document.general.hdr)
            let pixels = Double(targetW * targetH)
            if pixels > budget {
                let shrink = (budget / pixels).squareRoot()
                targetW = max(base.width, (targetW * CGFloat(shrink)).rounded())
                targetH = max(base.height, (targetH * CGFloat(shrink)).rounded())
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
        // The rigid-subtree parallax walk needs the FULL object hierarchy: a
        // clock text's chain runs through non-drawn groups before it reaches
        // the ancestor whose depth/origin drive the whole assembly.
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
        // The authored flag covers shader-driven audio; script-driven audio is
        // NOT reflected in it (see `usesAudioAPI`), and without capture running
        // those scripts read a permanently silent broker.
        sceneSupportsAudioProcessing = document.general.supportsAudioProcessing
            || WPESceneScriptInstanceInventory.usesAudioAPI(in: document)
        cameraParallaxSmoother.reset()
        sceneRenderSize = cameraUniforms.renderSize
        debugStage("camera", "renderSize=\(Int(sceneRenderSize.width))x\(Int(sceneRenderSize.height))")
        try checkCurrentSceneScriptLoad(scriptLoadToken)
        // Built BEFORE any loader below, so every engine's `installSandbox` sees
        // the resolved `engine.userProperties`. The `?? WPESharedScriptState(...)`
        // fallbacks in those loaders only fire if this line is skipped.
        sceneScriptSharedState = WPESharedScriptState(
            sceneScriptLoadToken: scriptLoadToken,
            userProperties: currentSceneScriptUserProperties(),
            layers: Self.scriptLayerTable(for: document)
        )
        loadDynamicOriginScripts(from: document, scriptLoadToken: scriptLoadToken)
        // Shader-constant scripts hang off the built pipeline, not the document.
        loadEffectConstantScripts(from: pipeline, document: document, scriptLoadToken: scriptLoadToken)
        loadEffectVisibilityScripts(from: pipeline, scriptLoadToken: scriptLoadToken)

        // Pre-warm shader transpile off-thread, overlapping the texture/particle/text
        // load below; awaited at the render.firstFrame gate so the first synchronous
        // render() hits the warmed cache instead of paying the lazy transpile inline.
        // A child task on the actor (not `async let`, which would try to send `self`
        // into a concurrent child) — it interleaves at the load's suspension points.
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

        // Layer visible-scripts (video intros etc.). After textures so the video
        // sources exist; runs each script's init() to seed visibility/alpha and
        // suppress auto-play on script-owned video sources.
        loadLayerScripts(from: document, scriptLoadToken: scriptLoadToken)
        // First-evaluation seeding, in WPE order: script hosts (pure compute
        // producers, e.g. 3509243656's MAIN n-body sim writing shared.xx*/ktime)
        // update once FIRST, then transform + text consumers seed. Seeding texts
        // inside loadTextPipeline ran consumers before the producer existed —
        // tooltip scripts threw and the `time` script NaN-poisoned itself.
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

        // Audio startup is deferred to after the first frame (see below): the
        // synchronous `runtime.prepare(sounds:)` + `play()` is a 300-900ms hit
        // that does not gate any pixels, so keeping it on the load path only
        // inflates perceived load time.
        // Finish seeding the shader cache before the first (synchronous) render() so it
        // hits warmed entries. By now this has overlapped the entire texture/particle/text
        // load above; on heavy scenes the ~1.9s transpile is already absorbed.
        await shaderWarmTask.value
        try checkCurrentSceneScriptLoad(scriptLoadToken)
        prepareSceneScriptsForFirstFrame(
            scriptLoadToken,
            scriptsAreBaked: &scriptsAreBaked
        )
        debugStage("render.firstFrame", "begin")
        onProgress?(String(localized: "Rendering scene", comment: "Scene load progress: first frame is being drawn."))

        // Render the FIRST frame synchronously: it is read back on the CPU right
        // after load() by the scene-debug snapshot and the `renderedTexture`
        // accessor (tests) — an async submission would let those read-backs race
        // the GPU and sample an unfinished frame. It is a one-time cost; the
        // steady-state draw loop switches to async below.
        executor.synchronizeFrameCompletion = true
        let capture = beginGPUCaptureIfRequested()
        outputTexture = try renderCurrentFrame(inputs: makeFrameInputs())
        outputFrameProduction = latestFrameProduction
        capture?.stop()

        if let outputTexture {
            // Capture per-pass scene-target RT hashes BEFORE finishFrame latches
            // and serializes the trace — otherwise recordPassOutputs runs after the
            // trace is already written and the per-pass output hashes are dropped.
            #if DEBUG
            dumpScenePassesIfRequested()
            #endif
            // The snapshot + visual-stats read-backs here exist only to feed the
            // scene-debug artifacts (first-frame PNG + stats). The inspector
            // reuses a *current* live frame on demand (captureLivePoster), so
            // production skips this synchronous load-path read-back — it would
            // slow first-frame present, and frame 0 often predates a scene's
            // intro / warmed particles / decoded video anyway.
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
        // Steady-state draw loop: async in production (no per-frame CPU stall on
        // the GPU); stay synchronous only when a per-frame read-back is active
        // (scene-debug / GPU capture / pass dumps) or pinned via WPEMetalSerializeFrames.
        executor.synchronizeFrameCompletion = shouldSynchronizeFrames()
        applyPerformanceProfile(currentProfile)
        surfaceControl.setNeedsRedraw()
        debugStage("render.firstFrame.done", "size=\(outputTexture?.width ?? 0)x\(outputTexture?.height ?? 0) snapshot=\(cachedSnapshot == nil ? "none" : "saved")")
        // Defer audio startup to the first actual present (handled in draw(in:))
        // so it never blocks the first visible frame. Empty-sound scenes clear
        // any prior runtime now.
        if document.soundObjects.isEmpty {
            soundRuntime = nil
            pendingAudioStartupDocument = nil
        } else {
            pendingAudioStartupDocument = document
        }
        _ = id
    }

    // MARK: - Deferred audio startup

    /// Boot the sound runtime once the first frame has actually presented (called
    /// from `draw(in:)` after the first successful `present`). The expensive
    /// `prepare(sounds:)` (file loads + buffer decode, ~300-900ms) runs OFF the
    /// main actor so the wallpaper never stalls but produces NO audio. Playback
    /// (`play()`) only starts back on the main actor, AFTER confirming the scene
    /// is still current — so a reload/cleanup during preparation can never let a
    /// stale scene's audio play (it just releases the prepared engine). Mute and
    /// volume are re-applied with the latest values immediately before `play()`,
    /// so a toggle during the off-main window is honored before any sound.
    func beginDeferredAudioStartup() {
        guard let document = pendingAudioStartupDocument else { return }
        pendingAudioStartupDocument = nil
        // Engine-level keys share the layered map with the properties; the
        // property filter drops them because they are not properties.
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
        let workshopID = descriptor.workshopID
        guard let actor = displayActor else { return }
        deferredAudioStartupTask?.cancel()
        deferredAudioStartupTask = Task.detached(priority: .userInitiated) { [actor] in
            _ = runtime.prepare(sounds: sounds)   // off-actor, decodes files; nothing audible yet
            // Publish + start on the actor. A reload/cleanup during prepare bumps
            // the generation, so `publishDeferredAudio` releases the engine instead
            // of leaking stale audio; a policy suspend leaves it prepared-but-silent
            // until the next `.quality`/`resume()`.
            await actor.publishDeferredAudio(runtime: runtime, generation: generation)
        }
    }

    /// Layer table SceneScript addresses by name (`thisScene.getLayer`,
    /// `enumerateLayers`, `getLayerIndex`, `layer.size`). Document order is the
    /// z-order; text objects carry their box as their size, images their `size`.
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

    /// Measured "where did the gigabytes go" breakdown, printed once per load.
    /// The census covers what registers with the metadata registry — scene
    /// textures and the render-target pool — NOT video textures, bloom, depth or
    /// the executor's own pools, so `device allocated` is the only total here
    /// that is a total. The JSContext count is the scripting side.
    /// Off by default — costs nothing when the key is unset:
    /// `defaults write com.loomscreen.pro WPEMemoryAuditLog -bool YES`
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
        // NOT multiplied by a per-VM cost any more: contexts share one
        // JSVirtualMachine per batch worker, and the beacon lives in the JS heap,
        // so this counts contexts whose globals are still reachable OR merely
        // uncollected. Rising without bound is the signal; the absolute value is not.
        // The dispatcher is per RENDERER, so a multi-display session runs this
        // many worker VMs per screen, not this many in total.
        lines.append("  JSContexts live: \(contexts) (sharing "
            + "\(sceneScriptBatchDispatcher.width) worker VMs on this renderer)")
        lines.append("  device allocated: \(mib(Int(executor.textureSourceDevice.currentAllocatedSize)))")
        // Totals and the largest offenders first: the per-category list is
        // bounded but the log is not, and a truncated tail must not cost the
        // numbers that answer "where did the gigabytes go".
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
