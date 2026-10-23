#if !LITE_BUILD
import Foundation
import LiveWallpaperProWPE
import Metal

extension WPEParityFrameRenderer {
    /// Opt-in cohort event counts, not resource/byte accounting. Reasons may overlap. Preparation counts
    /// include rejected candidates; acceptance is counted separately. No GPU or previous-renderer owner is kept.
    struct TextReplanDiagnostics: Codable, Sendable {
        var attemptedCohorts = 0
        var attemptedRequests = 0
        var unchangedCohorts = 0
        var acceptedCohorts = 0
        var failedCohorts = 0
        var videoDeferredCohorts = 0
        var changedTextObjects = 0
        var frameRebuildCohorts = 0
        var extentChangedCohorts = 0
        var atlasKeyChangedCohorts = 0
        var colorScaleChangedCohorts = 0
        var fieldCombosChangedCohorts = 0
        var extentOnlyCohorts = 0
        var objectValueChangedCohorts = 0
        var glyphLayoutChangedCohorts = 0
        var frameLayoutReuseCohorts = 0
        var fullLayoutCohorts = 0
        var readinessChangedCohorts = 0
        var effectsChangedCohorts = 0
        var graphPreparationAttempts = 0
        var graphReusePreparations = 0
        var directExtentLayoutReuseCohorts = 0
    }

    /// Explicit diagnostic-host entry, called on this serial owner after load. Starts a fresh count interval.
    func startTextReplanDiagnostics() {
        textReplanDiagnostics = .init()
    }

    static let directTextExtentReuseEnvironmentKey = "LOOMSCREEN_PARITY_REUSE_DIRECT_TEXT_EXTENTS"

    static func resolveDirectTextExtentReuse(explicit: Bool? = nil,
                                             environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        if let explicit {
            return explicit
        }
        switch environment[directTextExtentReuseEnvironmentKey]?.lowercased() {
        case "1", "true": return true
        case "0", "false": return false
        default: return true
        }
    }

    #if DEBUG
    /// Value snapshots for the real Metal preparation guard, never an additional resource owner/cache.
    struct TextPreparationSnapshot {
        let texts: [String: WPEParitySceneText]
        let atlases: WPEParityTextAtlasTextures
        let pipelineAtlases: [String: WPEParityGlyphAtlasInstance]
        let layers: WPEParityLayerTransformSet
        let frames: [WPEParityFrame]
        let draws: [Int: WPEParityFrameDrawPlan]
        let targets: [WPEResourceID: MTLTexture]
        let bindings: WPEParityResourceBindings
        let executorIDs: [ObjectIdentifier]
        let pendingRequests: Int
        let initialization: MTLCommandBuffer?
    }

    var textFrameLayoutForTesting: WPEParityFrameLayout {
        graphs.layout.planned
    }

    var textPreparationState: TextPreparationSnapshot {
        textSnapshot(planner: planner, layers: layers, graphs: graphs, targets: targets,
                     pipelineAtlases: textPipeline.atlases, initialization: nil)
    }

    private func textSnapshot(planner: WPEParityFrameDrawPlanner, layers: WPEParityLayerTransformSet,
                              graphs: Graphs, targets: [WPEResourceID: MTLTexture],
                              pipelineAtlases: [String: WPEParityGlyphAtlasInstance],
                              initialization: MTLCommandBuffer?) -> TextPreparationSnapshot {
        TextPreparationSnapshot(texts: planner.texts, atlases: planner.textAtlases,
                                pipelineAtlases: pipelineAtlases, layers: layers,
                                frames: graphs.layout.frames, draws: graphs.layout.draws, targets: targets,
                                bindings: resourceBindings, executorIDs: graphs.executors.map(ObjectIdentifier.init),
                                pendingRequests: textRequests.count, initialization: initialization)
    }
    #endif
    /// The native text dirty hook is consumed only after this ordered cohort is admitted.
    func applyScriptText() {
        let textGeneration = instance.state.generation(.textLayout)
        let effectsGeneration = instance.state.effectVisibilityGeneration
        let changed = textGeneration != (pendingScriptTextGeneration ?? seenScriptText)
        let effectsChanged = effectsGeneration != (pendingTextEffectsGeneration ?? seenEffects)
        guard changed || effectsChanged else { return }
        discardSupersededFailedTexts()
        // Discarding a failed cohort also drops its pending receipt; its canonical fields remain unconsumed.
        let projectFields = textGeneration != (pendingScriptTextGeneration ?? seenScriptText)
        var latest = textPipeline.texts.mapValues(\.object)
        for request in textRequests {
            latest[request.object.id] = request.object
        }
        for sceneObject in plan.scene.scene.objects {
            guard var object = latest[sceneObject.id] else { continue }
            if projectFields {
                object = WPEParityTextFields.applying(to: object, state: instance.state)
            }
            let effects = instance.state.effects.indices.count {
                instance.state.effects[$0].objectID == object.id && instance.state.effectVisibility[$0]
            }
            textRequests.append(.init(object, effectCount: effects))
        }
        pendingScriptTextGeneration = textGeneration
        pendingTextEffectsGeneration = effectsGeneration
    }

