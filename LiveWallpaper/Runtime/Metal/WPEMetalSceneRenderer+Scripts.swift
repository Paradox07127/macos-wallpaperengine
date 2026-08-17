#if !LITE_BUILD
import AppKit
import LiveWallpaperCore
import LiveWallpaperProWPE
import MetalKit

/// Mutation journal for `thisLayer` transform assignments, owned by the renderer
/// (so display-actor isolated, not `@MainActor`). The load generation is part of
/// the key so an outcome from a retired scene can never move an object in the
/// replacement scene that reused its objectID.
struct WPESceneScriptTransformMutationJournal: Equatable {
    struct Key: Hashable {
        let objectID: String
        let generation: Int
    }

    private(set) var entries: [Key: WPELayerScriptTransformMutation] = [:]

    mutating func record(
        _ mutation: WPELayerScriptTransformMutation,
        objectID: String,
        generation: Int
    ) {
        guard !mutation.isEmpty else { return }
        let key = Key(objectID: objectID, generation: generation)
        var accumulated = entries[key] ?? .init()
        accumulated.merge(mutation)
        entries[key] = accumulated
    }

    mutating func removeAll() {
        entries.removeAll(keepingCapacity: false)
    }

    func applying(
        to base: WPEMetalSceneRenderer.LiveScriptTransforms,
        generation: Int
    ) -> WPEMetalSceneRenderer.LiveScriptTransforms {
        var resolved = base
        for (key, mutation) in entries where key.generation == generation {
            if let origin = mutation.origin { resolved.origins[key.objectID] = origin }
            if let scale = mutation.scale { resolved.scales[key.objectID] = scale }
            if let angles = mutation.angles {
                resolved.angles[key.objectID] = angles * (.pi / 180)
            }
        }
        return resolved
    }
}

extension WPEMetalSceneRenderer {
    // MARK: - Script loading & seeding

