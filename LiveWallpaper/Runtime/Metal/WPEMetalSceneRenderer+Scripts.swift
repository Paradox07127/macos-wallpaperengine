#if !LITE_BUILD
import AppKit
import LiveWallpaperCore
import LiveWallpaperProWPE
import MetalKit

/// Load generation is part of the key so an outcome from a retired scene cannot move an object in the replacement scene that reused its objectID.
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

    func loadLayerScripts(
        from document: WPESceneDocument,
        scriptLoadToken: WPESceneScriptInstanceLimitToken
    ) {
        layerTransformMutationJournal.removeAll()
        layerScriptInstances = [:]
        layerAlphaScriptInstances = [:]
        particleAlphaScriptInstances = [:]
        liveParticleInstanceAlpha = [:]
        textVisibleScriptInstances = [:]
        textAlphaScriptInstances = [:]
        liveTextAlpha = [:]
        layerHoverStates = [:]
        layerPressStates = [:]
        lastHoverPointerPixels = nil
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
        let particleAlphaScripted = document.particleObjects
            .filter { $0.instanceOverride?.alphaScript != nil }
        let scriptHosts = document.scriptHostObjects
        debugStage(
            "layerScripts.load",
            "hosts=\(scriptHosts.count) visible=\(visibleScripted.count) alpha=\(alphaScripted.count) "
                + "textVisible=\(textVisibleScripted.count) textAlpha=\(textAlphaScripted.count) "
                + "particleAlpha=\(particleAlphaScripted.count) "
                + "hostNames=\(scriptHosts.prefix(8).map(\.name).joined(separator: ","))"
        )
        guard (!visibleScripted.isEmpty || !alphaScripted.isEmpty || !scriptHosts.isEmpty
                || !textVisibleScripted.isEmpty || !textAlphaScripted.isEmpty
                || !particleAlphaScripted.isEmpty),
              let pipeline = renderPipeline else { return }

        // Index every layer because scripts can control a different layer's video by name.
        for layer in pipeline.layers {
            let id = layer.graphLayer.objectID
            layerObjectIDByName[layer.graphLayer.objectName] = id
            if let key = videoTexturePaths(for: layer).first(where: { dynamicTextureSources[$0] is WPEVideoTextureSource }) {
                layerVideoSourceKey[id] = key
            }
        }

        // WPE delivers the user-property bag to each script after init(); without this, time-of-day scripts that gate on it (e.g. `timevarying`) never switch.
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
        let scriptScreenSize = SIMD2<Double>(
            max(Double(surfaceDrawableSize.width), 1),
            max(Double(surfaceDrawableSize.height), 1)
        )
        for object in scriptHosts {
            do {
                guard let instance = try constructSceneScript(for: scriptLoadToken, {
                    try WPELayerScriptInstance(
                    script: object.visibleScript,
                    scriptProperties: object.scriptProperties,
                    shared: sharedState,
                    canvasSize: scriptCanvasSize,
                    screenSize: scriptScreenSize,
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
                    screenSize: scriptScreenSize,
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
                    screenSize: scriptScreenSize,
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
                    screenSize: scriptScreenSize,
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
                    screenSize: scriptScreenSize,
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
        for object in particleAlphaScripted {
            guard let override = object.instanceOverride,
                  let script = override.alphaScript else { continue }
            do {
                guard let instance = try constructSceneScript(for: scriptLoadToken, {
                    try WPELayerScriptInstance(
                    script: script,
                    scriptProperties: override.alphaScriptProperties,
                    shared: sharedState,
                    canvasSize: scriptCanvasSize,
                    screenSize: scriptScreenSize,
                    // WPE hands `update(value)` the property's live value; the
                    // authored `value` inside the envelope is its seed.
                    outputMode: .returnedAlpha(initialValue: override.alpha ?? 1),
                    ownLayerName: object.name,
                    batchDispatcher: self.sceneScriptBatchDispatcher)
                }) else { return }
                particleAlphaScriptInstances[object.id] = instance
                liveParticleInstanceAlpha[object.id] = instance.initialOutput.own.alpha
                if let output = applyScriptUserProperties(instance, userProperties) {
                    liveParticleInstanceAlpha[object.id] = output.own.alpha
                }
            } catch {
                _ = latchSceneScriptFailure(error, operation: .setup, token: scriptLoadToken)
                Logger.warning("Scene \(descriptor.workshopID) [ParticleAlphaScript] init failed for \(object.name): \(error)", category: .wpeRender)
            }
        }
        setUpIntroPhaseAlign(
            scripted: visibleScripted,
            scriptLoadToken: scriptLoadToken
        )
    }

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

    /// One deterministic frame-0 pass — producers first. A `shared`-consumer must never evaluate before its producers; seeding inside each loader would let a consumer's first read hit empty `shared` and permanently corrupt state.
    func seedSceneScriptsAfterLoad(
        from document: WPESceneDocument,
        scriptLoadToken: WPESceneScriptInstanceLimitToken
    ) {
        guard isCurrentSceneScriptLoad(scriptLoadToken),
              scriptLoadToken.allows(.tick) else { return }
        applyInitialSceneScriptGeneralSettings()
        // Transform families must get the initial full user-property bag here — before the seeding ticks below — because a script that initialises state in the handler otherwise computes its first value from `undefined`.
        dispatchTransformScriptUserProperties(currentSceneScriptUserProperties())
        for host in document.scriptHostObjects {
            guard let instance = layerScriptInstances[host.id] else { continue }
            if let output = instance.tick(runtimeSeconds: 0, pointerFrame: .neutral) {
                applyLayerScriptOutput(output, ownObjectID: host.id)
            }
        }
        // Transform scripts, neutral pointer (the frame path's follow-cursor-off default) — first frame shows the scripted transform instead of popping from the baked value.
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
        // Effect constants BEFORE visibility gates: a gate reads what a constant script writes into `shared`, so seeding them out of order would leave the gate reading `undefined` and the first frame would render with every arm of the cycle closed.
        for (_, instance) in effectConstantScriptInstances
            .sorted(by: { ($0.key.passID, $0.key.uniform) < ($1.key.passID, $1.key.uniform) }) {
            instance.seedAsyncTick(pointerPosition: neutralPointer)
        }
        for (_, instance) in effectVisibilityScriptInstances.sorted(by: { $0.key < $1.key }) {
            instance.seedAsyncTick(pointerPosition: neutralPointer)
        }
    }

    // MARK: - On-demand video layers

    /// The predecessor filter admitted only scene-only layers, so a hidden video that writes an FBO decoded at full rate forever; the consumer graph replaces that proxy, answered per frame by `reconcileVideoResidency`.
    func indexOnDemandVideoLayers(pipeline: WPEPreparedRenderPipeline) {
        onDemandVideoKeyByID = [:]
        onDemandVideoLoading = []
        for layer in pipeline.layers {
            // Every video the layer samples, not just the first: a layer can bind one video as its source and another in a shader slot, and indexing only one of them would drop the other layer's consumer edge.
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

    /// Seeded with layers that sample the video, then closed transitively over the FBO/composite graph. `.scene`/`_rt_layerGroup_*` writes deliberately do not propagate — those are the two targets a hidden layer never reaches.
    nonisolated static func onDemandVideoKeysByConsumerLayer(
        layers: [WPEPreparedRenderLayer],
        videoKeyByLayerID: [String: Set<String>]
    ) -> [String: Set<String>] {
        guard !videoKeyByLayerID.isEmpty else { return [:] }
        // Per-layer unions, not per-pass: a layer's passes chain through `.previous` and its own composites, so any input reaching the layer can reach every target it writes.
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

    /// `resolveAliasedNamedTexture` strips `_rt_` / leading `_` and ignores case, so comparing raw strings here would lose edges the executor actually draws. Stripping repeats because a reader asking for `_rt__rt_Foo` resolves a writer's `_rt_Foo`.
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

    /// Scene alias names are not excluded: a name only enters the tainted set when some layer writes it as a real target. A `.scene` write contributes no name, so reading the scene-so-far still taints nothing.
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
                // The executor resolves `.previous` from the pass's own target, so the pass samples whatever that target already holds. Reusing the propagation helper also drops `.scene`/layer-group correctly: a hidden layer never contributes to those.
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
            // `thisScene.createLayer` clones get a fresh objectID the load-time graph never saw, so they inherit their template's entry through the shared image path. Without this a hidden template would release the video its visible clone samples.
            let path = layer.graphLayer.imagePath
            guard !path.isEmpty, let inherited = keysByImagePath[path] else { continue }
            needed.formUnion(inherited)
        }
        return needed
    }

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

    func reconcileVideoResidency(_ framePipeline: WPEPreparedRenderPipeline) {
        guard !onDemandVideoKeyByID.isEmpty else { return }
        let neededKeys = Self.neededOnDemandVideoKeys(
            in: framePipeline.layers,
            keysByConsumerID: onDemandVideoKeysByConsumerID,
            keysByImagePath: onDemandVideoKeysByImagePath
        )
        let allKeys = Set(onDemandVideoKeyByID.values.joined())
        // Release hidden sources first so overflow stills can take the tickets
        // in this same frame instead of waiting for the next vsync.
        for key in allKeys where !neededKeys.contains(key) {
            guard let source = dynamicTextureSources[key] as? WPEVideoTextureSource else { continue }
            // Phase-aligned intro/loop sources hold object references elsewhere;
            // releasing one would leave those refs dangling (no rebuild hook).
            guard source !== introPhaseSource, source !== loopPhaseSource else { continue }
            source.invalidate()
            dynamicTextureSources.removeValue(forKey: key)
            // 1×1 placeholder, not a removal: a stray sampler reference resolves instead of erroring. A hidden layer's FBO passes do still encode and will sample this placeholder — harmless only because nothing visible consumes those FBOs.
            loadedTextures[key] = (try? makeDynamicPlaceholderTexture(label: "\(key) released")) ?? loadedTextures[key]
        }
        for key in neededKeys {
            lazyLoadVideo(key: key)
        }
    }

    static func shouldStartOnDemandVideoLoad(
        hasResidentSource: Bool,
        isLiveDecoder: Bool,
        admissionHasVacancy: Bool
    ) -> Bool {
        if !hasResidentSource { return true }
        return !isLiveDecoder && admissionHasVacancy
    }

    private func lazyLoadVideo(key: String) {
        guard let actor = displayActor,
              !onDemandVideoLoading.contains(key) else { return }
        let source = dynamicTextureSources[key] as? WPEVideoTextureSource
        guard Self.shouldStartOnDemandVideoLoad(
            hasResidentSource: source != nil,
            isLiveDecoder: source?.isLiveDecoder ?? false,
            admissionHasVacancy: WPEVideoDecoderAdmission.shared.hasVacancy
        ) else { return }
        onDemandVideoLoading.insert(key)
        let generation = loadGeneration
        Task { [actor] in
            await actor.rebuildOnDemandVideo(key: key, generation: generation)
        }
    }

    // MARK: - User properties

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

    /// `pointer` nil (follow-cursor off / outside the view) counts as leaving everything; WPE fires these without click capture — hover only needs the cursor position.
    func dispatchLayerHoverEvents(
        pointer: SIMD2<Double>?,
        pipeline: WPEPreparedRenderPipeline,
        pointerFrame: WPEPointerFrame,
        runtimeSeconds: Double
    ) {
        guard !layerScriptInstances.isEmpty || !layerAlphaScriptInstances.isEmpty
            || !textVisibleScriptInstances.isEmpty || !textAlphaScriptInstances.isEmpty
        else { return }
        var geometryByID: [String: WPERenderLayerGeometry] = [:]
        for layer in pipeline.layers {
            let objectID = layer.graphLayer.objectID
            if layerScriptInstances[objectID] != nil || layerAlphaScriptInstances[objectID] != nil
                || textVisibleScriptInstances[objectID] != nil
                || textAlphaScriptInstances[objectID] != nil {
                geometryByID[objectID] = layer.graphLayer.geometry
            }
        }
        let width = Double(max(sceneRenderSize.width, 1))
        let height = Double(max(sceneRenderSize.height, 1))
        let pointerPixels = pointer.map { SIMD2<Double>($0.x * width, $0.y * height) }

        // `cursorMove` only on a real change, and only while the pointer is over the layer: a per-frame broadcast would run every move handler in the scene sixty times a second whether or not the cursor went anywhere.
        let moved = pointerPixels != lastHoverPointerPixels
        lastHoverPointerPixels = pointerPixels
        forEachCursorScriptInstance { objectID, instance in
            let inside: Bool
            if let pointerPixels, let geometry = geometryByID[objectID] {
                inside = pointerHits(pointerPixels, geometry: geometry)
            } else {
                inside = false
            }
            let previous = layerHoverStates[objectID] ?? false
            var events: [WPELayerScriptCursorEvent] = []
            if inside != previous {
                layerHoverStates[objectID] = inside
                events.append(inside ? .enter : .leave)
            }
            if moved, inside { events.append(.move) }
            dispatchScriptCursorEvents(
                instance,
                events: events,
                pointerFrame: pointerFrame,
                runtimeSeconds: runtimeSeconds
            )
        }

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
    private static let hoverCursorDebugDefault = UserDefaults.standard.bool(forKey: "WPEHoverCursorDebug")
    private var hoverCursorDebugEnabled: Bool { Self.hoverCursorDebugDefault }

    private func pointerHits(_ pointerPixels: SIMD2<Double>, geometry: WPERenderLayerGeometry) -> Bool {
        guard let rect = hoverHitRect(geometry: geometry) else { return false }
        return abs(pointerPixels.x - rect.center.x) <= rect.half.x
            && abs(pointerPixels.y - rect.center.y) <= rect.half.y
    }

    /// A minimum half-extent (scaled to render size) keeps a distant/perspective-shrunk hover pad reachable — otherwise the pad would project to a few pixels the cursor cannot land on.
    private func hoverHitRect(
        geometry: WPERenderLayerGeometry
    ) -> (center: SIMD2<Double>, half: SIMD2<Double>)? {
        let projection: (center: SIMD2<Double>, depthScale: Double)?
        if cameraUniforms.usesPerspectiveProjection {
            guard let projected = cameraUniforms.projectedCenterInScenePixels(
                worldPoint: geometry.origin,
                sceneSize: sceneRenderSize
            ) else { return nil }
            projection = (
                SIMD2<Double>(Double(projected.center.x), Double(projected.center.y)),
                Double(projected.depthScale)
            )
        } else {
            projection = nil
        }
        return Self.hoverHitRect(
            geometry: geometry,
            sceneSize: sceneRenderSize,
            projection: projection
        )
    }

    /// `projection` non-nil selects the perspective branch and carries the already-projected, scene-centred (Y-up) centre plus its depth scale.
    static func hoverHitRect(
        geometry: WPERenderLayerGeometry,
        sceneSize: CGSize,
        projection: (center: SIMD2<Double>, depthScale: Double)?
    ) -> (center: SIMD2<Double>, half: SIMD2<Double>)? {
        guard let size = geometry.size, size.width > 0, size.height > 0 else { return nil }
        let width = Double(max(sceneSize.width, 1))
        let height = Double(max(sceneSize.height, 1))
        let minHalf = max(height, 1) * 0.02
        let center: SIMD2<Double>
        var half: SIMD2<Double>
        if let projection {
            center = SIMD2<Double>(
                width * 0.5 + projection.center.x,
                height * 0.5 - projection.center.y
            )
            half = SIMD2<Double>(
                Double(size.width) * abs(geometry.scale.x) * projection.depthScale * 0.5,
                Double(size.height) * abs(geometry.scale.y) * projection.depthScale * 0.5
            )
        } else {
            // Authored origins are Y-up (`origin.y - sceneHeight/2`, no negation); the pointer arrives Y-down (`pointerSample` returns `1 - y`). Comparing the two raw would invert every hover.
            center = SIMD2<Double>(geometry.origin.x, height - geometry.origin.y)
            half = SIMD2<Double>(
                Double(size.width) * abs(geometry.scale.x) * 0.5,
                Double(size.height) * abs(geometry.scale.y) * 0.5
            )
        }
        half.x = max(half.x, minHalf)
        half.y = max(half.y, minHalf)
        return (center, half)
    }

    /// `cursorClick` is synthesised from a press and release that both land on the same layer. This stays a plain per-layer AABB test and does not claim to resolve overlapping hit boxes.
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

        let pressed = events.contains(.down)
        let released = events.contains(.up)
        if pressed { layerPressStates = layerHoverStates.filter { $0.value } }


        forEachCursorScriptInstance { objectID, instance in
            var batch: [WPELayerScriptCursorEvent] = []
            for event in events {
                batch.append(event)
                if event == .up,
                   layerPressStates[objectID] == true,
                   layerHoverStates[objectID] == true {
                    batch.append(.click)
                }
            }
            dispatchScriptCursorEvents(
                instance,
                events: batch,
                pointerFrame: current,
                runtimeSeconds: runtimeSeconds
            )
        }
        if released { layerPressStates.removeAll(keepingCapacity: true) }
    }

    /// `textVisible` and `textAlpha` are the same `WPELayerScriptInstance` type as the layer families; leaving them out would silently drop those handlers.
    private func forEachCursorScriptInstance(
        _ body: (String, WPELayerScriptInstance) -> Void
    ) {
        var seen: Set<ObjectIdentifier> = []
        for instances in [
            layerScriptInstances,
            layerAlphaScriptInstances,
            particleAlphaScriptInstances,
            textVisibleScriptInstances,
            textAlphaScriptInstances,
        ] {
            for (objectID, instance) in instances
            where seen.insert(ObjectIdentifier(instance)).inserted {
                body(objectID, instance)
            }
        }
    }

    // MARK: - Script output application

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

    /// Layer/alpha scripts are excluded because `applyingLayerAlpha` bakes the script value into `geometry.alpha` and clears `alphaAnimation` before classification — a script-alpha layer would otherwise classify as static and freeze at its first-cached alpha.
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
        // Same reason as alpha: `applyingLayerColor` bakes the script value into `geometry.color` before classification, so a color-scripted layer would otherwise classify as static and freeze at its first cached tint.
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

    /// `liveCreatedLayers` and `liveLayerAlpha` deliberately stay out of the cache — scripts grow them mid-frame, so their keys are unioned live above every frame.
    private var installedScriptLayerIDs: Set<String> {
        if let cached = cachedInstalledScriptLayerIDs { return cached }
        let ids = Self.staticCacheExcludedLayerIDs(
            originScriptIDs: Array(dynamicOriginScriptInstances.keys) + Array(sharedOriginReadFans.keys),
            // Memo-safe despite `dynamicOriginAnimations` having no invalidating didSet: loadDynamicOriginScripts writes it only after resetting the script-instance dicts (which do invalidate) in the same sync pass.
            originAnimationIDs: dynamicOriginAnimations.keys,
            scaleScriptIDs: Array(dynamicScaleScriptInstances.keys) + Array(sharedScaleReadFans.keys),
            anglesScriptIDs: Array(dynamicAnglesScriptInstances.keys) + Array(sharedAnglesReadFans.keys),
            colorScriptIDs: Array(dynamicColorScriptInstances.keys) + Array(sharedColorReadFans.keys),
            liveCreatedLayerIDs: EmptyCollection<String>(),
            layerScriptIDs: layerScriptInstances.keys,
            alphaScriptIDs: layerAlphaScriptInstances.keys,
            scriptAlphaOverriddenIDs: EmptyCollection<String>()
        )
        cachedInstalledScriptLayerIDs = ids
        return ids
    }

    /// True unless some ancestor is currently hidden. Each ancestor's current visibility is its live override if tracked, else its baked `visible`.
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

    private func applyLayerScriptState(_ state: WPELayerScriptState, objectID: String) {
        // A hidden ancestor always wins — the script runtime's `getParent()` is an always-visible stub, so a dock script gating on `parent.visible` cannot otherwise hide itself. Walk the chain live so a runtime ancestor toggle is respected, not snapshotted.
        if state.visibleAssigned {
            liveLayerVisibility[objectID] = state.visible && ancestorChainVisible(objectID)
        }
        if state.alphaAssigned {
            liveLayerAlpha[objectID] = state.alpha
        }
        sceneScriptVideoCommandBuffer.enqueue(state.videoCommands, objectID: objectID)
    }

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