    func discardSupersededFailedTexts() {
        guard failedTextRequestCount > 0 else { return }
        // Only the failed attempted prefix is superseded; preserve an already appended unattempted tail.
        textRequests.removeFirst(failedTextRequestCount)
        failedTextRequestCount = 0
        pendingScriptTextGeneration = nil
        pendingTextEffectsGeneration = nil
    }

    private func consumeTextRequests(_ count: Int) {
        textRequests.removeFirst(count)
        failedTextRequestCount = 0
        if let generation = pendingScriptTextGeneration {
            seenScriptText = generation
        }
        pendingScriptTextGeneration = nil
        pendingTextEffectsGeneration = nil
    }

    /// Mirror the existing decision inputs only for a requested probe. The original predicates below remain
    /// authoritative; no renderer state, atlas or planner is mutated by this classification.
    private func recordTextReplanReasons(_ changes: [WPEParityTextRelayoutDelta.Change],
                                         changedObjectCount: Int, requiresRebuild: Bool, keepsFrame: Bool) {
        guard var counts = textReplanDiagnostics else { return }
        var extent = false, atlas = false, colorScale = false, combos = false
        var objectValue = false, glyphLayout = false
        for change in changes {
            extent = extent || change.previous.layout.fboSize != change.current.layout.fboSize
            atlas = atlas || change.previous.atlasKey != change.current.atlasKey
            colorScale = colorScale || change.previous.layout.mesh?.colorAtlasScale != change.current.layout.mesh?.colorAtlasScale
            combos = combos || change.previous.fieldParameters?.combos != change.current.fieldParameters?.combos
            objectValue = objectValue || change.previous.object != change.current.object
            glyphLayout = glyphLayout || change.previous.layout != change.current.layout
        }
        counts.changedTextObjects += changedObjectCount
        counts.frameRebuildCohorts += requiresRebuild ? 1 : 0
        counts.extentChangedCohorts += extent ? 1 : 0
        counts.atlasKeyChangedCohorts += atlas ? 1 : 0
        counts.colorScaleChangedCohorts += colorScale ? 1 : 0
        counts.fieldCombosChangedCohorts += combos ? 1 : 0
        counts.extentOnlyCohorts += !requiresRebuild && extent && !atlas && !colorScale && !combos ? 1 : 0
        counts.objectValueChangedCohorts += objectValue ? 1 : 0
        counts.glyphLayoutChangedCohorts += glyphLayout ? 1 : 0
        counts.frameLayoutReuseCohorts += keepsFrame ? 1 : 0
        counts.fullLayoutCohorts += keepsFrame ? 0 : 1
        textReplanDiagnostics = counts
    }