    /// Builds a `WPELayerScriptInstance` per image object whose `visible` field
    /// is a SceneScript, maps each to its video source, and applies the script's
    /// `init()` state (visibility/alpha + video stop/seek). Runs after textures so
    /// the video sources exist. No-op for scenes without layer scripts.
    func loadLayerScripts(
        from document: WPESceneDocument,
        scriptLoadToken: WPESceneScriptInstanceLimitToken
    ) {
        layerTransformMutationJournal.removeAll()
        layerScriptInstances = [:]
        layerAlphaScriptInstances = [:]
        textVisibleScriptInstances = [:]
        textAlphaScriptInstances = [:]
        liveTextAlpha = [:]
        layerHoverStates = [:]
        layerVideoSourceKey = [:]
        layerObjectIDByName = [:]
        liveLayerAlpha = [:]
        invalidateIntroPhaseAlign()
        guard isCurrentSceneScriptLoad(scriptLoadToken),
              scriptLoadToken.allows(.setup) else { return }
        let visibleScripted = document.imageObjects.filter { $0.visibleScript != nil }
        let alphaScripted = document.imageObjects.filter { $0.alphaScript != nil }
        let textVisibleScripted = document.textObjects.filter { $0.visibleScript != nil }
        let textAlphaScripted = document.textObjects.filter { $0.alphaScript != nil }
        let scriptHosts = document.scriptHostObjects
        debugStage(
            "layerScripts.load",
            "hosts=\(scriptHosts.count) visible=\(visibleScripted.count) alpha=\(alphaScripted.count) "
                + "textVisible=\(textVisibleScripted.count) textAlpha=\(textAlphaScripted.count) "
                + "hostNames=\(scriptHosts.prefix(8).map(\.name).joined(separator: ","))"
        )
        guard (!visibleScripted.isEmpty || !alphaScripted.isEmpty || !scriptHosts.isEmpty
                || !textVisibleScripted.isEmpty || !textAlphaScripted.isEmpty),
              let pipeline = renderPipeline else { return }

        // Index every layer because scripts can control a different layer's video by name.
        for layer in pipeline.layers {
            let id = layer.graphLayer.objectID
            layerObjectIDByName[layer.graphLayer.objectName] = id
            if let key = videoTexturePaths(for: layer).first(where: { dynamicTextureSources[$0] is WPEVideoTextureSource }) {
                layerVideoSourceKey[id] = key
            }
        }

        // WPE delivers the user-property bag to each script after init(); time-of-day
        // scripts gate their day/night switch on it (e.g. `timevarying`), so without
        // this the switch never runs.
        let userProperties = currentSceneScriptUserProperties()
        debugStage("layerScripts.userProperties", "count=\(userProperties.count)")
        // One `shared` store for the whole scene so WPE's cross-script `shared`
        // global coordinates across the scripts' isolated contexts.
        let sharedState = sceneScriptSharedState
            ?? WPESharedScriptState(sceneScriptLoadToken: scriptLoadToken)
        sceneScriptSharedState = sharedState
        let scriptCanvasSize = SIMD2<Double>(
            max(Double(sceneRenderSize.width), 1),
            max(Double(sceneRenderSize.height), 1)
        )
        for object in scriptHosts {
            do {
                guard let instance = try constructSceneScript(for: scriptLoadToken, {
                    try WPELayerScriptInstance(
                    script: object.visibleScript,
                    scriptProperties: object.scriptProperties,
                    shared: sharedState,
                    canvasSize: scriptCanvasSize,
                    ownLayerName: object.name,
                    batchDispatcher: self.sceneScriptBatchDispatcher)
                }) else { return }
                layerScriptInstances[object.id] = instance
                applyLayerScriptOutput(instance.initialOutput, ownObjectID: object.id)
                if let output = applyScriptUserProperties(instance, userProperties) {
                    applyLayerScriptOutput(output, ownObjectID: object.id)
                }
            } catch {
                _ = latchSceneScriptFailure(error, operation: .setup, token: scriptLoadToken)
                Logger.warning("Scene \(descriptor.workshopID) [ScriptHost] init failed for \(object.name): \(error)", category: .wpeRender)
            }
        }
        for object in visibleScripted {
            guard let script = object.visibleScript else { continue }
            do {
                guard let instance = try constructSceneScript(for: scriptLoadToken, {
                    try WPELayerScriptInstance(
                    script: script,
                    scriptProperties: object.scriptProperties,
                    shared: sharedState,
                    canvasSize: scriptCanvasSize,
                    initialVisible: object.visible,
                    initialAlpha: object.alpha,
                    ownLayerName: object.name,
                    batchDispatcher: self.sceneScriptBatchDispatcher)
                }) else { return }
                layerScriptInstances[object.id] = instance
                applyLayerScriptOutput(instance.initialOutput, ownObjectID: object.id)
                if let output = applyScriptUserProperties(instance, userProperties) {
                    applyLayerScriptOutput(output, ownObjectID: object.id)
                }
            } catch {
                _ = latchSceneScriptFailure(error, operation: .setup, token: scriptLoadToken)
                Logger.warning("Scene \(descriptor.workshopID) [LayerScript] init failed for \(object.name): \(error)", category: .wpeRender)
            }
        }
        for object in alphaScripted {
            guard let script = object.alphaScript else { continue }
            do {
                guard let instance = try constructSceneScript(for: scriptLoadToken, {
                    try WPELayerScriptInstance(
                    script: script,
                    scriptProperties: object.alphaScriptProperties,
                    shared: sharedState,
                    canvasSize: scriptCanvasSize,
                    outputMode: .returnedAlpha(initialValue: object.alpha),
                    ownLayerName: object.name,
                    batchDispatcher: self.sceneScriptBatchDispatcher)
                }) else { return }
                layerAlphaScriptInstances[object.id] = instance
                applyLayerAlphaScriptOutput(instance.initialOutput, ownObjectID: object.id)
                if let output = applyScriptUserProperties(instance, userProperties) {
                    applyLayerAlphaScriptOutput(output, ownObjectID: object.id)
                }
            } catch {
                _ = latchSceneScriptFailure(error, operation: .setup, token: scriptLoadToken)
                Logger.warning("Scene \(descriptor.workshopID) [AlphaScript] init failed for \(object.name): \(error)", category: .wpeRender)
            }
        }
        for object in textVisibleScripted {
            guard let script = object.visibleScript else { continue }
            do {
                guard let instance = try constructSceneScript(for: scriptLoadToken, {
                    try WPELayerScriptInstance(
                    script: script,
                    scriptProperties: object.visibleScriptProperties,
                    shared: sharedState,
                    canvasSize: scriptCanvasSize,
                    initialVisible: object.visible,
                    initialAlpha: object.alpha,
                    ownLayerName: object.name,
                    batchDispatcher: self.sceneScriptBatchDispatcher)
                }) else { return }
                textVisibleScriptInstances[object.id] = instance
                applyTextScriptOutput(instance.initialOutput, ownObjectID: object.id)
                if let output = applyScriptUserProperties(instance, userProperties) {
                    applyTextScriptOutput(output, ownObjectID: object.id)
                }
            } catch {
                _ = latchSceneScriptFailure(error, operation: .setup, token: scriptLoadToken)
                Logger.warning("Scene \(descriptor.workshopID) [TextVisibleScript] init failed for \(object.name): \(error)", category: .wpeRender)
            }
        }
        for object in textAlphaScripted {
            guard let script = object.alphaScript else { continue }
            do {
                guard let instance = try constructSceneScript(for: scriptLoadToken, {
                    try WPELayerScriptInstance(
                    script: script,
                    scriptProperties: object.alphaScriptProperties,
                    shared: sharedState,
                    canvasSize: scriptCanvasSize,
                    outputMode: .returnedAlpha(initialValue: object.alpha),
                    ownLayerName: object.name,
                    batchDispatcher: self.sceneScriptBatchDispatcher)
                }) else { return }
                textAlphaScriptInstances[object.id] = instance
                liveTextAlpha[object.id] = instance.initialOutput.own.alpha
                if let output = applyScriptUserProperties(instance, userProperties) {
                    liveTextAlpha[object.id] = output.own.alpha
                }
            } catch {
                _ = latchSceneScriptFailure(error, operation: .setup, token: scriptLoadToken)
                Logger.warning("Scene \(descriptor.workshopID) [TextAlphaScript] init failed for \(object.name): \(error)", category: .wpeRender)
            }
        }
        setUpIntroPhaseAlign(
            scripted: visibleScripted,
            scriptLoadToken: scriptLoadToken
        )
    }

