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

/// Both layer-state scripts and transform-property scripts can export cursor
/// handlers. Implementations buffer the frame's burst and return a batch job
/// for the renderer-owned ordered drain (nil when nothing is pending).
protocol WPECursorEventScriptInstance: AnyObject {
    func enqueueCursorEvents(
        _ events: [WPELayerScriptCursorInvocation],
        allowSubmission: Bool
    ) -> WPESceneScriptBatchDispatcher.Job?
    func cancelPendingCursorEvents()
}

extension WPELayerScriptInstance: WPECursorEventScriptInstance {
    func enqueueCursorEvents(
        _ events: [WPELayerScriptCursorInvocation],
        allowSubmission: Bool = true
    ) -> WPESceneScriptBatchDispatcher.Job? {
        batchCursorEvents(events, allowSubmission: allowSubmission)
    }
}

extension WPEDynamicTransformScriptInstance: WPECursorEventScriptInstance {}

extension WPEMetalSceneRenderer {
    typealias CursorEventDelivery = (any WPECursorEventScriptInstance, [WPELayerScriptCursorEvent], WPEPointerFrame) -> Void

    // MARK: - Script loading & seeding

    func configureSceneScriptVideoSourceMapping() {
        guard let pipeline = renderPipeline else { return }
        let prior = layerVideoSourceKey
        layerVideoSourceKey = [:]
        for layer in pipeline.layers {
            let objectID = layer.graphLayer.objectID
            if let key = videoTexturePaths(for: layer).first(where: {
                dynamicTextureSources[$0] is WPEVideoTextureSource
                    || onDemandVideoKeyByID[objectID]?.contains($0) == true || prior[objectID] == $0
            }) {
                layerVideoSourceKey[layer.graphLayer.objectID] = key
            }
        }
    }