    /// Extent is not an input to a direct glyph operation or its graph resource descriptors. Only admit
    /// an already composed scene-destination pass; a transform-only group parent is not a composite owner.
    private func canReuseDirectTextExtents(_ changes: [WPEParityTextRelayoutDelta.Change], in current: Layout) -> Bool {
        guard instance.state.membershipGeneration == seenMembership, instance.state.modelDataGeneration == seenModelData,
              instance.state.visibilityGeneration == seenVisibility, instance.state.effectVisibilityGeneration == seenEffects,
              current.effects == instance.state.effectVisibility,
              changes.allSatisfy({
                  $0.previous.atlasKey == $0.current.atlasKey
                      && $0.previous.layout.mesh?.colorAtlasScale == $0.current.layout.mesh?.colorAtlasScale
                      && $0.previous.fieldParameters?.combos == $0.current.fieldParameters?.combos
              }) else { return false }
        let post = plan.postConfig(state: instance.state, mipMappedFrameBufferRequested: mipMappedFrameBufferRequested)
        guard post.bloomEnabled == current.post.bloomEnabled,
              post.sceneMipMappedFrameBufferEnabled == current.post.sceneMipMappedFrameBufferEnabled,
              !post.hdrEnabled || !post.bloomEnabled || post.hdrBloomLevelCount == current.post.hdrBloomLevelCount
        else { return false }
        let objects = Set(changes.compactMap { change in
            change.previous.layout.fboSize != change.current.layout.fboSize ? change.current.object.id : nil
        })
        guard !objects.isEmpty, objects.allSatisfy({ id in
            plan.scene.scene.objects.first(where: { $0.id == id })?.effects.isEmpty == true
        }) else { return false }
        let foreignResources = Set(objects.flatMap {
            [WPEParitySceneResource.layerImage($0), WPEParitySceneResource.layerCompositeA($0)]
        })
        for frame in current.frames {
            // A foreign material/dependency can force a text composite even when the text has no own effect.
            guard !frame.resources.contains(where: { foreignResources.contains($0.id) }) else { return false }
            var found: Set<String> = []
            for (index, operation) in frame.draws {
                guard case let .scene(draw) = operation, objects.contains(draw.objectID) else { continue }
                guard case .textGlyphs = draw.geometry,
                      draw.shader == "font", draw.effectID == nil, draw.compositeOwnerID == nil,
                      !draw.fillsComposite, draw.reads.isEmpty, current.draws[index] != nil,
                      draw.target == WPEParitySceneResource.backbuffer || draw.target == WPEParitySceneResource.multisampled
                else { return false }
                found.insert(draw.objectID)
            }
            guard found == objects else { return false }
        }
        return !current.frames.isEmpty
    }