    /// A text object's own `visible` script output → live text visibility (and
    /// alpha when the script assigned it). `others` still routes to image
    /// layers via the shared name map, matching image layer-script semantics.
    func applyTextScriptOutput(_ output: WPELayerScriptOutput, ownObjectID: String) {
        if output.own.visibleAssigned {
            liveTextVisibility[ownObjectID] = output.own.visible
        }
        if output.own.alphaAssigned {
            liveTextAlpha[ownObjectID] = output.own.alpha
        }
        layerTransformMutationJournal.record(
            output.ownTransform,
            objectID: ownObjectID,
            generation: loadGeneration
        )
        for (name, state) in output.others {
            guard let targetID = layerObjectIDByName[name] else { continue }
            applyLayerScriptState(state, objectID: targetID)
        }
        for (name, mutation) in output.otherTransforms {
            guard let targetID = layerObjectIDByName[name] else { continue }
            layerTransformMutationJournal.record(
                mutation,
                objectID: targetID,
                generation: loadGeneration
            )
        }
    }

    /// One deterministic "frame 0" evaluation pass over the scene's scripts, run
    /// once at the end of load — PRODUCERS FIRST. WPE ticks every script serially
    /// in scene-object order each frame, so a `shared`-consuming script never
    /// evaluates before the producers that precede it. Our per-load seeding used
    /// to run inside each loader (texts before the layer scripts even existed);
    /// a consumer's first evaluation then read an empty `shared` — worst case
    /// permanently corrupting its own module state (3509243656's `time` script
    /// accumulates `undefined` arithmetic into NaN, and its self-reset keys off
    /// `shared.xntime === undefined`, which that same broken tick already set to
    /// NaN — "frozen at NaN Years" forever). Order here: script hosts (pure
    /// compute producers, e.g. MAIN's n-body sim writing shared.xx*/ktime) run
    /// one update() each, then transform + text-content consumers seed.
    func seedSceneScriptsAfterLoad(
        from document: WPESceneDocument,
        scriptLoadToken: WPESceneScriptInstanceLimitToken
    ) {
        guard isCurrentSceneScriptLoad(scriptLoadToken),
              scriptLoadToken.allows(.tick) else { return }
        // 1. Script hosts: one bounded synchronous update() each, in scene
        //    order, applied exactly like a frame tick.
        for host in document.scriptHostObjects {
            guard let instance = layerScriptInstances[host.id] else { continue }
            if let output = instance.tick(runtimeSeconds: 0, pointerFrame: .neutral) {
                applyLayerScriptOutput(output, ownObjectID: host.id)
            }
        }
        // 2. Transform scripts, neutral pointer (the frame path's
        //    follow-cursor-off default) — first frame shows the scripted
        //    transform instead of popping from the baked value.
        let neutralPointer = SIMD2<Double>(0.5, 0.5)
        for instances in [
            dynamicOriginScriptInstances,
            dynamicScaleScriptInstances,
            dynamicAnglesScriptInstances,
            dynamicColorScriptInstances
        ] {
            for (_, instance) in instances.sorted(by: { $0.key < $1.key }) {
                instance.seedAsyncTick(pointerPosition: neutralPointer)
            }
        }
        // 3. Seed text scripts in object order because later scripts may consume shared state.
        for object in textObjects {
            textScriptInstances[object.id]?.seedAsyncTick()
        }
        // 4./5. Effect constants BEFORE visibility gates: a gate reads what a
        //    constant script writes into `shared` (day/night `shared.shownight`),
        //    so seeding them out of order leaves the gate reading `undefined` and
        //    the first frame renders with every arm of the cycle closed.
        for (_, instance) in effectConstantScriptInstances
            .sorted(by: { ($0.key.passID, $0.key.uniform) < ($1.key.passID, $1.key.uniform) }) {
            instance.seedAsyncTick(pointerPosition: neutralPointer)
        }
        for (_, instance) in effectVisibilityScriptInstances.sorted(by: { $0.key < $1.key }) {
            instance.seedAsyncTick(pointerPosition: neutralPointer)
        }
    }

    // MARK: - On-demand video layers

    /// Index every video layer, plus the static graph of who can put each video's
    /// pixels on screen. The predecessor filter admitted only scene-only layers,
    /// so a hidden video that writes an FBO decoded at full rate forever; the
    /// consumer graph replaces that proxy with the real question, answered per
    /// frame by `reconcileVideoResidency`.
    func indexOnDemandVideoLayers(pipeline: WPEPreparedRenderPipeline) {
        onDemandVideoKeyByID = [:]
        onDemandVideoLoading = []
        for layer in pipeline.layers {
            // Every video the layer samples, not just the first: a layer can bind
            // one video as its source and another in a shader slot, and indexing
            // only one of them drops the other layer's consumer edge.
            let keys = Set(videoTexturePaths(for: layer)
                .filter { dynamicTextureSources[$0] is WPEVideoTextureSource })
            guard !keys.isEmpty else { continue }
            onDemandVideoKeyByID[layer.graphLayer.objectID] = keys
        }
        onDemandVideoKeysByConsumerID = Self.onDemandVideoKeysByConsumerLayer(
            layers: pipeline.layers,
            videoKeyByLayerID: onDemandVideoKeyByID
        )
        onDemandVideoKeysByImagePath = Self.onDemandVideoKeysByImagePath(
            layers: pipeline.layers,
            keysByConsumerID: onDemandVideoKeysByConsumerID
        )
    }

