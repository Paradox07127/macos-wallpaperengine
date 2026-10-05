#if !LITE_BUILD
import AppKit
import LiveWallpaperCore
import LiveWallpaperProWPE
import MetalKit
import os

extension WPEMetalSceneRenderer {
    // MARK: - Frame instrumentation

    static let frameSignposter = OSSignposter(
        subsystem: Bundle.main.bundleIdentifier ?? "com.loomscreen.pro",
        category: "WPEFrame"
    )

    @inline(__always)
    func withFrameSignpost<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let signposter = Self.frameSignposter
        let state = signposter.beginInterval(name, id: signposter.makeSignpostID())
        defer { signposter.endInterval(name, state) }
        return try body()
    }

    // MARK: - Frame rendering

    func makeFrameInputs() -> WPEFrameInputs {
        let pointer = mailbox.read()
        return WPEFrameInputs(
            clickCaptureEnabled: pointer.clickCaptureEnabled,
            pointerSample: pointerSampler.sample(),
            pointerFrame: pointer.pointerFrame,
            preferredFramesPerSecond: effectiveFPS,
            buttonCursor: pointer.buttonCursor,
            buttonsSuppressed: pointer.buttonsSuppressed
        )
    }

    func renderCurrentFrame(
        inputs: WPEFrameInputs,
        deferredPresent: WPEMetalRenderExecutor.DeferredPresentEncoder? = nil
    ) throws -> MTLTexture {
        latestFrameProduction = nil
        let signposter = Self.frameSignposter
        let frameState = signposter.beginInterval(
            "frame",
            id: signposter.makeSignpostID(),
            "scene:\(self.descriptor.workshopID, privacy: .public) renderer:\(self.rendererSignpostID, privacy: .public)"
        )
        // The defer runs on the throw paths too, so an aborted frame otherwise records a
        // complete — and shorter — "frame" interval, which reads as a speed-up in a trace.
        var frameRendered = false
        let previousCameraPathPlayback = cameraPathPlayback
        let previousCameraPlayback = cameraMotionPlayback
        let previousCameraUniforms = cameraUniforms
        defer {
            if !frameRendered {
                cameraPathPlayback = previousCameraPathPlayback
                cameraMotionPlayback = previousCameraPlayback
                cameraUniforms = previousCameraUniforms
            }
            signposter.endInterval("frame", frameState, "rendered:\(frameRendered, privacy: .public)")
        }

        guard let pipeline = renderPipeline else {
            throw WPEMetalRenderExecutorError.noRenderablePasses
        }
        let frameContext = withFrameSignpost("sampleContext") {
            sampleFrameContext(inputs: inputs)
        }
        let uniforms = frameContext.uniforms
        let scriptState = signposter.beginInterval("scriptTick", id: signposter.makeSignpostID())
        let scriptFailureBeforeFrame = sceneScriptLoadState.currentFailureReason
        let publicationBeforeFrame = captureSceneScriptFramePublication()
        beginSceneScriptVideoCommands()
        publishVideoPlaybackSnapshots()
        consumeSceneScriptLayerOutputs()
        pendingSceneScriptBatchJobs.removeAll(keepingCapacity: true)
        var didFinishSceneScriptVideoCommands = false
        defer {
            if !didFinishSceneScriptVideoCommands {
                discardSceneScriptVideoCommands()
            }
            submitSceneScriptFrameJobs()
            pendingSceneScriptBatchJobs.removeAll(keepingCapacity: true)
        }
        sceneScriptSharedState?.timelineAnimations.publishTime(uniforms.time)
        var frameOverlay = tickLayerPresentationScripts(
            uniforms: uniforms,
            layerScriptPointerFrame: frameContext.layerScriptPointerFrame
        )
        let timelineAlpha = sceneScriptSharedState?.timelineAnimations.alphaOverrides(at: uniforms.time) ?? [:]
        frameOverlay.alpha = timelineAlpha.merging(frameOverlay.alpha) { _, script in script }
        // Kept around past the pipeline application so render-graph text can
        // re-compose text anchors through the SAME live parent transforms.
        let authoredTransforms = authoredTransformAnimations(at: uniforms.time)
        let parentReadSnapshot = layerTransformMutationJournal.applying(
            to: LiveScriptTransforms.resolving(
                authored: authoredTransforms,
                script: lastStableScriptTransforms
            ),
            generation: loadGeneration
        )
        sceneScriptSharedState?.publishLayerTransforms(
            origins: parentReadSnapshot.origins,
            scales: parentReadSnapshot.scales,
            angles: parentReadSnapshot.angles
        )
        var liveScriptTransforms = lastStableScriptTransforms
        if let ticked = tickDynamicTransformScripts(
            pointer: frameContext.pointer,
            time: uniforms.time
        ) {
            if scriptFailureBeforeFrame == nil,
               sceneScriptLoadState.currentFailureReason == nil {
                liveScriptTransforms = ticked
            }
        }
        var liveTransforms = layerTransformMutationJournal.applying(
            to: LiveScriptTransforms.resolving(
                authored: authoredTransforms,
                script: liveScriptTransforms
            ),
            generation: loadGeneration
        )
        let sampledCameraMotion = cameraUniforms.sceneMotion
        applyScriptCameraMotion(liveScriptTransforms, sampled: sampledCameraMotion)
        frameOverlay.colors = layerColorsExcludingText(liveTransforms.colors)
        var framePipeline = pipeline.applyingFrameOverlay(frameOverlay)
        if !liveTransforms.isEmpty {
            framePipeline = framePipeline
                .applyingLayerTransforms(
                    origins: applyingTextLayerOriginOffsets(
                        liveTransforms.origins,
                        scales: liveTransforms.scales,
                        angles: liveTransforms.angles
                    ),
                    scales: liveTransforms.scales,
                    angles: liveTransforms.angles,
                    parentByID: objectParentByID,
                    hostTransforms: layerAncestorLocalTransformsByID
                )
        }
        // Aggregate the complete per-instance cursor burst before claiming a VM job.
        // Hover uses this frame's transformed geometry before every button edge.
        var cursorAttachmentGeometry: [String: WPERenderLayerGeometry] = [:]
        var cursorScriptObjectIDs: Set<String> = []
        forEachCursorScriptInstance { objectID, _ in cursorScriptObjectIDs.insert(objectID) }
        if Self.scriptedLayerFollowsAttachment(
            in: framePipeline,
            isScripted: cursorScriptObjectIDs.contains,
            objectParentByID: executor.parallaxObjectParentByID
        ) {
            let attachments: WPEMetalRenderExecutor.PuppetAttachmentFrameContext
            do {
                attachments = try executor.makeAttachmentFrameContext(
                    for: framePipeline, runtimeUniforms: uniforms, sceneSize: sceneRenderSize
                )
            } catch {
                signposter.endInterval("scriptTick", scriptState)
                throw error
            }
            for layer in framePipeline.layers {
                cursorAttachmentGeometry[layer.id] = executor.layerApplyingAttachmentFollow(
                    layer.graphLayer, context: attachments
                ).geometry
            }
        }
        var cursorBursts: [ObjectIdentifier: [WPELayerScriptCursorInvocation]] = [:]
        let deliver: CursorEventDelivery = { instance, events, frame in
            cursorBursts[ObjectIdentifier(instance), default: []].append(contentsOf: events.map {
                .init(event: $0, pointerFrame: frame, runtimeSeconds: uniforms.time)
            })
        }
        let buttonBatch = inputs.buttonCursor.map { mailbox.takeButtonEvents(through: $0) }
        if buttonBatch?.cancelled == true {
            layerPressStates.removeAll(keepingCapacity: true)
            previousLayerScriptPointerFrame = .neutral
            forEachCursorScriptInstance { _, instance in instance.cancelPendingCursorEvents() }
        }
        for edge in buttonBatch?.edges ?? [] {
            let space = Self.pointerSpace(
                present: presentUniforms(),
                sample: edge.isInsideView ? .inside(edge.frame.position) : .inactive,
                frame: edge.frame, followEnabled: mouseInteractionEnabled,
                clickEnabled: inputs.clickCaptureEnabled
            )
            dispatchLayerHoverEvents(
                pointer: space.clickPointerIsLive ? space.pointerFrame.position : nil,
                pipeline: framePipeline, pointerFrame: space.pointerFrame,
                attachmentGeometry: cursorAttachmentGeometry, deliver: deliver
            )
            dispatchPointerButtonEdges(
                from: previousLayerScriptPointerFrame, to: space.pointerFrame, deliver: deliver
            )
            previousLayerScriptPointerFrame = space.pointerFrame
        }
        var finalCursorFrame = frameContext.layerScriptPointerFrame
        if buttonBatch?.snapshotCurrent == false {
            finalCursorFrame.isDown = false
            finalCursorFrame.isRightDown = false
        }
        dispatchLayerHoverEvents(
            pointer: frameContext.clickPointerIsLive ? finalCursorFrame.position
                : (frameContext.followPointerIsLive ? frameContext.pointer : nil),
            pipeline: framePipeline, pointerFrame: finalCursorFrame,
            attachmentGeometry: cursorAttachmentGeometry, deliver: deliver
        )
        // Explicit oracle/manual inputs keep their existing snapshot-only behavior.
        // Mailbox edges own button delivery when a snapshot cursor is present.
        if buttonBatch == nil {
            dispatchPointerButtonEdges(
                from: previousLayerScriptPointerFrame, to: frameContext.layerScriptPointerFrame, deliver: deliver
            )
            previousLayerScriptPointerFrame = frameContext.layerScriptPointerFrame
        }
        forEachCursorScriptInstance { _, instance in
            let canSubmit = !hasPendingAuthoredLayerBatch || pendingOrderedLayerScriptBatch?.hasCompleteAdmission == true
            if let job = instance.enqueueCursorEvents(cursorBursts[ObjectIdentifier(instance)] ?? [], allowSubmission: canSubmit) {
                pendingSceneScriptBatchJobs.append(job)
            }
        }
        // Before the text tick: a `mediaPropertiesChanged` that landed since the
        // last frame should reach `update()` on THIS frame, not the next one.
        drainMediaEvents(runtimeSeconds: uniforms.time)
        tickParticleRateScripts(pointer: frameContext.pointer, time: uniforms.time)
        tickEffectConstantScripts(pointer: frameContext.pointer, time: uniforms.time)
        tickEffectVisibilityScripts(pointer: frameContext.pointer, time: uniforms.time)
        drainScriptSoundCommands()
        let tickedTextByID = tickTextContentScripts(runtimeSeconds: uniforms.time)
        let liveTextByID: [String: String]
        if scriptFailureBeforeFrame == nil,
           let failure = sceneScriptLoadState.currentFailureReason {
            invalidateIntroPhaseAlign()
            restoreSceneScriptPresentation(publicationBeforeFrame.presentation)
            layerTransformMutationJournal = publicationBeforeFrame.transformMutationJournal
            liveScriptTransforms = lastStableScriptTransforms
            applyScriptCameraMotion(liveScriptTransforms, sampled: sampledCameraMotion)
            liveTransforms = layerTransformMutationJournal.applying(
                to: .resolving(
                    authored: authoredTransforms,
                    script: liveScriptTransforms
                ),
                generation: loadGeneration
            )
            liveTextByID = lastStableScriptTextByID
            framePipeline = applyingSceneScriptPresentation(
                to: pipeline,
                transforms: liveTransforms
            )
            Logger.warning(
                "Scene \(descriptor.workshopID) froze its last stable SceneScript presentation: \(failure)",
                category: .wpeRender
            )
        } else if sceneScriptLoadState.currentFailureReason == nil {
            lastStableScriptTransforms = liveScriptTransforms
            lastStableScriptTextByID = tickedTextByID
            liveTextByID = tickedTextByID
            framePipeline = framePipeline.applyingScriptLayerPresentation(frameLayerPresentation)
            if !liveCreatedLayers.isEmpty {
                framePipeline = framePipeline.addingCreatedLayers(
                    liveCreatedLayers,
                    templatesByImagePath: createdLayerTemplatesByImagePath
                )
            }
        } else {
            liveScriptTransforms = lastStableScriptTransforms
            liveTransforms = layerTransformMutationJournal.applying(
                to: .resolving(
                    authored: authoredTransforms,
                    script: liveScriptTransforms
                ),
                generation: loadGeneration
            )
            liveTextByID = lastStableScriptTextByID
            framePipeline = applyingSceneScriptPresentation(
                to: pipeline,
                transforms: liveTransforms
            )
        }
        lastFramePipeline = framePipeline
        signposter.endInterval("scriptTick", scriptState)
        withFrameSignpost("videoReconcile") {
            reconcileVideoResidency(framePipeline)
        }
        let frameSubmission = try executor.beginFrameSubmission()
        defer { frameSubmission.seal() }
        try withFrameSignpost("particleTick") {
            try tickParticleSystems(
                time: uniforms.time,
                followPointerIsLive: frameContext.followPointerIsLive,
                pointer: frameContext.pointer,
                liveTransforms: liveTransforms,
                frameSlot: frameSubmission.slot,
                presentationBeforeScripts: publicationBeforeFrame.presentation,
                audioSpectrum16: particleSystems.contains(where: \.isAudioResponsive)
                    ? uniforms.audioSpectrum16Average
                    : nil
            )
        }
        // Fail-close must decide commit BEFORE present is encoded: a denial
        // rolls back and the stable re-encode carries present instead.
        var videoCommandsOutcome: Bool?
        let guardedPresent: WPEMetalRenderExecutor.DeferredPresentEncoder?
        if let deferredPresent {
            let failureBeforeFrame = scriptFailureBeforeFrame
            guardedPresent = { [self] texture, commandBuffer in
                if failureBeforeFrame == nil {
                    let granted = finishCurrentSceneScriptVideoCommands()
                    videoCommandsOutcome = granted
                    guard granted else { return false }
                }
                return try deferredPresent(texture, commandBuffer)
            }
        } else {
            guardedPresent = nil
        }
        let frame = try encodeSceneFrame(
            pipeline: framePipeline,
            uniforms: uniforms,
            liveTextByID: liveTextByID,
            transforms: liveTransforms,
            parallaxFrame: frameContext.parallaxFrame,
            frameSubmission: frameSubmission,
            deferredPresent: guardedPresent
        )
        didFinishSceneScriptVideoCommands = true
        let rendered = try finishSceneScriptFrame(
            speculativeFrame: frame,
            failureBeforeFrame: scriptFailureBeforeFrame,
            publicationBeforeFrame: publicationBeforeFrame,
            basePipeline: pipeline,
            uniforms: uniforms,
            authoredTransforms: authoredTransforms,
            sampledCameraMotion: sampledCameraMotion,
            parallaxFrame: frameContext.parallaxFrame,
            frameSubmission: frameSubmission,
            videoCommandsOutcome: videoCommandsOutcome,
            deferredPresent: deferredPresent
        )
        frameRendered = true
        if cameraMotionPlayback != nil || cameraPathPlayback != nil {
            synchronizeFrameDemand(); publishRuntimeActivity()
        }
        return rendered
    }

    static func scriptedLayerFollowsAttachment(
        in pipeline: WPEPreparedRenderPipeline,
        isScripted: (String) -> Bool,
        objectParentByID: [String: String]
    ) -> Bool {
        guard pipeline.layers.contains(where: { $0.graphLayer.attachment != nil }) else { return false }
        let layersByObjectID = Dictionary(
            pipeline.layers.map { ($0.graphLayer.objectID, $0.graphLayer) },
            uniquingKeysWith: { first, _ in first }
        )
        // Same parent walk as `layerApplyingAttachmentFollow`: an attachment anywhere up the chain moves the layer.
        return pipeline.layers.contains { layer in
            guard isScripted(layer.id) else { return false }
            var currentID: String? = layer.graphLayer.objectID
            var seen: Set<String> = []
            while let id = currentID, seen.insert(id).inserted, seen.count <= 100 {
                let node = id == layer.graphLayer.objectID ? layer.graphLayer : layersByObjectID[id]
                if node?.attachment != nil {
                    return true
                }
                currentID = node?.parentObjectID ?? objectParentByID[id]
            }
            return false
        }
    }

    /// `sampled` is this frame's keyframed camera motion; a channel no script drives keeps it.
    func applyScriptCameraMotion(_ scriptTransforms: LiveScriptTransforms, sampled: WPESceneCameraMotionSample) {
        guard let definition = cameraMotionPlayback?.definition else { return }
        cameraUniforms = baseCameraUniforms.applyingSceneMotion(.init(
            origin: scriptTransforms.origins[definition.objectID] ?? sampled.origin,
            zoom: scriptTransforms.scales[WPECameraMotionPlayback.zoomScriptKey]?.x ?? sampled.zoom,
            angles: scriptTransforms.angles[definition.objectID] ?? sampled.angles
        ))
        sceneScriptSharedState?.setCursorWorldProjection(nil, sceneMotion: cameraUniforms.sceneMotion)
    }

    func encodeSceneFrame(
        pipeline: WPEPreparedRenderPipeline,
        uniforms: WPEMetalRuntimeUniforms,
        liveTextByID: [String: String],
        transforms: LiveScriptTransforms,
        parallaxFrame: WPECameraParallaxFrame,
        frameSubmission: WPEMetalFrameSubmissionLease,
        deferredPresent: WPEMetalRenderExecutor.DeferredPresentEncoder? = nil
    ) throws -> MTLTexture {
        let readinessPlan = WPEFrameReadinessTrackingPlan.make(
            generation: loadGeneration,
            completedGeneration: completedPresentGeneration,
            hasReadinessConsumer: displayActor != nil
        )
        let frameProduction = (readinessPlan.tracksReadiness || spanFrames != nil)
            ? WPEMetalFrameProductionCompletion()
            : nil
        defer { frameProduction?.seal() }
        // Published before `executor.render`: merged present reads this mid-render.
        latestFrameProduction = frameProduction
        let textFrame = withFrameSignpost("textLayout") {
            prepareTextFrame(
                pipeline: pipeline,
                liveTextByID: liveTextByID,
                transforms: transforms,
                parallaxFrame: parallaxFrame
            )
        }
        if !textFrame.obsoleteTargetNames.isEmpty {
            executor.targetPool.discardTextures(named: textFrame.obsoleteTargetNames)
        }
        refreshParallaxRootOrigins(from: transforms)
        let lighting = WPESceneDirectionalLightingSnapshot.make(
            lights: sceneLightObjects, localTransforms: lightingLocalTransformsByID,
            parentByID: objectParentByID, ownVisibilityByID: ownVisibilityByID,
            origins: transforms.origins, scales: transforms.scales, angles: transforms.angles,
            colors: transforms.colors,
            visibility: liveLayerVisibility.merging(liveTextVisibility) { _, text in text }
        )
        lastFrameDirectionalLighting = lighting
        let frame = try withFrameSignpost("encode") { () throws -> MTLTexture in
            let currentTextures = try texturesForCurrentFrame(
                time: uniforms.time,
                pipeline: textFrame.pipeline,
                frameSlot: frameSubmission.slot
            )
            return try executor.render(
                pipeline: textFrame.pipeline.resolvingSceneModelMatrices(
                    origins: transforms.origins, scales: transforms.scales, angles: transforms.angles,
                    parentByID: objectParentByID, hostTransforms: layerAncestorLocalTransformsByID, camera: cameraUniforms
                ),
                size: sceneRenderSize,
                textures: currentTextures,
                textureSamplingDescriptors: loadedTextureSamplingDescriptors,
                dynamicTextureNames: dynamicTextureNames,
                dynamicLayerIDs: staticCacheExcludedLayerIDs,
                runtimeUniforms: uniforms,
                cameraUniforms: cameraUniforms,
                directionalLighting: lighting,
                scriptedConstants: liveEffectConstants,
                passVisibility: liveEffectVisibility,
                sceneID: descriptor.workshopID,
                particleSystems: particleSystems.filter(particleSystemVisible),
                particleTextures: particleTextures,
                particleNormalTextures: particleNormalTextures,
                particleParallax: parallaxFrame,
                textPayloads: textFrame.payloads,
                frameSubmission: frameSubmission,
                frameProduction: frameProduction,
                // `presetSnapshot`, not the layered map: the layered map also carries `propertyOverrides`, so an author's slider named `volume` would drive an engine setting.
                colorCorrection: WPEEngineColorCorrection.parse(
                    descriptor.presetSnapshot
                ) ?? .neutral,
                deferredPresent: deferredPresent
            )
        }
        return frame
    }

    func recordSceneFrameForDebug(time: Double, composite: MTLTexture) {
        #if DEBUG
        maybeDumpScenePassesOverTime(time: time, composite: composite)
        #endif
    }

    // MARK: - Per-frame script & particle ticks

    private func tickLayerPresentationScripts(
        uniforms: WPEMetalRuntimeUniforms,
        layerScriptPointerFrame: WPEPointerFrame
    ) -> WPEFrameOverlay {
        guard !layerScriptInstances.isEmpty || !layerAlphaScriptInstances.isEmpty
            || !textVisibleScriptInstances.isEmpty || !textAlphaScriptInstances.isEmpty
            || !particleAlphaScriptInstances.isEmpty || !textScriptInstances.isEmpty else {
            // Transform/effect scripts' layer writes land in the live maps via consumeSceneScriptLayerOutputs.
            let hasLayerWritingScripts = !dynamicOriginScriptInstances.isEmpty || !dynamicScaleScriptInstances.isEmpty
                || !dynamicAnglesScriptInstances.isEmpty || !dynamicColorScriptInstances.isEmpty
                || !effectConstantScriptInstances.isEmpty || !effectVisibilityScriptInstances.isEmpty
                || !particleRateScriptInstances.isEmpty || !dynamicParallaxDepthScriptInstances.isEmpty
            return hasLayerWritingScripts ? livePresentationOverlay : WPEFrameOverlay()
        }
        // Sorted by objectID: these scripts cross-talk through shared state, so a
        // stable tick order keeps the frame deterministic (oracle) and behaviour
        // reproducible (dictionary order was arbitrary).
        if sceneScriptSharedState?.isAuthoredLayerOrderingEnabled == true {
            tickOrderedLayerScripts(time: uniforms.time, pointerFrame: layerScriptPointerFrame)
        } else {
            for (objectID, instance) in layerScriptInstances.sorted(by: { $0.key < $1.key }) {
                if let output = tickLayerScript(
                    instance,
                    runtimeSeconds: uniforms.time,
                    pointerFrame: layerScriptPointerFrame
                ) {
                    applyLayerScriptOutput(output, ownObjectID: objectID)
                }
            }
        }
        for (objectID, instance) in layerAlphaScriptInstances.sorted(by: { $0.key < $1.key }) {
            if let output = tickLayerScript(
                instance,
                runtimeSeconds: uniforms.time,
                pointerFrame: layerScriptPointerFrame
            ) {
                applyLayerAlphaScriptOutput(output, ownObjectID: objectID)
            }
        }
        for (objectID, instance) in textVisibleScriptInstances.sorted(by: { $0.key < $1.key }) {
            if let output = tickLayerScript(
                instance,
                runtimeSeconds: uniforms.time,
                pointerFrame: layerScriptPointerFrame
            ) {
                applyTextScriptOutput(output, ownObjectID: objectID)
            }
        }
        for (objectID, instance) in textAlphaScriptInstances.sorted(by: { $0.key < $1.key }) {
            if let output = tickLayerScript(
                instance,
                runtimeSeconds: uniforms.time,
                pointerFrame: layerScriptPointerFrame
            ) {
                applyTextAlphaScriptOutput(output, ownObjectID: objectID)
            }
        }
        for (objectID, instance) in particleAlphaScriptInstances.sorted(by: { $0.key < $1.key }) {
            if let output = tickLayerScript(
                instance,
                runtimeSeconds: uniforms.time,
                pointerFrame: layerScriptPointerFrame
            ) {
                applyParticleAlphaScriptOutput(output, ownObjectID: objectID)
            }
        }
        stageIntroPhaseAlign()
        // Capture now: transform/event scripts run later and may mutate live
        // presentation. The frame keeps the same snapshot as the old early
        // visibility/alpha application, while the tree is rebuilt only once.
        return livePresentationOverlay
    }

    private var livePresentationOverlay: WPEFrameOverlay {
        WPEFrameOverlay(visibility: liveLayerVisibilityIncludingText, alpha: liveLayerAlphaIncludingText)
    }

    /// WPE evaluates the parallax static term at the root's CURRENT position. Only parentless ids are overlaid:
    /// a parented id's live origin is parent-local, while the authored table is scene space.
    func refreshParallaxRootOrigins(from transforms: LiveScriptTransforms) {
        var origins = parallaxAuthoredOriginByObjectID
        for (id, origin) in transforms.origins where objectParentByID[id] == nil {
            origins[id] = SIMD2<Double>(origin.x, origin.y)
        }
        executor.parallaxHostOriginByObjectID = origins
        let halfScene = SIMD2<Double>(Double(sceneRenderSize.width), Double(sceneRenderSize.height)) * 0.5
        for system in particleSystems {
            // A parent without a depth entry leaves the emitter as its own root; that center is not refreshed here.
            guard let parent = system.hostAncestorIDs.first,
                  parallaxAuthoredDepthByObjectID[parent] != nil,
                  let rootOrigin = origins[parallaxRootObjectID(of: parent)] else { continue }
            system.parallaxCenter = rootOrigin - halfScene
        }
    }

    struct LiveScriptTransforms {
        var origins: [String: SIMD3<Double>] = [:]
        var scales: [String: SIMD3<Double>] = [:]
        var angles: [String: SIMD3<Double>] = [:]
        /// Script-driven layer tint (linear RGB 0…1). Rides this struct rather
        /// than a map of its own so fail-close freezes it with the transforms.
        var colors: [String: SIMD3<Double>] = [:]
    }

    /// Ticks the dynamic origin/scale/angles scripts; nil when the scene has none
    /// (the pipeline keeps its parse-time transforms).
    private func tickDynamicTransformScripts(
        pointer: SIMD2<Double>,
        time: Double
    ) -> LiveScriptTransforms? {
        guard !dynamicOriginScriptInstances.isEmpty
            || !dynamicScaleScriptInstances.isEmpty
            || !dynamicAnglesScriptInstances.isEmpty
            || !dynamicColorScriptInstances.isEmpty
            || !dynamicParallaxDepthScriptInstances.isEmpty
            || !sharedOriginReadFans.isEmpty
            || !sharedScaleReadFans.isEmpty
            || !sharedAnglesReadFans.isEmpty
            || !sharedColorReadFans.isEmpty
            || !sharedParallaxReadFans.isEmpty else { return nil }
        var transforms = LiveScriptTransforms()
        transforms.origins.reserveCapacity(dynamicOriginScriptInstances.count + sharedOriginReadFans.count)
        for (objectID, instance) in dynamicOriginScriptInstances.sorted(by: { $0.key < $1.key }) {
            if let origin = tickTransformScript(
                instance,
                pointer: pointer,
                runtimeSeconds: time
            ) {
                transforms.origins[objectID] = origin
            }
        }
        applySharedReadFans(sharedOriginReadFans, into: &transforms.origins)
        transforms.scales.reserveCapacity(dynamicScaleScriptInstances.count + sharedScaleReadFans.count)
        for (objectID, instance) in dynamicScaleScriptInstances.sorted(by: { $0.key < $1.key }) {
            if let scale = tickTransformScript(
                instance,
                pointer: pointer,
                runtimeSeconds: time
            ) {
                transforms.scales[objectID] = scale
            }
        }
        applySharedReadFans(sharedScaleReadFans, into: &transforms.scales)
        transforms.angles.reserveCapacity(dynamicAnglesScriptInstances.count + sharedAnglesReadFans.count)
        for (objectID, instance) in dynamicAnglesScriptInstances.sorted(by: { $0.key < $1.key }) {
            if let angle = tickTransformScript(
                instance,
                pointer: pointer,
                runtimeSeconds: time
            ) {
                // WPE's script API exposes `angles` in degrees; scene.json and the rotation math are radians. Convert only at this boundary — the instance's lastValue stays in script-space degrees.
                transforms.angles[objectID] = angle * (.pi / 180)
            }
        }
        applySharedReadFans(sharedAnglesReadFans, into: &transforms.angles)
        for objectID in sharedAnglesReadFans.keys {
            if let angle = transforms.angles[objectID] {
                transforms.angles[objectID] = angle * (.pi / 180)
            }
        }
        transforms.colors.reserveCapacity(dynamicColorScriptInstances.count + sharedColorReadFans.count)
        for (objectID, instance) in dynamicColorScriptInstances.sorted(by: { $0.key < $1.key }) {
            if let color = tickTransformScript(
                instance,
                pointer: pointer,
                runtimeSeconds: time
            ) {
                transforms.colors[objectID] = color
            }
        }
        applySharedReadFans(sharedColorReadFans, into: &transforms.colors)
        for (objectID, instance) in dynamicParallaxDepthScriptInstances.sorted(by: { $0.key < $1.key }) {
            if let ticked = tickTransformScript(
                instance,
                pointer: pointer,
                runtimeSeconds: time
            ) {
                applyScriptParallaxDepth(SIMD2<Double>(ticked.x, ticked.y), objectID: objectID)
            }
        }
        if let shared = sceneScriptSharedState {
            for (objectID, key) in sharedParallaxReadFans {
                if let value = WPESharedReadFanAnalysis.vec3(from: shared.get(key)) {
                    applyScriptParallaxDepth(SIMD2<Double>(value.x, value.y), objectID: objectID)
                }
            }
        }
        if !dynamicParallaxDepthScriptInstances.isEmpty || !sharedParallaxReadFans.isEmpty {
            applyEffectiveParallaxDepths()
        }
        return transforms
    }

    /// Writes only the live depth tables; render depth is resolved per anchor in `applyEffectiveParallaxDepths`.
    private func applyScriptParallaxDepth(_ depth: SIMD2<Double>, objectID: String) {
        guard depth.x.isFinite, depth.y.isFinite else { return }
        parallaxAuthoredDepthByObjectID[objectID] = depth
        executor.parallaxHostDepthByObjectID[objectID] = depth
    }

    /// A subtree moves by its anchor's depth alone, so a parented object's own scripted depth never renders.
    private func applyEffectiveParallaxDepths() {
        let effective = WPERenderGraphBuilder.effectiveParallaxDepths(
            live: parallaxAuthoredDepthByObjectID,
            parentByID: objectParentByID,
            drivenBy: Set(dynamicParallaxDepthScriptInstances.keys).union(sharedParallaxReadFans.keys)
        )
        for (objectID, depth) in effective {
            liveLayerPresentation[objectID, default: .init()].parallaxDepth = depth
        }
        for system in particleSystems {
            if let objectID = system.scriptParticleObjectID, let depth = effective[objectID] {
                system.parallaxDepth = depth
            }
        }
    }

    /// Swift fan-out for `return shared.K` scripts that never entered JS.
    func applySharedReadFans(
        _ fans: [String: String],
        into map: inout [String: SIMD3<Double>]
    ) {
        guard !fans.isEmpty, let shared = sceneScriptSharedState else { return }
        for (objectID, key) in fans {
            if let value = WPESharedReadFanAnalysis.vec3(from: shared.get(key)) {
                map[objectID] = value
            }
        }
    }

    /// Particles tick (CPU sim) BEFORE the layer composite so the executor can
    /// interleave their draws at each system's scene paint index.
    private func tickParticleSystems(
        time: Double,
        followPointerIsLive: Bool,
        pointer: SIMD2<Double>,
        liveTransforms: LiveScriptTransforms,
        frameSlot: Int,
        presentationBeforeScripts: WPESceneScriptPresentationSnapshot,
        audioSpectrum16: [Float]? = nil
    ) throws {
        guard !particleSystems.isEmpty else { return }
        // Cursor in the centered render frame (Y-up), or nil when Follow Cursor is off/outside. Center-relative so it matches `WPEParticleSceneTransform`'s coordinate space.
        let particlePointer: SIMD2<Float>? = followPointerIsLive
            ? SIMD2<Float>(
                Float((pointer.x - 0.5) * sceneRenderSize.width),
                Float((0.5 - pointer.y) * sceneRenderSize.height)
            )
            : nil
        updateParticleHostOriginOffsets(using: liveTransforms)
        let gpuPerspectiveUnavailable = cameraUniforms.particlePerspectiveViewProjectionMatrix == nil
        withFrameSignpost("particleIndependent") {
            for system in particleIndependentSystems where particleSystemVisible(system) {
                // Shown by this frame's scripts: emission starts now, with no history from the hidden span.
                if let objectID = system.scriptParticleObjectID,
                   !Self.particleObjectVisible(
                       objectID,
                       parentByID: objectParentByID,
                       layerVisibility: presentationBeforeScripts.layerVisibility,
                       textVisibility: presentationBeforeScripts.textVisibility,
                       ownVisibilityByID: ownVisibilityByID
                   ) {
                    system.anchorInstanceClock(at: time)
                }
                system.pointerCentered = particlePointer
                system.cpuPerspectiveFallback = gpuPerspectiveUnavailable
                if let objectID = system.instanceAlphaScriptObjectID,
                   let alpha = liveParticleInstanceAlpha[objectID] {
                    system.instanceAlphaScale = Float(max(0, min(1, alpha)))
                }
                if system.isAudioResponsive { system.audioSpectrum16 = audioSpectrum16 }
                system.advanceSimulation(now: time)
                if !Self.particleFrameArenaEnabled, system.definition.rendersSprite {
                    system.prepareRenderData(frameSlot: frameSlot)
                }
            }
        }
        if let coordinator = particleInstanceCoordinator {
            let gpuPerspectiveUnavailable = cameraUniforms.particlePerspectiveViewProjectionMatrix == nil
            withFrameSignpost("particleEvents") {
                coordinator.tick(now: time, frameSlot: frameSlot, shouldPrepareRenderData: { system in
                    !Self.particleFrameArenaEnabled && system.definition.rendersSprite && particleSystemVisible(system)
                }, configure: { system in
                    updateParticleHostOriginOffset(system, using: liveTransforms)
                    system.pointerCentered = system.pointerInSimulationFrame(particlePointer)
                    system.cpuPerspectiveFallback = gpuPerspectiveUnavailable
                    if let objectID = system.instanceAlphaScriptObjectID,
                       let alpha = liveParticleInstanceAlpha[objectID] {
                        system.instanceAlphaScale = Float(max(0, min(1, alpha)))
                    }
                    if system.isAudioResponsive {
                        system.audioSpectrum16 = audioSpectrum16
                    }
                })
            }
            withFrameSignpost("particleBindings") {
                synchronizeParticleInstanceBindings()
            }
        }
        if Self.particleFrameArenaEnabled {
            try withFrameSignpost("particlePrepare") {
                try prepareParticleFrameOutput(frameSlot: frameSlot)
            }
        }
        withFrameSignpost("particlePublish") {
            publishParticlePlaybackSnapshots()
        }
        if Self.frameSignposter.isEnabled {
            let coordinator = particleInstanceCoordinator
            let independent = particleIndependentSystems.count
            let independentAlive = particleIndependentSystems.reduce(0) { $0 + $1.liveParticleCount }
            let eventInstances = coordinator?.eventInstanceCount ?? 0
            let eventSlots = coordinator?.eventParticleSlots ?? 0
            let eventAlive = coordinator?.liveParticleCount ?? 0
            let created = coordinator?.createdEventInstances ?? 0
            let released = coordinator?.releasedEventInstances ?? 0
            let rejected = coordinator?.rejectedEventInstances ?? 0
            Self.frameSignposter.emitEvent(
                "particleCounts", id: Self.frameSignposter.makeSignpostID(),
                "independent:\(independent, privacy: .public) independentAlive:\(independentAlive, privacy: .public) eventInstances:\(eventInstances, privacy: .public) eventSlots:\(eventSlots, privacy: .public) eventAlive:\(eventAlive, privacy: .public) created:\(created, privacy: .public) released:\(released, privacy: .public) rejected:\(rejected, privacy: .public)"
            )
        }
    }

    /// A constant keeps its last good value when its script returns nothing, matching how the transform families hold their last value.
    private func tickEffectConstantScripts(pointer: SIMD2<Double>, time: Double) {
        guard !effectConstantScriptInstances.isEmpty
            || !sharedEffectConstantReadFans.isEmpty else { return }
        for (key, instance) in effectConstantScriptInstances.sorted(
            by: { ($0.key.passID, $0.key.uniform) < ($1.key.passID, $1.key.uniform) }
        ) {
            guard let value = tickTransformScript(
                instance,
                pointer: pointer,
                runtimeSeconds: time
            ) else { continue }
            liveEffectConstants[key.passID, default: [:]][key.uniform] = instance.constantValue(value)
        }
        for (key, fan) in sharedEffectConstantReadFans {
            guard let raw = sceneScriptSharedState?.get(fan.sharedKey),
                  let value = WPESharedReadFanAnalysis.vec3(from: raw) else { continue }
            let constant: WPESceneShaderConstantValue
            switch fan.valueShape {
            case .scalar, .boolean: constant = .number(value.x)
            case .vector2: constant = .vector([value.x, value.y])
            case .vector3: constant = .vector([value.x, value.y, value.z])
            }
            liveEffectConstants[key.passID, default: [:]][key.uniform] = constant
        }
    }

    /// Runs AFTER the constant scripts because the value a gate reads is produced by a constant script on the same effect, so same-frame ordering removes a frame of lag. A gate keeps its last value when its script returns nothing.
    private func tickEffectVisibilityScripts(pointer: SIMD2<Double>, time: Double) {
        guard !effectVisibilityScriptInstances.isEmpty else { return }
        for (id, instance) in effectVisibilityScriptInstances.sorted(by: { $0.key < $1.key }) {
            guard let value = tickTransformScript(
                instance,
                pointer: pointer,
                runtimeSeconds: time
            ) else { continue }
            liveEffectVisibility[id] = value.x > 0.5
        }
    }

    private func drainScriptSoundCommands() {
        guard let sharedState = sceneScriptSharedState, let soundRuntime else { return }
        for entry in sharedState.drainSoundCommands() {
            soundRuntime.applyScriptCommand(entry.command, layer: entry.layer)
        }
    }

    /// Ticks ALL text scripts, including hidden objects — a hidden one may populate
    /// the shared state a visible object consumes.
    private func tickTextContentScripts(runtimeSeconds: Double) -> [String: String] {
        var liveTextByID: [String: String] = [:]
        liveTextByID.reserveCapacity(textScriptInstances.count)
        for (id, instance) in textScriptInstances.sorted(by: { $0.key < $1.key }) {
            liveTextByID[id] = tickTextScript(instance, runtimeSeconds: runtimeSeconds)
            if let output = instance.takeLayerOutput() {
                applyLayerScriptOutput(output, ownObjectID: id)
            }
        }
        return liveScriptAssignedText.merging(liveTextByID) { _, ownScriptText in ownScriptText }
    }
}
#endif