    /// Prepare all text/atlas/geometry/RT values on this serial owner, then publish once after CPU accept.
    /// False defers the unchanged ordered request queue for asynchronous video admission; no text is accepted.
    func replanRelaidTexts() throws -> Bool {
        guard !textRequests.isEmpty else { return true }
        let attemptedCount = textRequests.count
        textReplanDiagnostics?.attemptedCohorts += 1
        textReplanDiagnostics?.attemptedRequests += attemptedCount
        failedTextRequestCount = 0
        var completed = false
        defer {
            if !completed {
                failedTextRequestCount = attemptedCount
                textReplanDiagnostics?.failedCohorts += 1
            }
        }
        let pipeline = textPipeline
        let requested = try WPEParityTextFieldAdmission.requests(textRequests, texts: pipeline.texts)
        guard let prepared = try pipeline.prepareRelayouts(requested) else {
            textReplanDiagnostics?.unchangedCohorts += 1
            consumeTextRequests(attemptedCount)
            completed = true
            return true
        }
        var accepted = false
        defer {
            if !accepted {
                try? pipeline.discard(prepared)
            }
        }
        let changed = Set(prepared.changedObjectIDs)
        var candidatePlanner = planner
        guard candidatePlanner.updateTexts(prepared.changedObjectIDs.compactMap { prepared.texts[$0] },
                                           atlases: prepared.atlases) else {
            throw WPEParityFrameRenderError.arenaUnavailable
        }
        var candidateLayers = layers
        for id in prepared.changedObjectIDs {
            guard let text = prepared.texts[id] else { continue }
            candidateLayers.setSize(id, size: SIMD2(Float(text.layout.fboSize.x), Float(text.layout.fboSize.y)))
        }
        let current = graphs.layout
        let requiresRebuild = prepared.delta.changes.contains { $0.requiresFrameRebuild }
        // Of a text's inputs, only these reach the composed frame and its bindings rather than just its own draws.
        let originalKeepsFrame = !requiresRebuild && prepared.delta.changes.allSatisfy { change in
            change.previous.layout.fboSize == change.current.layout.fboSize
                && change.previous.atlasKey == change.current.atlasKey
                && change.previous.layout.mesh?.colorAtlasScale == change.current.layout.mesh?.colorAtlasScale
                && change.previous.fieldParameters?.combos == change.current.fieldParameters?.combos
        }
        let directExtentReuse = !originalKeepsFrame && reusesDirectTextExtentLayouts && !requiresRebuild
            && canReuseDirectTextExtents(prepared.delta.changes, in: current)
        let keepsFrame = originalKeepsFrame || directExtentReuse
        if directExtentReuse {
            textReplanDiagnostics?.directExtentLayoutReuseCohorts += 1
        }
        if textReplanDiagnostics != nil {
            recordTextReplanReasons(prepared.delta.changes, changedObjectCount: prepared.changedObjectIDs.count,
                                    requiresRebuild: requiresRebuild, keepsFrame: keepsFrame)
        }
        var kept = current.draws
        for (index, description) in current.frames[0].draws {
            guard case let .scene(draw) = description, changed.contains(draw.objectID), kept[index] != nil else { continue }
            // makeLayout still checks the actual program/source, resources and frame compatibility before reuse.
            if case .textGlyphs = draw.geometry, let before = planner.texts[draw.objectID],
               let after = prepared.texts[draw.objectID], before.layout == after.layout, before.atlasKey == after.atlasKey {
                continue
            }
            kept[index] = nil
        }
        let planned: WPEParityFrameLayout
        var layout: Layout
        if keepsFrame {
            planned = current.planned
            layout = Self.replanDraws(of: changed, in: current, keeping: kept, artifacts: artifacts,
                                      planner: &candidatePlanner, encoder: drawEncoder, state: instance.state)
        } else {
            planned = try plan.layout(effects: instance.state, texts: prepared.texts,
                                      mipMappedFrameBufferRequested: mipMappedFrameBufferRequested)
            let reuse = Layout(planned: current.planned, effects: current.effects, draws: kept,
                               skipped: current.skipped, fade: current.fade)
            layout = try Self.makeLayout(planned, effects: instance.state.effectVisibility, artifacts: artifacts,
                                         planner: &candidatePlanner, encoder: drawEncoder,
                                         state: instance.state, reusing: reuse)
        }
        // makeLayout records per-draw failures as skips. Required readers of this changed text cohort cannot
        // be silently dropped while its CPU atlas/ref/layout is accepted.
        for (index, description) in planned.frames[0].draws {
            guard case let .scene(draw) = description, changed.contains(draw.objectID) else { continue }
            guard planned.programs[index] != nil, layout.draws[index] != nil else {
                throw layout.skipped[index] ?? WPEParityFrameSkip.noMaterial
            }
        }
        // A text layout must not publish a newly discovered video texture without its existing async decoder
        // admission. Discard this speculative token before staging a candidate made from committed texts.
        guard candidatePlanner.videos.count == planner.videos.count else {
            completed = true
            return false
        }
        // Every other draw already holds its object's unchanged parameters and a still-current atlas texture.
        let replacedAtlases = Set(planner.textAtlases.textures.compactMap { key, texture in
            candidatePlanner.textAtlases.textures[key] === texture ? nil : key
        })
        let affected = layout.draws.keys.filter { index in
            if case let .scene(draw)? = layout.frames[0].draws[index], changed.contains(draw.objectID) {
                return true
            }
            return !replacedAtlases.isEmpty && candidatePlanner.samplesTextAtlas(replacedAtlases, operation: index)
        }
        if !affected.isEmpty {
            var rebound = layout.draws
            for index in affected {
                candidatePlanner.refreshTextParameters(&rebound[index]!, operation: index)
                try candidatePlanner.refreshAtlasBindings(&rebound[index]!, operation: index)
            }
            layout = Layout(planned: layout.planned, effects: layout.effects, draws: rebound,
                            skipped: layout.skipped, fade: layout.fade)
        }
        let readinessChanged = Set(layout.draws.keys) != Set(current.draws.keys)
        if var counts = textReplanDiagnostics {
            let effectsChanged = layout.effects != current.effects
            counts.readinessChangedCohorts += readinessChanged ? 1 : 0
            counts.effectsChangedCohorts += effectsChanged ? 1 : 0
            if requiresRebuild || readinessChanged || effectsChanged {
                counts.graphPreparationAttempts += 1
            } else {
                counts.graphReusePreparations += 1
            }
            textReplanDiagnostics = counts
        }
        let gpu: PreparedGraphs = if requiresRebuild || readinessChanged || layout.effects != current.effects {
            try prepareGraphs(layout)
        } else {
            PreparedGraphs(graphs: Graphs(layout: layout, hidden: graphs.hidden, executors: graphs.executors,
                                          operations: graphs.operations, particleDraws: graphs.particleDraws,
                                          particleSnapshotSkips: graphs.particleSnapshotSkips),
                           targets: targets, samplers: targetSamplers, initialization: nil)
        }
        #if DEBUG
        try textPreparationCheckpoint?(textSnapshot(planner: candidatePlanner, layers: candidateLayers,
                                                    graphs: gpu.graphs, targets: gpu.targets,
                                                    pipelineAtlases: prepared.atlases,
                                                    initialization: gpu.initialization))
        #endif
        // Last throwing operation. No await, GPU allocation, graph encode or other admission follows accept.
        try pipeline.accept(prepared)
        accepted = true
        planner = candidatePlanner
        layers = candidateLayers
        layersMoved = true
        publishGraphs(gpu, cachePrevious: false)
        pipeline.atlases = candidatePlanner.textAtlases.atlases
        if keepsFrame {
            for index in layout.draws.keys where kept[index] == nil {
                packedConstants[index] = nil
            }
        } else {
            packedConstants.removeAll()
            fadeConstants.removeAll()
        }
        for id in prepared.changedObjectIDs {
            guard let text = prepared.texts[id] else { continue }
            instance.state.setScriptField("size", of: id, to: .vector(SIMD4(lowHalf: text.scriptSize, highHalf: .zero)),
                                 invalidating: .none)
        }
        consumeTextRequests(attemptedCount)
        completed = true
        textReplanDiagnostics?.acceptedCohorts += 1
        repackBloom()
        return true
    }