    /// Static half of the release decision: layer objectID → the video keys whose
    /// pixels that layer can put on screen. Seeded with the layers that sample the
    /// video, then closed transitively over the FBO/composite graph — A writes
    /// FBO1, B samples FBO1 and writes FBO2, C samples FBO2 ⇒ all three are
    /// consumers of A's video. `.scene` and `_rt_layerGroup_*` writes deliberately
    /// do NOT propagate: those are exactly the two targets `WPEMetalRenderExecutor`
    /// skips for a hidden layer, so a hidden layer's pixels never reach them, and a
    /// VISIBLE layer that writes them already counts as a consumer on its own.
    /// Visibility is absent here on purpose — it changes every frame, this graph
    /// does not. Pure + static for unit testing.
    nonisolated static func onDemandVideoKeysByConsumerLayer(
        layers: [WPEPreparedRenderLayer],
        videoKeyByLayerID: [String: Set<String>]
    ) -> [String: Set<String>] {
        guard !videoKeyByLayerID.isEmpty else { return [:] }
        // Per-layer unions, not per-pass: a layer's passes chain through
        // `.previous` and its own composites, so any input reaching the layer can
        // reach every target it writes.
        let sampled = layers.map { Set($0.passes.flatMap(Self.passSampledTargetNames)) }
        let written = layers.map { Set($0.passes.compactMap(Self.passPropagatedTargetName)) }
        var result: [String: Set<String>] = [:]
        for key in Set(videoKeyByLayerID.values.joined()) {
            var consumers: Set<String> = []
            var tainted: Set<String> = []
            for (index, layer) in layers.enumerated()
                where videoKeyByLayerID[layer.graphLayer.objectID]?.contains(key) == true {
                consumers.insert(layer.graphLayer.objectID)
                tainted.formUnion(written[index])
            }
            var grew = true
            while grew {
                grew = false
                for (index, layer) in layers.enumerated() {
                    let objectID = layer.graphLayer.objectID
                    guard !consumers.contains(objectID),
                          !sampled[index].isDisjoint(with: tainted) else { continue }
                    consumers.insert(objectID)
                    tainted.formUnion(written[index])
                    grew = true
                }
            }
            for objectID in consumers {
                result[objectID, default: []].insert(key)
            }
        }
        return result
    }

    /// Both sides of the graph key on this. `WPEMetalShaderInputs`
    /// `resolveAliasedNamedTexture` matches an `.fbo(name)` against the frame's
    /// named textures after stripping `_rt_`/leading `_` and ignoring case, so
    /// comparing raw strings here loses edges the executor actually draws
    /// (author writes `_rt_Blur`, a visible layer samples `blur`). Merging more
    /// names than the executor would only over-retains; missing an edge
    /// releases a texture a visible layer still samples.
    /// Stripping repeats, because the executor strips one `_rt_` and then matches:
    /// a reader asking for `_rt__rt_Foo` resolves a writer's `_rt_Foo`, so keying
    /// those to `rt_foo` and `foo` would lose that edge.
    private nonisolated static func normalizedTargetKey(_ name: String) -> String {
        var key = name.lowercased()
        while true {
            if key.hasPrefix("_rt_") { key = String(key.dropFirst(4)); continue }
            if key.hasPrefix("rt_") { key = String(key.dropFirst(3)); continue }
            if key.hasPrefix("_") { key = String(key.dropFirst()); continue }
            break
        }
        return key
    }

    /// Render-target names a pass samples. Scene alias names are NOT excluded:
    /// a name only enters the tainted set when some layer writes it as a real
    /// target, and writing e.g. `_rt_HalfFrameBuffer` as an actual target is
    /// supported. A `.scene` write contributes no name at all, so reading the
    /// scene-so-far still taints nothing.
    private nonisolated static func passSampledTargetNames(
        _ pass: WPEPreparedRenderPass
    ) -> [String] {
        var references: [WPETextureReference] = [pass.pass.source]
        references.append(contentsOf: pass.pass.textures.values)
        references.append(contentsOf: pass.pass.binds.values)
        references.append(contentsOf: pass.textureBindings.values)
        return references.compactMap { reference in
            switch reference {
            case .fbo(let name):
                return normalizedTargetKey(name)
            case .previous:
                // The executor resolves `.previous` from the pass's own target, so
                // the pass samples whatever that target already holds. Reusing the
                // propagation helper also drops `.scene`/layer-group correctly: a
                // hidden layer never contributes to those.
                return passPropagatedTargetName(pass)
            case .image, .asset:
                return nil
            }
        }
    }

    private nonisolated static func passPropagatedTargetName(
        _ pass: WPEPreparedRenderPass
    ) -> String? {
        switch pass.pass.target {
        case .scene:
            return nil
        case .fbo(let name) where WPERenderTargetNames.LayerGroup.matches(name):
            return nil
        case .fbo(let name), .layerComposite(let name):
            return normalizedTargetKey(name)
        }
    }