    func loadLayerScripts(
        from document: WPESceneDocument,
        scriptLoadToken: WPESceneScriptInstanceLimitToken
    ) {
        cancelCursorInputRouting()
        layerTransformMutationJournal.removeAll()
        liveLayerPresentation = [:]
        layerScriptInstances = [:]
        layerAlphaScriptInstances = [:]
        particleAlphaScriptInstances = [:]
        liveParticleInstanceAlpha = [:]
        textVisibleScriptInstances = [:]
        textAlphaScriptInstances = [:]
        liveTextAlpha = [:]
        liveScriptAssignedText = [:]
        layerHoverStates = [:]
        layerPressStates = [:]
        lastHoverPointerPixels = nil
        layerVideoSourceKey = [:]
        sceneScriptVideoCommandBuffer.forgetTransports()
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
        guard let pipeline = renderPipeline else { return }
        configureSceneScriptVideoSourceMapping()
        // Index every layer because scripts can control a different layer's video by name.
        for layer in pipeline.layers {
            let id = layer.graphLayer.objectID
            layerObjectIDByName[layer.graphLayer.objectName] = id
        }
        // `getLayer(name)` also reaches particle emitters; an image layer keeps a name both share.
        for object in document.particleObjects where layerObjectIDByName[object.name] == nil {
            layerObjectIDByName[object.name] = object.id
        }

        // Named non-drawable ancestors receive cross-layer writes too; keep drawable name precedence.
        // Duplicate/empty names retain the shared state's object-ID handle route.
        for object in document.transformHostObjects where layerObjectIDByName[object.name] == nil {
            layerObjectIDByName[object.name] = object.id
        }

        // Transform-only hosts also use the same video handles and shared source map.
        publishVideoPlaybackSnapshots()
        guard !visibleScripted.isEmpty || !alphaScripted.isEmpty || !scriptHosts.isEmpty
                || !textVisibleScripted.isEmpty || !textAlphaScripted.isEmpty
                || !particleAlphaScripted.isEmpty || !textScriptInstances.isEmpty
                || document.particleObjects.contains(where: { $0.instanceOverride?.rateScript != nil }) else { return }

        // One `shared` store for the whole scene so WPE's cross-script `shared`
        // global coordinates across the scripts' isolated contexts.
        let sharedState = sceneScriptSharedState
            ?? WPESharedScriptState(sceneScriptLoadToken: scriptLoadToken)
        sceneScriptSharedState = sharedState
        publishVideoPlaybackSnapshots()
        if Self.permitsSharedAuthoredLayerOrdering(document: document, pipeline: pipeline) {
            sharedState.configureAuthoredLayerOrdering(ownerIDs: Set(visibleScripted.map(\.id)))
        }
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
                    ownObjectID: object.id,
                    createdLayerBridge: Self.createdLayerBridgeConfiguration(
                        document: document, pipeline: pipeline, ownerName: object.name
                    ),
                    batchDispatcher: self.sceneScriptBatchDispatcher, initializationMode: .deferred)
                }) else { return }
                layerScriptInstances[object.id] = instance
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
                    ownObjectID: object.id,
                    createdLayerBridge: Self.createdLayerBridgeConfiguration(
                        document: document, pipeline: pipeline, ownerName: object.name
                    ),
                    batchDispatcher: self.sceneScriptBatchDispatcher, initializationMode: .deferred)
                }) else { return }
                layerScriptInstances[object.id] = instance
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
                    ownObjectID: object.id,
                    batchDispatcher: self.sceneScriptBatchDispatcher, initializationMode: .deferred)
                }) else { return }
                layerAlphaScriptInstances[object.id] = instance
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
                    ownObjectID: object.id,
                    batchDispatcher: self.sceneScriptBatchDispatcher, initializationMode: .deferred)
                }) else { return }
                textVisibleScriptInstances[object.id] = instance
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
                    ownObjectID: object.id,
                    batchDispatcher: self.sceneScriptBatchDispatcher, initializationMode: .deferred)
                }) else { return }
                textAlphaScriptInstances[object.id] = instance
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
                    ownObjectID: object.id,
                    batchDispatcher: self.sceneScriptBatchDispatcher, initializationMode: .deferred)
                }) else { return }
                particleAlphaScriptInstances[object.id] = instance
            } catch {
                _ = latchSceneScriptFailure(error, operation: .setup, token: scriptLoadToken)
                Logger.warning("Scene \(descriptor.workshopID) [ParticleAlphaScript] init failed for \(object.name): \(error)", category: .wpeRender)
            }
        }
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
            guard let targetID = scriptTargetObjectID(name) else { continue }
            applyLayerScriptState(state, objectID: targetID)
        }
        for call in output.videoCalls where !call.layerKey.isEmpty {
            guard let targetID = scriptTargetObjectID(call.layerKey) else { continue }
            sceneScriptVideoCommandBuffer.enqueue([call.command], objectID: targetID)
        }
        for (name, mutation) in output.otherTransforms {
            guard let targetID = scriptTargetObjectID(name) else { continue }
            layerTransformMutationJournal.record(
                mutation,
                objectID: targetID,
                generation: loadGeneration
            )
        }
        for (name, text) in output.texts {
            guard let id = name.isEmpty ? ownObjectID : scriptTargetObjectID(name) else { continue }
            liveScriptAssignedText[id] = text
        }
    }

    /// Duplicate or empty layer names reach scripts as object-ID keys; plain names map through the scene name index.
    private func scriptTargetObjectID(_ key: String) -> String? {
        if let id = wpeScriptLayerObjectID(key), sceneScriptSharedState?.layerTransform(id: id) != nil { return id }
        return layerObjectIDByName[key]
    }

    /// All modules are prepared before document-owner initialization; initial
    /// properties follow every init without inferring authored dependencies.
    func initializePreparedSceneScripts(
        from document: WPESceneDocument,
        scriptLoadToken: WPESceneScriptInstanceLimitToken
    ) {
        guard isCurrentSceneScriptLoad(scriptLoadToken), scriptLoadToken.allows(.setup) else { return }
        var jobs: [(ownerID: String, run: () -> Void)] = []
        func append(
            ownerID: String, initialize: @escaping () throws -> Void,
            accepted: @escaping () -> Void = {}
        ) {
            jobs.append((ownerID, {
                guard self.isCurrentSceneScriptLoad(scriptLoadToken), scriptLoadToken.allows(.setup) else { return }
                do {
                    try initialize()
                } catch {
                    _ = self.latchSceneScriptFailure(error, operation: .setup, token: scriptLoadToken)
                    Logger.warning("Scene \(self.descriptor.workshopID) script init failed for \(ownerID): \(error)", category: .wpeRender)
                }
                if self.isCurrentSceneScriptLoad(scriptLoadToken), scriptLoadToken.acceptsCompletion() {
                    accepted()
                }
            }))
        }
        let dynamicFamilies = [
            dynamicOriginScriptInstances, dynamicScaleScriptInstances,
            dynamicAnglesScriptInstances, dynamicColorScriptInstances,
            particleRateScriptInstances,
            dynamicParallaxDepthScriptInstances,
        ]
        for instances in dynamicFamilies {
            for (objectID, instance) in instances.sorted(by: { $0.key < $1.key }) {
                append(ownerID: objectID, initialize: instance.initializePreparedScript)
            }
        }
        for (key, instance) in effectConstantScriptInstances.sorted(by: { ($0.key.passID, $0.key.uniform) < ($1.key.passID, $1.key.uniform) }) {
            append(ownerID: instance.ownObjectID ?? key.passID, initialize: instance.initializePreparedScript)
        }
        for (key, instance) in effectVisibilityScriptInstances.sorted(by: { $0.key < $1.key }) {
            append(ownerID: instance.ownObjectID ?? key, initialize: instance.initializePreparedScript)
        }
        for (objectID, instance) in textScriptInstances.sorted(by: { $0.key < $1.key }) {
            append(ownerID: objectID, initialize: instance.initializePreparedScript)
        }
        let layerFamilies: [([String: WPELayerScriptInstance], (WPELayerScriptOutput, String) -> Void)] = [
            (layerScriptInstances, { self.applyLayerScriptOutput($0, ownObjectID: $1) }),
            (layerAlphaScriptInstances, { self.applyLayerAlphaScriptOutput($0, ownObjectID: $1) }),
            (textVisibleScriptInstances, { self.applyTextScriptOutput($0, ownObjectID: $1) }),
            (textAlphaScriptInstances, { self.applyTextAlphaScriptOutput($0, ownObjectID: $1) }),
            (particleAlphaScriptInstances, { self.applyParticleAlphaScriptOutput($0, ownObjectID: $1) }),
        ]
        for (instances, publish) in layerFamilies {
            for (objectID, instance) in instances.sorted(by: { $0.key < $1.key }) {
                append(ownerID: objectID, initialize: instance.initializePreparedScript,
                       accepted: { publish(instance.initialOutput, objectID) })
            }
        }
        let order = Dictionary((sceneScriptSharedState?.layers ?? []).map { ($0.id, $0.index) }, uniquingKeysWith: min)
        for job in jobs.enumerated().sorted(by: {
            (order[$0.element.ownerID] ?? Int.max, $0.offset) < (order[$1.element.ownerID] ?? Int.max, $1.offset)
        }) {
            job.element.run()
        }
        guard isCurrentSceneScriptLoad(scriptLoadToken), scriptLoadToken.allows(.event) else { return }
        consumeSceneScriptLayerOutputs()
        let userProperties = currentSceneScriptUserProperties()
        for (instances, publish) in layerFamilies {
            for (objectID, instance) in instances.sorted(by: { $0.key < $1.key }) {
                if let output = applyScriptUserProperties(instance, userProperties) {
                    publish(output, objectID)
                }
            }
        }
        dispatchTransformScriptUserProperties(userProperties)
        consumeSceneScriptLayerOutputs()
        setUpIntroPhaseAlign(scripted: document.imageObjects.filter { $0.visibleScript != nil }, scriptLoadToken: scriptLoadToken)
    }

    func seedSceneScriptsAfterLoad(
        from document: WPESceneDocument,
        scriptLoadToken: WPESceneScriptInstanceLimitToken
    ) {
        guard isCurrentSceneScriptLoad(scriptLoadToken),
              scriptLoadToken.allows(.tick) else { return }
        consumeSceneScriptLayerOutputs()
        applyInitialSceneScriptGeneralSettings()
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
            dynamicColorScriptInstances,
            particleRateScriptInstances,
            dynamicParallaxDepthScriptInstances
        ] {
            for (_, instance) in instances.sorted(by: { $0.key < $1.key }) {
                instance.seedAsyncTick(pointerPosition: neutralPointer)
            }
        }
        // 3. Seed text scripts in object order because later scripts may consume shared state.
        for object in textObjects {
            guard let instance = textScriptInstances[object.id] else { continue }
            instance.seedAsyncTick()
            if let output = instance.takeLayerOutput() {
                applyLayerScriptOutput(output, ownObjectID: object.id)
            }
        }
        // Effect constants BEFORE visibility gates: a gate reads what a constant script writes into `shared`, so seeding them out of order would leave the gate reading `undefined` and the first frame would render with every arm of the cycle closed.
        for (_, instance) in effectConstantScriptInstances
            .sorted(by: { ($0.key.passID, $0.key.uniform) < ($1.key.passID, $1.key.uniform) }) {
            instance.seedAsyncTick(pointerPosition: neutralPointer)
        }
        for (_, instance) in effectVisibilityScriptInstances.sorted(by: { $0.key < $1.key }) {
            instance.seedAsyncTick(pointerPosition: neutralPointer)
        }
        consumeSceneScriptLayerOutputs()
    }

    // MARK: - On-demand video layers

    /// The predecessor filter admitted only scene-only layers, so a hidden video that writes an FBO decoded at full rate forever; the consumer graph replaces that proxy, answered per frame by `reconcileVideoResidency`.
    func indexOnDemandVideoLayers(pipeline: WPEPreparedRenderPipeline) {
        onDemandVideoKeyByID = [:]
        onDemandVideoTasks = [:]
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

    static func createdLayerBridgeConfiguration(
        document: WPESceneDocument,
        pipeline: WPEPreparedRenderPipeline,
        ownerName: String
    ) -> WPECreatedLayerBridgeConfiguration {
        let scripts = document.imageObjects.compactMap { object in
            object.visibleScript.map { (object.name, $0) }
        } + document.scriptHostObjects.map { ($0.name, $0.visibleScript) }
        let namesByID: [String: String] = Dictionary(
            (document.imageObjects.map { ($0.id, $0.name) }
                + document.scriptHostObjects.map { ($0.id, $0.name) }
                + document.soundObjects.map { ($0.id, $0.name) }
                + document.transformHostObjects.map { ($0.id, $0.name) }),
            uniquingKeysWith: { first, _ in first }
        )
        let names = namesByID.keys.sorted {
            (document.objectPaintOrder[$0] ?? Int.max) < (document.objectPaintOrder[$1] ?? Int.max)
        }.compactMap { namesByID[$0] }
        return WPECreatedLayerBridgeConfiguration(
            imagePaths: Set(createdLayerTemplatesByImagePath(pipeline).keys),
            orderedLayerNames: names,
            allowsSorting: scripts.count == 1 && scripts.first?.0 == ownerName
                && document.imageObjects.allSatisfy { $0.alphaScript == nil }
                && Set(names).count == names.count && !names.contains("")
                && document.particleObjects.isEmpty && document.textObjects.isEmpty
                && pipeline.layers.allSatisfy(\.permitsIndependentImageReordering)
        )
    }

    static func createdLayerTemplatesByImagePath(
        _ pipeline: WPEPreparedRenderPipeline
    ) -> [String: WPEPreparedRenderLayer] {
        var templates: [String: WPEPreparedRenderLayer] = [:]
        for layer in pipeline.layers {
            let path = layer.graphLayer.imagePath
            guard !path.isEmpty,
                  templates[path] == nil,
                  layer.createdImagePassLayout != nil else {
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

    func lazyLoadVideo(key: String) {
        guard let actor = displayActor,
              onDemandVideoTasks[key] == nil else { return }
        let source = dynamicTextureSources[key] as? WPEVideoTextureSource
        guard Self.shouldStartOnDemandVideoLoad(
            hasResidentSource: source != nil,
            isLiveDecoder: source?.isLiveDecoder ?? false,
            admissionHasVacancy: videoDecoderAdmission.hasVacancy
        ) else { return }
        let generation = loadGeneration
        onDemandVideoTasks[key] = Task { [actor] in
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
        attachmentGeometry: [String: WPERenderLayerGeometry] = [:],
        deliver: CursorEventDelivery
    ) {
        guard !layerScriptInstances.isEmpty || !layerAlphaScriptInstances.isEmpty
            || !textVisibleScriptInstances.isEmpty || !textAlphaScriptInstances.isEmpty
            || !dynamicOriginScriptInstances.isEmpty || !dynamicScaleScriptInstances.isEmpty
            || !dynamicAnglesScriptInstances.isEmpty || !dynamicColorScriptInstances.isEmpty
            || !dynamicParallaxDepthScriptInstances.isEmpty
            || !effectVisibilityScriptInstances.isEmpty || !effectConstantScriptInstances.isEmpty
        else { return }
        var geometryByID: [String: WPERenderLayerGeometry] = [:]
        for layer in pipeline.layers {
            let objectID = layer.graphLayer.objectID
            if layerScriptInstances[objectID] != nil || layerAlphaScriptInstances[objectID] != nil
                || textVisibleScriptInstances[objectID] != nil
                || textAlphaScriptInstances[objectID] != nil
                || dynamicOriginScriptInstances[objectID] != nil
                || dynamicScaleScriptInstances[objectID] != nil
                || dynamicAnglesScriptInstances[objectID] != nil
                || dynamicColorScriptInstances[objectID] != nil
                || dynamicParallaxDepthScriptInstances[objectID] != nil {
                geometryByID[objectID] = attachmentGeometry[objectID] ?? layer.graphLayer.geometry
            }
        }
        // Effect-constant/visibility scripts key by pass, not object — resolve the host object.
        for instance in [WPEDynamicTransformScriptInstance](effectConstantScriptInstances.values)
            + effectVisibilityScriptInstances.values {
            guard let id = instance.ownObjectID, geometryByID[id] == nil,
                  let layer = pipeline.layers.first(where: { $0.graphLayer.objectID == id }) else { continue }
            geometryByID[id] = attachmentGeometry[id] ?? layer.graphLayer.geometry
        }
        let width = Double(max(sceneRenderSize.width, 1))
        let height = Double(max(sceneRenderSize.height, 1))
        let pointerPixels = pointer.map { SIMD2<Double>($0.x * width, $0.y * height) }

        // A pressed layer owns moves through release, including after leaving
        // its hit region. Without capture, authored drag handlers stop midway.
        let moved = pointerPixels != lastHoverPointerPixels
        lastHoverPointerPixels = pointerPixels
        // All property scripts on an object receive the same transition.
        let previousHoverStates = layerHoverStates
        forEachCursorScriptInstance { objectID, instance in
            let inside: Bool
            if let pointerPixels, let geometry = geometryByID[objectID] {
                inside = pointerHits(pointerPixels, geometry: geometry)
            } else {
                inside = false
            }
            let previous = previousHoverStates[objectID] ?? false
            var events: [WPELayerScriptCursorEvent] = []
            if inside != previous {
                layerHoverStates[objectID] = inside
                events.append(inside ? .enter : .leave)
            }
            let captured = layerPressStates[objectID] == true && pointerFrame.isDown
            if moved, inside || captured { events.append(.move) }
            deliver(instance, events, pointerFrame)
        }

    }

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
            projection: projection,
            camera: cameraUniforms
        )
    }

    /// `projection` non-nil selects the perspective branch and carries the already-projected, scene-centred (Y-up) centre plus its depth scale.
    /// `camera` supplies the orthographic pan/zoom the quad is drawn with.
    static func hoverHitRect(
        geometry: WPERenderLayerGeometry,
        sceneSize: CGSize,
        projection: (center: SIMD2<Double>, depthScale: Double)?,
        camera: WPEMetalCameraUniforms = .identity
    ) -> (center: SIMD2<Double>, half: SIMD2<Double>)? {
        guard let size = geometry.size, size.width > 0, size.height > 0 else { return nil }
        let width = Double(max(sceneSize.width, 1))
        let height = Double(max(sceneSize.height, 1))
        let minHalf = max(height, 1) * 0.02
        var center: SIMD2<Double>
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
            // Only the camera's shift goes through Float, so an identity camera keeps the Double origin exact.
            let authored = WPEMetalRenderExecutor.centeredOrigin(of: geometry, sceneSize: sceneSize)
            let shift = camera.transformScenePoint(authored) - authored
            let zoom = camera.sceneMotion.zoom
            center = SIMD2<Double>(geometry.origin.x + Double(shift.x), height - geometry.origin.y - Double(shift.y))
            half = SIMD2<Double>(
                Double(size.width) * abs(geometry.scale.x) * zoom * 0.5,
                Double(size.height) * abs(geometry.scale.y) * zoom * 0.5
            )
        }
        // Same shift the draw path applies; it is Y-up, so its Y flips into pointer space.
        let alignmentOffset = WPEMetalRenderExecutor.alignmentCenterOffset(
            alignment: geometry.alignment,
            width: Float(half.x * 2),
            height: Float(half.y * 2)
        )
        center.x += Double(alignmentOffset.x)
        center.y -= Double(alignmentOffset.y)
        half.x = max(half.x, minHalf)
        half.y = max(half.y, minHalf)
        return (center, half)
    }

    /// `cursorClick` is synthesised from a press and release that both land on the same layer. This stays a plain per-layer AABB test and does not claim to resolve overlapping hit boxes.
    func dispatchPointerButtonEdges(
        from previous: WPEPointerFrame,
        to current: WPEPointerFrame,
        deliver: CursorEventDelivery
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
            deliver(instance, batch, current)
        }
        if released { layerPressStates.removeAll(keepingCapacity: true) }
    }

    /// `textVisible` and `textAlpha` are the same `WPELayerScriptInstance` type as the layer families; leaving them out would silently drop those handlers. Transform-property scripts are a different class but can export the same handlers (workshop 3809609151 gates poses on `cursorClick` inside `angles` scripts).
    func forEachCursorScriptInstance(
        _ body: (String, any WPECursorEventScriptInstance) -> Void
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
        for instances in [
            dynamicOriginScriptInstances,
            dynamicScaleScriptInstances,
            dynamicAnglesScriptInstances,
            dynamicColorScriptInstances,
            dynamicParallaxDepthScriptInstances,
        ] {
            for (objectID, instance) in instances
            where seen.insert(ObjectIdentifier(instance)).inserted {
                body(objectID, instance)
            }
        }
        // Gate-keyed dicts: the key is a pass/gate id, not an object id, so the
        // host object must come from the instance — like the constants loop.
        for (gateID, instance) in effectVisibilityScriptInstances
        where seen.insert(ObjectIdentifier(instance)).inserted {
            body(instance.ownObjectID ?? gateID, instance)
        }
        for (key, instance) in effectConstantScriptInstances
        where seen.insert(ObjectIdentifier(instance)).inserted {
            body(instance.ownObjectID ?? key.passID, instance)
        }
    }

    func cancelCursorInputRouting() {
        mailbox.resetButtonEvents()
        previousLayerScriptPointerFrame = .neutral
        layerPressStates.removeAll(keepingCapacity: true)
        forEachCursorScriptInstance { _, instance in instance.cancelPendingCursorEvents() }
    }

    // MARK: - Script output application

    func applyLayerScriptOutput(_ output: WPELayerScriptOutput, ownObjectID: String) {
        applyLayerScriptState(output.own, objectID: ownObjectID)
        applyLayerScriptSideEffects(output, ownObjectID: ownObjectID)
    }

    /// Property-return scripts bind only their own alpha; their other layer and transport writes use the normal journal.
    func applyLayerScriptSideEffects(_ output: WPELayerScriptOutput, ownObjectID: String) {
        let targetID = scriptTargetObjectID
        layerTransformMutationJournal.record(
            output.ownTransform,
            objectID: ownObjectID,
            generation: loadGeneration
        )
        for (name, state) in output.others {
            guard let targetID = targetID(name) else { continue }
            applyLayerScriptState(state, objectID: targetID)
        }
        for call in output.videoCalls {
            guard let id = call.layerKey.isEmpty ? ownObjectID : targetID(call.layerKey) else { continue }
            sceneScriptVideoCommandBuffer.enqueue([call.command], objectID: id)
        }
        for (name, mutation) in output.otherTransforms {
            guard let targetID = targetID(name) else { continue }
            layerTransformMutationJournal.record(
                mutation,
                objectID: targetID,
                generation: loadGeneration
            )
        }
        for (name, mutation) in output.presentation {
            guard let id = name.isEmpty ? ownObjectID : targetID(name) else { continue }
            liveLayerPresentation[id, default: .init()].merge(mutation)
        }
        for (name, text) in output.texts {
            guard let id = name.isEmpty ? ownObjectID : targetID(name) else { continue }
            liveScriptAssignedText[id] = text
        }
        for created in output.created {
            guard !created.imagePath.isEmpty else { continue }
            var state = created
            state.key = "\(ownObjectID).\(created.key)"
            liveCreatedLayers[state.key] = state
        }
        for key in output.destroyedCreatedKeys {
            liveCreatedLayers.removeValue(forKey: "\(ownObjectID).\(key)")
        }
    }

    func applyLayerAlphaScriptOutput(_ output: WPELayerScriptOutput, ownObjectID: String) {
        if output.own.alphaAssigned {
            liveLayerAlpha[ownObjectID] = output.own.alpha
        }
        applyLayerScriptSideEffects(output, ownObjectID: ownObjectID)
    }

    func applyTextAlphaScriptOutput(_ output: WPELayerScriptOutput, ownObjectID: String) {
        liveTextAlpha[ownObjectID] = output.own.alpha
        applyLayerScriptSideEffects(output, ownObjectID: ownObjectID)
    }

    func applyParticleAlphaScriptOutput(_ output: WPELayerScriptOutput, ownObjectID: String) {
        liveParticleInstanceAlpha[ownObjectID] = output.own.alpha
        applyLayerScriptSideEffects(output, ownObjectID: ownObjectID)
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
        ids.formUnion(liveLayerPresentation.compactMap { id, mutation in
            mutation.alignment != nil || mutation.parallaxDepth != nil ? id : nil
        })
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
            colorScriptIDs: Array(dynamicColorScriptInstances.keys) + Array(sharedColorReadFans.keys)
                + Array(dynamicParallaxDepthScriptInstances.keys) + Array(sharedParallaxReadFans.keys),
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
        // Store the script-assigned OWN flag — ancestors fold in at the frame
        // overlay (`liveLayerVisibilityIncludingText`), which also re-shows this
        // object's subtree when the assignment makes it visible again.
        // Text objects draw from the text maps, which also win the merge over the layer maps.
        let isText = liveTextVisibility[objectID] != nil
        if state.visibleAssigned {
            if isText {
                liveTextVisibility[objectID] = state.visible
            } else {
                liveLayerVisibility[objectID] = state.visible
            }
        }
        if state.alphaAssigned {
            if isText {
                liveTextAlpha[objectID] = state.alpha
            } else {
                liveLayerAlpha[objectID] = state.alpha
            }
        }
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