    /// A speculative text layout discovered a new video. Its token is already discarded; only committed
    /// text/atlas values may survive the async boundary. A non-video candidate must not be published here.
    func requestTextVideoAdmission() throws {
        var staged = false
        defer {
            if !staged {
                failedTextRequestCount = textRequests.count
                textReplanDiagnostics?.failedCohorts += 1
            }
        }
        var candidate = planner
        candidate.adoptModelDataTransforms(plan.modelDataTransforms(state: instance.state, existing: layers))
        let planned = try plan.layout(effects: instance.state, texts: candidate.texts,
                                      mipMappedFrameBufferRequested: mipMappedFrameBufferRequested)
        let layout = try Self.makeLayout(planned, effects: instance.state.effectVisibility, artifacts: artifacts,
                                         planner: &candidate, encoder: drawEncoder, state: instance.state, reusing: graphs.layout)
        guard candidate.videos.contains(where: { !videos.contains($0.texture) }) else {
            // Keep the original rejection if the committed-text layout cannot independently admit that stream.
            throw WPEParityFrameSkip.videoTexture("Text preparation requires an unprepared video stream")
        }
        let cachePrevious = instance.state.membershipGeneration == seenMembership && instance.state.modelDataGeneration == seenModelData
        // The guard above guarantees installVideoReadyLayout only stages its private request, never graphs.
        _ = try installVideoReadyLayout(layout, planner: candidate, cachePrevious: cachePrevious)
        staged = true
        textReplanDiagnostics?.videoDeferredCohorts += 1
    }
}
#endif