    /// Per-frame half: the video keys some visible layer can show this frame.
    /// Pure + static for unit testing.
    nonisolated static func neededOnDemandVideoKeys(
        in layers: [WPEPreparedRenderLayer],
        keysByConsumerID: [String: Set<String>],
        keysByImagePath: [String: Set<String>] = [:]
    ) -> Set<String> {
        guard !keysByConsumerID.isEmpty else { return [] }
        var needed: Set<String> = []
        for layer in layers where layer.graphLayer.visible {
            if let keys = keysByConsumerID[layer.graphLayer.objectID] {
                needed.formUnion(keys)
                continue
            }
            // `thisScene.createLayer` clones get a fresh objectID the load-time
            // graph never saw, so they inherit their template's entry through the
            // shared image path. Without this a hidden template releases the very
            // video its visible clone samples, and the clone shows the placeholder
            // for the rest of the scene.
            let path = layer.graphLayer.imagePath
            guard !path.isEmpty, let inherited = keysByImagePath[path] else { continue }
            needed.formUnion(inherited)
        }
        return needed
    }

    /// Load-time companion to the consumer graph: image path → the video keys any
    /// layer drawing that image consumes. Only script-created clones need it.
    nonisolated static func onDemandVideoKeysByImagePath(
        layers: [WPEPreparedRenderLayer],
        keysByConsumerID: [String: Set<String>]
    ) -> [String: Set<String>] {
        guard !keysByConsumerID.isEmpty else { return [:] }
        var result: [String: Set<String>] = [:]
        for layer in layers {
            let path = layer.graphLayer.imagePath
            guard !path.isEmpty,
                  let keys = keysByConsumerID[layer.graphLayer.objectID] else { continue }
            result[path, default: []].formUnion(keys)
        }
        return result
    }

    static func createdLayerTemplatesByImagePath(
        _ pipeline: WPEPreparedRenderPipeline
    ) -> [String: WPEPreparedRenderLayer] {
        var templates: [String: WPEPreparedRenderLayer] = [:]
        for layer in pipeline.layers {
            let path = layer.graphLayer.imagePath
            guard !path.isEmpty,
                  templates[path] == nil,
                  layer.puppetModel == nil,
                  layer.passes.count == 1 else {
                continue
            }
            templates[path] = layer
        }
        return templates
    }

    /// Per-frame: an on-demand video source is resident iff some CONSUMER of it is
    /// visible this frame — the layer sampling it, or any layer downstream of the
    /// FBOs that layer feeds (`onDemandVideoKeysByConsumerID`, built at load).
    /// Otherwise it's released (freeing its resident MP4 + buffers) and rebuilt on
    /// the next reveal. Aggregated by texture key, so two layers sharing one video
    /// keep it while either is visible.
    func reconcileVideoResidency(_ framePipeline: WPEPreparedRenderPipeline) {
        guard !onDemandVideoKeyByID.isEmpty else { return }
        let neededKeys = Self.neededOnDemandVideoKeys(
            in: framePipeline.layers,
            keysByConsumerID: onDemandVideoKeysByConsumerID,
            keysByImagePath: onDemandVideoKeysByImagePath
        )
        for key in Set(onDemandVideoKeyByID.values.joined()) {
            if neededKeys.contains(key) {
                lazyLoadVideo(key: key)
            } else if let source = dynamicTextureSources[key] as? WPEVideoTextureSource {
                // Phase-aligned intro/loop sources hold object references elsewhere;
                // releasing one would leave those refs dangling (no rebuild hook).
                guard source !== introPhaseSource, source !== loopPhaseSource else { continue }
                source.invalidate()
                dynamicTextureSources.removeValue(forKey: key)
                // 1×1 placeholder, not a removal: a stray sampler reference resolves
                // instead of erroring. A hidden layer's FBO passes DO still encode
                // and will sample this placeholder — harmless only because we got
                // here by proving nothing visible consumes those FBOs.
                loadedTextures[key] = (try? makeDynamicPlaceholderTexture(label: "\(key) released")) ?? loadedTextures[key]
            }
        }
    }

    private func lazyLoadVideo(key: String) {
        guard dynamicTextureSources[key] == nil,
              !onDemandVideoLoading.contains(key),
              let actor = displayActor else { return }
        onDemandVideoLoading.insert(key)
        let generation = loadGeneration
        // Re-enter the render actor to rebuild + force-play the revealed source
        // (a layer script re-issues its own play() next tick). Capture only the
        // actor (Sendable); the renderer is reached through it.
        Task { [actor] in
            await actor.rebuildOnDemandVideo(key: key, generation: generation)
        }
    }

    // MARK: - User properties

    /// Effective scene user-property values (project.json defaults ⊕ the
    /// descriptor's persisted overrides) bridged to the script value type, so a
    /// layer script's `applyUserProperties` sees the SAME bag WPE delivers. Keyed
    /// by the project.json property name the script reads (`timevarying`, etc.).
    func currentSceneScriptUserProperties() -> [String: WPESceneScriptPropertyValue] {
        let manifestRoot = projectManifestRootURL ?? cacheRootURL
        let values = WallpaperEngineProjectPropertySchema.effectiveSceneValues(
            descriptor: descriptor,
            cacheRootURL: manifestRoot
        )
        return Self.bridgeUserProperties(values)
    }

