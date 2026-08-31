#if !LITE_BUILD
import AppKit
import LiveWallpaperCore
import LiveWallpaperProWPE
import MetalKit
import os

extension WPEMetalSceneRenderer {
    // MARK: - Frame instrumentation

    /// Phase-level os_signpost intervals for the per-frame render. Always on;
    /// with no Instruments observer the emit cost is negligible. Read the stages
    /// with the os_signpost template to measure off-main rendering.
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

    /// Snapshots the pointer inputs `renderCurrentFrame` needs from the mailbox
    /// (fed by the surface's publisher + view). The frame-rate field is the
    /// renderer's own `effectiveFPS` — the diagnostic reader (audio log) only, and
    /// exactly the value the surface applies to the view. See `WPEFrameInputs`.
    func makeFrameInputs() -> WPEFrameInputs {
        let pointer = mailbox.read()
        return WPEFrameInputs(
            clickCaptureEnabled: pointer.clickCaptureEnabled,
            pointerSample: pointerSampler.sample(),
            pointerFrame: pointer.pointerFrame,
            preferredFramesPerSecond: effectiveFPS
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
        defer { signposter.endInterval("frame", frameState) }

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
        pendingSceneScriptBatchJobs.removeAll(keepingCapacity: true)
        var didFinishSceneScriptVideoCommands = false
        defer {
            if !didFinishSceneScriptVideoCommands {
                discardSceneScriptVideoCommands()
            }
            // One hand-off for the whole frame: every family has ticked by now, so
            // each worker gets exactly one dispatch no matter how many scripts the
            // scene has.
            sceneScriptBatchDispatcher.submit(pendingSceneScriptBatchJobs)
            pendingSceneScriptBatchJobs.removeAll(keepingCapacity: true)
        }
        var framePipeline = applyingLayerScriptTicks(
            to: pipeline,
            uniforms: uniforms,
            layerScriptPointerFrame: frameContext.layerScriptPointerFrame
        )
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
        if !liveTransforms.isEmpty {
            framePipeline = framePipeline
                .applyingLayerColor(layerColorsExcludingText(liveTransforms.colors))
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
        // Hover hit-testing AFTER live transforms: the pads follow the moving
        // bodies (per-star cursorEnter → shared.cretN → label fade-in), so the
        // rects must come from this frame's transformed geometry.
        dispatchLayerHoverEvents(
            pointer: frameContext.followPointerIsLive ? frameContext.pointer : nil,
            pipeline: framePipeline,
            pointerFrame: frameContext.layerScriptPointerFrame,
            runtimeSeconds: uniforms.time
        )
        // AFTER the hover pass, not before it: a press is attributed to whatever
        // `layerHoverStates` says is under the cursor, so dispatching it from
        // inside the tick helper — which runs near the top of the frame — matched
        // presses against the previous frame's hover set. Moving onto a layer and
        // clicking within one frame then produced no `cursorClick`, or one on the
        // layer the cursor had just left. Hover cannot move earlier instead: its
        // hit rects have to come from this frame's live transforms.
        dispatchPointerButtonEdges(
            from: previousLayerScriptPointerFrame,
            to: frameContext.layerScriptPointerFrame,
            runtimeSeconds: uniforms.time
        )
        previousLayerScriptPointerFrame = frameContext.layerScriptPointerFrame
        // Before the text tick: a `mediaPropertiesChanged` that landed since the
        // last frame should reach `update()` on THIS frame, not the next one.
        drainMediaEvents(runtimeSeconds: uniforms.time)
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
        // Keep only currently-visible on-demand videos resident (releases hidden
        // ones, rebuilds revealed ones). No-op unless the scene has releasable
        // videos; reads the final per-frame visibility so it covers script-,
        // user-property- and condition-driven switches alike.
        withFrameSignpost("videoReconcile") {
            reconcileVideoResidency(framePipeline)
        }
        let frameSubmission = try executor.beginFrameSubmission()
        defer { frameSubmission.seal() }
        withFrameSignpost("particleTick") {
            tickParticleSystems(
                time: uniforms.time,
                followPointerIsLive: frameContext.followPointerIsLive,
                pointer: frameContext.pointer,
                liveTransforms: liveTransforms,
                frameSlot: frameSubmission.slot,
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
        return try finishSceneScriptFrame(
            speculativeFrame: frame,
            failureBeforeFrame: scriptFailureBeforeFrame,
            publicationBeforeFrame: publicationBeforeFrame,
            basePipeline: pipeline,
            uniforms: uniforms,
            authoredTransforms: authoredTransforms,
            parallaxFrame: frameContext.parallaxFrame,
            frameSubmission: frameSubmission,
            videoCommandsOutcome: videoCommandsOutcome,
            deferredPresent: deferredPresent
        )
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
        let frameProduction = readinessPlan.tracksReadiness
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
        let frame = try withFrameSignpost("encode") { () throws -> MTLTexture in
            let currentTextures = try texturesForCurrentFrame(
                time: uniforms.time,
                pipeline: textFrame.pipeline,
                frameSlot: frameSubmission.slot
            )
            return try executor.render(
                pipeline: textFrame.pipeline,
                size: sceneRenderSize,
                textures: currentTextures,
                textureSamplingDescriptors: loadedTextureSamplingDescriptors,
                dynamicTextureNames: dynamicTextureNames,
                dynamicLayerIDs: staticCacheExcludedLayerIDs,
                runtimeUniforms: uniforms,
                cameraUniforms: cameraUniforms,
                scriptedConstants: liveEffectConstants,
                passVisibility: liveEffectVisibility,
                sceneID: descriptor.workshopID,
                particleSystems: particleSystems,
                particleTextures: particleTextures,
                particleNormalTextures: particleNormalTextures,
                particleParallax: parallaxFrame,
                textPayloads: textFrame.payloads,
                frameSubmission: frameSubmission,
                frameProduction: frameProduction,
                // `presetSnapshot`, not the layered map: the layered map also carries
                // `propertyOverrides`, whatever the user moved in the settings card. A
                // wallpaper is free to declare its own property named `volume` or `wec_e`
                // (the repo's own fixture declares `volume`) — reading the merged map would let an author's slider drive an engine setting.
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

    /// Tick layer SceneScripts (e.g. a video intro that plays once then hides):
    /// each drives its layer's visibility/alpha + video playback. Gated so a
    /// scene with no layer scripts pays nothing (no per-frame pipeline rebuild).
    private func applyingLayerScriptTicks(
        to pipeline: WPEPreparedRenderPipeline,
        uniforms: WPEMetalRuntimeUniforms,
        layerScriptPointerFrame: WPEPointerFrame
    ) -> WPEPreparedRenderPipeline {
        guard !layerScriptInstances.isEmpty || !layerAlphaScriptInstances.isEmpty
            || !textVisibleScriptInstances.isEmpty || !textAlphaScriptInstances.isEmpty else {
            return pipeline
        }
        // Sorted by objectID: these scripts cross-talk through shared state, so a
        // stable tick order keeps the frame deterministic (oracle) and behaviour
        // reproducible (dictionary order was arbitrary).
        for (objectID, instance) in layerScriptInstances.sorted(by: { $0.key < $1.key }) {
            if let output = tickLayerScript(
                instance,
                runtimeSeconds: uniforms.time,
                pointerFrame: layerScriptPointerFrame
            ) {
                applyLayerScriptOutput(output, ownObjectID: objectID)
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
                liveTextAlpha[objectID] = output.own.alpha
            }
        }
        stageIntroPhaseAlign()
        return pipeline
            .applyingLayerVisibility(liveLayerVisibilityIncludingText)
            .applyingLayerAlpha(liveLayerAlphaIncludingText)
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
            || !sharedOriginReadFans.isEmpty
            || !sharedScaleReadFans.isEmpty
            || !sharedAnglesReadFans.isEmpty
            || !sharedColorReadFans.isEmpty else { return nil }
        var transforms = LiveScriptTransforms()
        transforms.origins.reserveCapacity(dynamicOriginScriptInstances.count + sharedOriginReadFans.count)
        // Sorted by objectID for the same shared-state-determinism reason as the
        // layer/text script loops above.
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
        if audioDebugLogEnabled {
            audioDiagCounter += 1
            if audioDiagCounter % 120 == 2, let sample = transforms.scales.sorted(by: { $0.key < $1.key }).first {
                Logger.notice(
                    "[AudioCapture] scale scripts: instances=\(dynamicScaleScriptInstances.count)"
                        + " published=\(transforms.scales.count)"
                        + " \(sample.key)=\(String(format: "%.4f", sample.value.x))",
                    category: .audioCapture
                )
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
                // WPE's script API exposes `angles` in degrees; scene.json and the
                // rotation math are radians (corpus-verified: all 353 nonzero static
                // angles ≤ 2π). Convert only at this boundary — the instance's
                // lastValue stays in script-space degrees so `value.y += k`
                // accumulation matches WPE (3509243656 universe spin was 57.3× fast).
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
        return transforms
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
        audioSpectrum16: [Float]? = nil
    ) {
        guard !particleSystems.isEmpty else { return }
        // Cursor in the centered render frame (Y-up), or nil when Follow
        // Cursor is off/outside this renderer — drives pointer-locked
        // particle control points (emitter-follow + controlpointattract).
        // Center-relative so it matches `WPEParticleSceneTransform`'s
        // coordinate space.
        let particlePointer: SIMD2<Float>? = followPointerIsLive
            ? SIMD2<Float>(
                Float((pointer.x - 0.5) * sceneRenderSize.width),
                Float((0.5 - pointer.y) * sceneRenderSize.height)
            )
            : nil
        updateParticleHostOriginOffsets(using: liveTransforms)
        // Parents precede their children in `particleSystems` (DFS
        // registration order), so a parent's `primaryLiveParticlePosition`
        // is already this-frame-fresh when its event-follow child ticks.
        for system in particleSystems {
            system.pointerCentered = particlePointer
            if system.isAudioResponsive { system.audioSpectrum16 = audioSpectrum16 }
            Self.injectFollowControlPoint(into: system)
            system.tick(now: time, frameSlot: frameSlot)
        }
    }

    /// Point an `eventfollow` child's control point at its parent's live particle.
    /// Prewarm drives the same rule (see `prewarmParticleSystems`), so this stays
    /// the single definition of parent→child injection.
    nonisolated static func injectFollowControlPoint(into system: WPEParticleSystem) {
        if let parent = system.followParent {
            if let followPosition = parent.primaryLiveParticlePosition {
                system.injectedControlPoints[system.followControlPointID] = followPosition
            } else {
                system.injectedControlPoints.removeValue(forKey: system.followControlPointID)
            }
        } else if system.requiresFollowParent {
            // Parent missing (failed to register or weak ref gone): keep
            // the follow gate so the orphan stays disabled instead of
            // spawning at a wrong static origin.
            system.injectedControlPoints.removeValue(forKey: system.followControlPointID)
        }
    }

    /// Ticks every shader-constant script into `liveEffectConstants`, which the
    /// executor merges over the authored values for this frame. A constant keeps
    /// its last good value when its script returns nothing, matching how the
    /// transform families hold their last value.
    private func tickEffectConstantScripts(pointer: SIMD2<Double>, time: Double) {
        guard !effectConstantScriptInstances.isEmpty
            || !sharedEffectConstantReadFans.isEmpty else { return }
        // Sorted for the same shared-state determinism as the other tick loops.
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

    /// Ticks each script-gated effect's visibility script. Runs AFTER the constant
    /// scripts because the value a gate reads (`shared.shownight`) is produced by a
    /// constant script on the very effect the gate controls, so same-frame ordering
    /// removes a frame of lag on the day/night switch. A gate keeps its last value
    /// when its script returns nothing, matching the other script families.
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

    /// Hand this frame's `ISoundLayer` calls to the audio runtime. Scripts enqueue
    /// onto `shared` from their own queues; applying them here keeps AVAudioEngine
    /// touched from one place.
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
        // A stable object order makes shared-state dependencies and traces deterministic.
        for (id, instance) in textScriptInstances.sorted(by: { $0.key < $1.key }) {
            liveTextByID[id] = tickTextScript(instance, runtimeSeconds: runtimeSeconds)
        }
        return liveTextByID
    }
}
#endif