    static func bridgeUserProperties(
        _ values: [String: WallpaperEngineProjectPropertyValue]
    ) -> [String: WPESceneScriptPropertyValue] {
        values.reduce(into: [:]) { result, pair in
            switch pair.value {
            case .bool(let value): result[pair.key] = .bool(value)
            case .number(let value): result[pair.key] = .number(value)
            case .string(let value): result[pair.key] = .string(value)
            }
        }
    }

    // MARK: - Pointer events

    /// Per-layer hover transitions (`cursorEnter`/`cursorLeave`): hit-tests the
    /// pointer against each scripted layer's screen rect (axis-aligned; ortho =
    /// origin-centered size×scale, perspective = projected center + depth-scaled
    /// size) and dispatches only on state change. `pointer` nil (follow-cursor
    /// off / outside the view) counts as leaving everything. WPE fires these
    /// without click capture — hover only needs the cursor position.
    func dispatchLayerHoverEvents(
        pointer: SIMD2<Double>?,
        pipeline: WPEPreparedRenderPipeline,
        pointerFrame: WPEPointerFrame,
        runtimeSeconds: Double
    ) {
        guard !layerScriptInstances.isEmpty || !layerAlphaScriptInstances.isEmpty else { return }
        var geometryByID: [String: WPERenderLayerGeometry] = [:]
        for layer in pipeline.layers {
            let objectID = layer.graphLayer.objectID
            if layerScriptInstances[objectID] != nil || layerAlphaScriptInstances[objectID] != nil {
                geometryByID[objectID] = layer.graphLayer.geometry
            }
        }
        let width = Double(max(sceneRenderSize.width, 1))
        let height = Double(max(sceneRenderSize.height, 1))
        let pointerPixels = pointer.map { SIMD2<Double>($0.x * width, $0.y * height) }

        func dispatch(_ instances: [String: WPELayerScriptInstance]) {
            for (objectID, instance) in instances {
                let inside: Bool
                if let pointerPixels, let geometry = geometryByID[objectID] {
                    inside = pointerHits(pointerPixels, geometry: geometry)
                } else {
                    inside = false
                }
                let previous = layerHoverStates[objectID] ?? false
                guard inside != previous else { continue }
                layerHoverStates[objectID] = inside
                dispatchScriptCursorEvent(
                    instance,
                    event: inside ? .enter : .leave,
                    pointerFrame: pointerFrame,
                    runtimeSeconds: runtimeSeconds
                )
            }
        }
        dispatch(layerScriptInstances)
        dispatch(layerAlphaScriptInstances)

        if hoverCursorDebugEnabled, let pointerPixels {
            hoverDebugCounter += 1
            if hoverDebugCounter % 30 == 1 {
                for (objectID, geometry) in geometryByID.sorted(by: { $0.key < $1.key }) {
                    let rect = hoverHitRect(geometry: geometry)
                    Logger.notice(
                        "[hover] obj=\(objectID) pointer=(\(Int(pointerPixels.x)),\(Int(pointerPixels.y))) "
                            + "rect=\(rect.map { "c(\(Int($0.center.x)),\(Int($0.center.y)))±(\(Int($0.half.x)),\(Int($0.half.y)))" } ?? "nil") "
                            + "inside=\(rect.map { abs(pointerPixels.x - $0.center.x) <= $0.half.x && abs(pointerPixels.y - $0.center.y) <= $0.half.y } ?? false)",
                        category: .wpeRender
                    )
                }
            }
        }
    }
    /// Read once (static because extensions can't add stored instance
    /// properties): log-only toggle per WPERenderFlagRegistryTests, and no test
    /// flips it at runtime, so skipping per-frame defaults reads is safe.
    private static let hoverCursorDebugDefault = UserDefaults.standard.bool(forKey: "WPEHoverCursorDebug")
    private var hoverCursorDebugEnabled: Bool { Self.hoverCursorDebugDefault }

    /// Pointer (top-left scene pixels) vs a layer's axis-aligned screen rect.
    private func pointerHits(_ pointerPixels: SIMD2<Double>, geometry: WPERenderLayerGeometry) -> Bool {
        guard let rect = hoverHitRect(geometry: geometry) else { return false }
        return abs(pointerPixels.x - rect.center.x) <= rect.half.x
            && abs(pointerPixels.y - rect.center.y) <= rect.half.y
    }

    /// A scripted layer's hover rect in scene pixels. A MINIMUM half-extent
    /// (scaled to render size) keeps a distant/perspective-shrunk hover pad
    /// reachable — the n-body sim pushes some bodies far enough that their pad
    /// would otherwise project to a few pixels the cursor can't land on
    /// (3509243656's outer stars had no tooltip until this floor).
    private func hoverHitRect(
        geometry: WPERenderLayerGeometry
    ) -> (center: SIMD2<Double>, half: SIMD2<Double>)? {
        guard let size = geometry.size, size.width > 0, size.height > 0 else { return nil }
        let width = Double(max(sceneRenderSize.width, 1))
        let height = Double(max(sceneRenderSize.height, 1))
        let minHalf = max(height, 1) * 0.02
        let center: SIMD2<Double>
        var half: SIMD2<Double>
        if cameraUniforms.usesPerspectiveProjection {
            guard let projection = cameraUniforms.projectedCenterInScenePixels(
                worldPoint: geometry.origin,
                sceneSize: sceneRenderSize
            ) else { return nil }
            center = SIMD2<Double>(
                width * 0.5 + Double(projection.center.x),
                height * 0.5 - Double(projection.center.y)
            )
            let depthScale = Double(projection.depthScale)
            half = SIMD2<Double>(
                Double(size.width) * abs(geometry.scale.x) * depthScale * 0.5,
                Double(size.height) * abs(geometry.scale.y) * depthScale * 0.5
            )
        } else {
            center = SIMD2<Double>(geometry.origin.x, geometry.origin.y)
            half = SIMD2<Double>(
                Double(size.width) * abs(geometry.scale.x) * 0.5,
                Double(size.height) * abs(geometry.scale.y) * 0.5
            )
        }
        half.x = max(half.x, minHalf)
        half.y = max(half.y, minHalf)
        return (center, half)
    }

    /// Detects button edges between two pointer frames and fans each one out to
    /// every layer/alpha script instance.
    func dispatchPointerButtonEdges(
        from previous: WPEPointerFrame,
        to current: WPEPointerFrame,
        runtimeSeconds: Double
    ) {
        var events: [WPELayerScriptCursorEvent] = []
        if !previous.isDown, current.isDown { events.append(.down) }
        if previous.isDown, !current.isDown { events.append(.up) }
        if !previous.isRightDown, current.isRightDown { events.append(.rightDown) }
        if previous.isRightDown, !current.isRightDown { events.append(.rightUp) }
        guard !events.isEmpty else { return }

        for event in events {
            for instance in layerScriptInstances.values {
                dispatchScriptCursorEvent(
                    instance,
                    event: event,
                    pointerFrame: current,
                    runtimeSeconds: runtimeSeconds
                )
            }
            for instance in layerAlphaScriptInstances.values {
                dispatchScriptCursorEvent(
                    instance,
                    event: event,
                    pointerFrame: current,
                    runtimeSeconds: runtimeSeconds
                )
            }
        }
    }

    // MARK: - Script output application

    /// Applies a layer script's full output: its own layer plus any layers it
    /// drove via `thisScene.getLayer(name)` (resolved name→objectID).
    func applyLayerScriptOutput(_ output: WPELayerScriptOutput, ownObjectID: String) {
        applyLayerScriptState(output.own, objectID: ownObjectID)
        layerTransformMutationJournal.record(
            output.ownTransform,
            objectID: ownObjectID,
            generation: loadGeneration
        )
        for (name, state) in output.others {
            guard let targetID = layerObjectIDByName[name] else { continue }
            applyLayerScriptState(state, objectID: targetID)
        }
        for (name, mutation) in output.otherTransforms {
            guard let targetID = layerObjectIDByName[name] else { continue }
            layerTransformMutationJournal.record(
                mutation,
                objectID: targetID,
                generation: loadGeneration
            )
        }
        for created in output.created {
            guard !created.imagePath.isEmpty else { continue }
            var state = created
            state.key = "\(ownObjectID).\(created.key)"
            liveCreatedLayers[state.key] = state
        }
    }

    func applyLayerAlphaScriptOutput(_ output: WPELayerScriptOutput, ownObjectID: String) {
        liveLayerAlpha[ownObjectID] = output.own.alpha
    }

    // MARK: - Static-cache exclusion & ancestor visibility

    /// Layer IDs the static-layer cache must never admit. Origin/scale/angles
    /// scripts and live-created layers move geometry the classifier can't see.
    /// Layer/alpha scripts are excluded because `applyingLayerAlpha` bakes the
    /// script value into `geometry.alpha` and clears `alphaAnimation` BEFORE
    /// classification — a script-alpha layer would otherwise classify as static
    /// and freeze at its first-cached alpha. `scriptAlphaOverriddenIDs` (the live
    /// alpha override map's keys) additionally catches cross-layer writes: a layer
    /// script may set any other named layer's alpha via its `others` output, which
    /// is unknowable statically; passed per frame, so the target layer stops
    /// classifying as static the moment it is first written. Pure + static for
    /// unit testing.
    nonisolated static func staticCacheExcludedLayerIDs(
        originScriptIDs: some Sequence<String>,
        originAnimationIDs: some Sequence<String>,
        scaleScriptIDs: some Sequence<String>,
        anglesScriptIDs: some Sequence<String>,
        colorScriptIDs: some Sequence<String>,
        liveCreatedLayerIDs: some Sequence<String>,
        layerScriptIDs: some Sequence<String>,
        alphaScriptIDs: some Sequence<String>,
        scriptAlphaOverriddenIDs: some Sequence<String>
    ) -> Set<String> {
        var ids = Set(originScriptIDs)
        // Keyframed origins ride the same live-transform map as origin scripts,
        // so an animated host would otherwise freeze at its first cached position.
        ids.formUnion(originAnimationIDs)
        ids.formUnion(scaleScriptIDs)
        ids.formUnion(anglesScriptIDs)
        // Same reason as alpha: `applyingLayerColor` bakes the script value into
        // `geometry.color` before classification, so a color-scripted layer would
        // otherwise classify as static and freeze at its first cached tint.
        ids.formUnion(colorScriptIDs)
        ids.formUnion(liveCreatedLayerIDs)
        ids.formUnion(layerScriptIDs)
        ids.formUnion(alphaScriptIDs)
        ids.formUnion(scriptAlphaOverriddenIDs)
        return ids
    }

    var staticCacheExcludedLayerIDs: Set<String> {
        var ids = installedScriptLayerIDs
        ids.formUnion(textScriptInstances.keys)
        ids.formUnion(textRenderPlans.lazy.filter(\.copiesSceneBackground).map { $0.object.id })
        guard !liveCreatedLayers.isEmpty || !liveLayerAlpha.isEmpty else { return ids }
        ids.formUnion(liveCreatedLayers.keys)
        ids.formUnion(liveLayerAlpha.keys)
        return ids
    }

    /// The exclusion set's load-scoped part, memoized. `liveCreatedLayers` and
    /// `liveLayerAlpha` deliberately stay OUT of the cache — scripts grow them
    /// mid-frame, so their keys are unioned live above every frame.
    private var installedScriptLayerIDs: Set<String> {
        if let cached = cachedInstalledScriptLayerIDs { return cached }
        let ids = Self.staticCacheExcludedLayerIDs(
            originScriptIDs: dynamicOriginScriptInstances.keys,
            // Memo-safe despite `dynamicOriginAnimations` having no invalidating
            // didSet: loadDynamicOriginScripts writes it only AFTER resetting the
            // script-instance dicts (which do invalidate) in the same sync pass.
            originAnimationIDs: dynamicOriginAnimations.keys,
            scaleScriptIDs: dynamicScaleScriptInstances.keys,
            anglesScriptIDs: dynamicAnglesScriptInstances.keys,
            colorScriptIDs: dynamicColorScriptInstances.keys,
            liveCreatedLayerIDs: EmptyCollection<String>(),
            layerScriptIDs: layerScriptInstances.keys,
            alphaScriptIDs: layerAlphaScriptInstances.keys,
            scriptAlphaOverriddenIDs: EmptyCollection<String>()
        )
        cachedInstalledScriptLayerIDs = ids
        return ids
    }

    /// True unless some ancestor is currently hidden. Each ancestor's CURRENT
    /// visibility is its live override (image/script/text) if tracked, else its
    /// baked `visible` (groups) — so both static group toggles and live image
    /// toggles are honored. Pure + static for unit testing.
    nonisolated static func ancestorChainVisible(
        _ objectID: String,
        parentByID: [String: String],
        liveLayerVisibility: [String: Bool],
        liveTextVisibility: [String: Bool],
        ownVisibilityByID: [String: Bool]
    ) -> Bool {
        var seen: Set<String> = []
        var current = parentByID[objectID]
        while let id = current, seen.insert(id).inserted {
            let visible = liveLayerVisibility[id]
                ?? liveTextVisibility[id]
                ?? ownVisibilityByID[id]
                ?? true
            if !visible { return false }
            current = parentByID[id]
        }
        return true
    }

    func ancestorChainVisible(_ objectID: String) -> Bool {
        Self.ancestorChainVisible(
            objectID,
            parentByID: objectParentByID,
            liveLayerVisibility: liveLayerVisibility,
            liveTextVisibility: liveTextVisibility,
            ownVisibilityByID: ownVisibilityByID
        )
    }

    /// Applies one layer's resolved state and stages one-shot player mutations
    /// until every script family in the traversal succeeds.
    private func applyLayerScriptState(_ state: WPELayerScriptState, objectID: String) {
        // A hidden ancestor always wins — the script runtime's `getParent()` is an
        // always-visible stub, so a dock script gating on `parent.visible` can't
        // otherwise hide itself (green App Launcher Dock on 3660962877). Walk the
        // chain live so a runtime ancestor toggle is respected, not snapshotted.
        if state.visibleAssigned {
            liveLayerVisibility[objectID] = state.visible && ancestorChainVisible(objectID)
        }
        if state.alphaAssigned {
            liveLayerAlpha[objectID] = state.alpha
        }
        sceneScriptVideoCommandBuffer.enqueue(state.videoCommands, objectID: objectID)
    }

    /// External texture paths a layer references, in pass order — mirrors the
    /// `loadTextures` walk so a layer script can find its video source key.
    private func videoTexturePaths(for layer: WPEPreparedRenderLayer) -> [String] {
        var paths: [String] = []
        if layer.passes.isEmpty {
            if let path = externalTexturePath(for: .image(layer.graphLayer.imagePath)) {
                paths.append(path)
            }
            return paths
        }
        for pass in layer.passes {
            for reference in requiredTextureReferences(for: pass) {
                if let path = externalTexturePath(for: reference) {
                    paths.append(path)
                }
            }
        }
        return paths
    }
}
#endif
