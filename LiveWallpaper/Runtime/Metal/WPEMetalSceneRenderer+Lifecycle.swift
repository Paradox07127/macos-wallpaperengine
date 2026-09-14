#if !LITE_BUILD
import AppKit
import LiveWallpaperCore
import LiveWallpaperProWPE
import MetalKit

extension WPEMetalSceneRenderer {

    private struct SceneScriptPropertyConsumerKey: Hashable {
        let objectID: String
        let role: WPESceneScriptPropertyRole
        let subresourceID: String?
    }

    private struct ScenePropertyPatchPlan {
        var layers: [String: Bool]
        var text: [String: Bool]
        var soundVisibility: [String: Bool] = [:]
        var soundVolume: [String: Double] = [:]
        var scriptProperties: [
            SceneScriptPropertyConsumerKey: [String: WPESceneScriptPropertyValue]
        ] = [:]
    }

    // MARK: - Reload & scene property patching

    func reload(on actor: isolated WPEDisplayRenderActor) async throws {
        await retireRuntimeState(on: actor)
        try await load(on: actor)
    }

    func retireRuntimeState(on actor: isolated WPEDisplayRenderActor) async {
        didLoad = false
        let staticTextureReloadDrain = await staticTextureReloadTaskOwner.quiesce()
        loadGeneration &+= 1
        await staticTextureReloadDrain.wait()
        finishAllPendingLivePosterCaptures(image: nil)
        deferredAudioStartupTask?.cancel()
        deferredAudioStartupTask = nil
        pendingAudioStartupDocument = nil
        completedPresentGeneration = nil
        failedPresentGeneration = nil
        pendingPresentRetryCount = 0
        outputTexture = nil
        outputFrameProduction = nil
        latestFrameProduction = nil
        renderGraph = nil
        renderPipeline = nil
        #if DEBUG
        shaderImplementationInventory = []
        #endif
        lastFramePipeline = nil
        scenePropertyBindings = [:]
        liveLayerVisibility = [:]
        liveCreatedLayers = [:]
        createdLayerTemplatesByImagePath = [:]
        previousPointer = SIMD2<Double>(0.5, 0.5)
        previousPointerWasLive = false
        previousLayerScriptPointerFrame = .neutral
        objectParentByID = [:]
        ownVisibilityByID = [:]
        liveTextVisibility = [:]
        clearSceneScriptRuntimeState()
        // Retire only after destroy() has synchronously released JSC callbacks; late queued completions would still run.
        sceneScriptLoadState.retireCurrent()
        loadDiagnostics = nil
        resolutionTracer.reset()
        releaseDynamicTextureSources()
        particleSystems.removeAll(keepingCapacity: false)
        particleTextures.removeAll(keepingCapacity: false)
        particleNormalTextures.removeAll(keepingCapacity: false)
        particleTextureLoadCache.removeAll(keepingCapacity: false)
        textObjects.removeAll(keepingCapacity: false)
        // `releaseTextTargets` owns the renderer; nil-ing it first would make its atlas release a no-op.
        releaseTextTargets()
        transformHostLocalTransformsByID.removeAll(keepingCapacity: false)
        layerAncestorLocalTransformsByID.removeAll(keepingCapacity: false)
        onDemandVideoKeyByID.removeAll(keepingCapacity: false)
        onDemandVideoKeysByConsumerID.removeAll(keepingCapacity: false)
        onDemandVideoKeysByImagePath.removeAll(keepingCapacity: false)
        onDemandVideoLoading.removeAll(keepingCapacity: false)
        createdLayerTemplatesByImagePath.removeAll(keepingCapacity: false)
        soundRuntime?.stop()
        soundRuntime = nil
        latchedTextureCap = nil
        didLatchTextureCap = false
        hasPlannedUpscale = false
        sceneRenderSize = CGSize(width: 1, height: 1)
        cameraUniforms = .identity
        lastRuntimeUniforms = nil
        lastFramePipeline = nil
        cachedSnapshot = nil
        // Left stale, frameDemand stays non-empty and the wake's `.quality` command would unpause the display link for the whole reload.
        hasAnimatedShaderPasses = false
        sceneSupportsAudioProcessing = false
        // Scene-scoped: do not reset inside `releaseTransientResources()` — that is also the `.suspended` path and would blank the inspector's failure list for a still-loaded scene.
        executor.shaderErrorSink.reset()
        executor.releaseTransientResources()
    }

    /// Suspend-path resource-release depth, not a third performance profile.
    func hibernate(on actor: isolated WPEDisplayRenderActor) async -> Bool {
        guard didLoad else { return false }
        await retireRuntimeState(on: actor)
        publishRuntimeActivity()
        return true
    }

    func canApplyScenePropertyPatch(_ patch: WPEScenePropertyPatch) -> Bool {
        scenePropertyPatchPlan(patch) != nil
    }

    private func scenePropertyPatchPlan(
        _ patch: WPEScenePropertyPatch
    ) -> ScenePropertyPatchPlan? {
        guard !patch.requiresReload else { return nil }
        guard !patch.changedKeys.isEmpty else {
            return ScenePropertyPatchPlan(layers: liveLayerVisibility, text: liveTextVisibility)
        }
        guard renderPipeline != nil || patch.incrementalBindings.isEmpty else { return nil }
        var plan = ScenePropertyPatchPlan(
            layers: liveLayerVisibility,
            text: liveTextVisibility
        )

        func resolvedVisible(for binding: WPEScenePropertyBinding) -> Bool? {
            if let condition = binding.condition {
                guard let value = patch.newValues[binding.propertyKey] else { return nil }
                return WallpaperEngineProjectPropertySchema.sceneConditionMatches(
                    value: value,
                    condition: condition
                )
            }
            return patch.newValues[binding.propertyKey]?.boolValue
        }

        func scriptValue(for propertyKey: String) -> WPESceneScriptPropertyValue? {
            guard let value = patch.newValues[propertyKey] else { return nil }
            switch value {
            case .bool(let value): return .bool(value)
            case .number(let value): return .number(value)
            case .string(let value): return .string(value)
            }
        }

        for binding in patch.incrementalBindings {
            switch (binding.target, binding.kind) {
            case (.imageObject(let id), .visible):
                guard let value = resolvedVisible(for: binding) else { return nil }
                plan.layers[id] = value
            case (.textObject(let id), .visible):
                guard let value = resolvedVisible(for: binding) else { return nil }
                plan.text[id] = value
            case (.soundObject(let id), .visible):
                guard let value = resolvedVisible(for: binding) else { return nil }
                plan.soundVisibility[id] = value
            case (.soundObject(let id), .volume):
                guard binding.condition == nil,
                      let value = patch.newValues[binding.propertyKey]?.numberValue,
                      value.isFinite else { return nil }
                plan.soundVolume[id] = min(max(value, 0), 1)
            case (.scriptProperty(let target), .scriptProperty):
                guard binding.condition == nil,
                      hasLiveScriptPropertyConsumer(target),
                      let value = scriptValue(for: binding.propertyKey) else {
                    return nil
                }
                let key = SceneScriptPropertyConsumerKey(
                    objectID: target.objectID,
                    role: target.role,
                    subresourceID: target.subresourceID
                )
                plan.scriptProperties[key, default: [:]][target.propertyName] = value
            default:
                return nil
            }
        }
        // Audio is prepared only after first present; a property mutation while `soundRuntime` is nil must reload or the detached preparation would later publish the old document.
        if (!plan.soundVisibility.isEmpty || !plan.soundVolume.isEmpty), soundRuntime == nil {
            return nil
        }
        return plan
    }

    func applyScenePropertyPatch(_ patch: WPEScenePropertyPatch) -> Bool {
        guard let plan = scenePropertyPatchPlan(patch) else { return false }
        let scriptFailureBeforePatch = sceneScriptLoadState.currentFailureReason
        let presentationBeforePatch = captureSceneScriptPresentation()
        let lastFramePipelineBeforePatch = lastFramePipeline
        let frameProductionBeforePatch = latestFrameProduction
        beginSceneScriptVideoCommands()
        liveLayerVisibility = plan.layers
        liveTextVisibility = plan.text

        guard applyLiveScriptPropertyUpdates(plan.scriptProperties) else {
            discardSceneScriptVideoCommands()
            restoreSceneScriptPresentation(presentationBeforePatch)
            return false
        }

        if !layerScriptInstances.isEmpty || !layerAlphaScriptInstances.isEmpty
            || !textVisibleScriptInstances.isEmpty || !textAlphaScriptInstances.isEmpty
            || !particleAlphaScriptInstances.isEmpty
            || hasTransformScriptInstances {
            let changed = Self.bridgeUserProperties(
                patch.newValues.filter { patch.changedKeys.contains($0.key) }
            )
            if !changed.isEmpty {
                for (objectID, instance) in layerScriptInstances {
                    if let output = applyScriptUserProperties(
                        instance,
                        changed,
                        runtimeSeconds: lastRuntimeUniforms?.time
                    ) {
                        applyLayerScriptOutput(output, ownObjectID: objectID)
                    }
                }
                for (objectID, instance) in layerAlphaScriptInstances {
                    if let output = applyScriptUserProperties(
                        instance,
                        changed,
                        runtimeSeconds: lastRuntimeUniforms?.time
                    ) {
                        applyLayerAlphaScriptOutput(output, ownObjectID: objectID)
                    }
                }
                for (objectID, instance) in particleAlphaScriptInstances {
                    if let output = applyScriptUserProperties(
                        instance,
                        changed,
                        runtimeSeconds: lastRuntimeUniforms?.time
                    ) {
                        liveParticleInstanceAlpha[objectID] = output.own.alpha
                    }
                }
                for (objectID, instance) in textVisibleScriptInstances {
                    if let output = applyScriptUserProperties(
                        instance,
                        changed,
                        runtimeSeconds: lastRuntimeUniforms?.time
                    ) {
                        applyTextScriptOutput(output, ownObjectID: objectID)
                    }
                }
                for (objectID, instance) in textAlphaScriptInstances {
                    if let output = applyScriptUserProperties(
                        instance,
                        changed,
                        runtimeSeconds: lastRuntimeUniforms?.time
                    ) {
                        liveTextAlpha[objectID] = output.own.alpha
                    }
                }
                dispatchTransformScriptUserProperties(changed)
            }
        }

        if scriptFailureBeforePatch == nil {
            let failureBeforeCommit = sceneScriptLoadState.currentFailureReason
            let committed = failureBeforeCommit == nil
                && finishCurrentSceneScriptVideoCommands()
            if !committed {
                discardSceneScriptVideoCommands()
                invalidateIntroPhaseAlign()
                restoreSceneScriptPresentation(presentationBeforePatch)
                if let failure = failureBeforeCommit ?? sceneScriptLoadState.currentFailureReason {
                    Logger.warning(
                        "Scene \(descriptor.workshopID) discarded its failed SceneScript property traversal: \(failure)",
                        category: .wpeRender
                    )
                }
                return false
            }
        } else {
            discardSceneScriptVideoCommands()
        }

        if let pipeline = renderPipeline {
            let previousPipeline = pipeline
            renderPipeline = pipeline
                .applyingLayerVisibility(liveLayerVisibilityIncludingText)
                .applyingLayerAlpha(liveLayerAlphaIncludingText)
            if !needsContinuousFrames {
                do {
                    let frame = try renderCurrentFrame(inputs: makeFrameInputs())
                    outputTexture = frame
                    outputFrameProduction = latestFrameProduction
                    applySoundPropertyUpdates(plan)
                    surfaceControl.drawImmediately()
                    return true
                } catch {
                    restoreSceneScriptPresentation(presentationBeforePatch)
                    renderPipeline = previousPipeline
                    lastFramePipeline = lastFramePipelineBeforePatch
                    latestFrameProduction = frameProductionBeforePatch
                    return false
                }
            }
        }
        applySoundPropertyUpdates(plan)
        surfaceControl.setNeedsRedraw()
        return true
    }

    private func hasLiveScriptPropertyConsumer(
        _ target: WPESceneScriptPropertyTarget
    ) -> Bool {
        switch target.role {
        case .origin:
            return dynamicOriginScriptInstances[target.objectID] != nil
        case .scale:
            return dynamicScaleScriptInstances[target.objectID] != nil
        case .angles:
            return dynamicAnglesScriptInstances[target.objectID] != nil
        case .color:
            return dynamicColorScriptInstances[target.objectID] != nil
        case .layerVisible:
            return layerScriptInstances[target.objectID] != nil
        case .layerAlpha:
            return layerAlphaScriptInstances[target.objectID] != nil
        case .textContent:
            return textScriptInstances[target.objectID] != nil
        case .textVisible:
            return textVisibleScriptInstances[target.objectID] != nil
        case .textAlpha:
            return textAlphaScriptInstances[target.objectID] != nil
        case .effectVisible, .effectConstant:
            // These dictionaries use compiled gate/pass identities; return false (reload) until the compiled ID is on the property target, instead of guessing.
            return false
        }
    }

    private func applyLiveScriptPropertyUpdates(
        _ updates: [
            SceneScriptPropertyConsumerKey: [String: WPESceneScriptPropertyValue]
        ]
    ) -> Bool {
        let runtimeSeconds = lastRuntimeUniforms?.time
        for (key, properties) in updates.sorted(by: {
            if $0.key.objectID != $1.key.objectID {
                return $0.key.objectID < $1.key.objectID
            }
            return $0.key.role.rawValue < $1.key.role.rawValue
        }) {
            switch key.role {
            case .origin:
                guard dynamicOriginScriptInstances[key.objectID]?
                    .applyScriptPropertiesSuperseding(
                        properties,
                        pointerPosition: previousPointer,
                        runtimeSeconds: runtimeSeconds
                    ) == true else { return false }
            case .scale:
                guard dynamicScaleScriptInstances[key.objectID]?
                    .applyScriptPropertiesSuperseding(
                        properties,
                        pointerPosition: previousPointer,
                        runtimeSeconds: runtimeSeconds
                    ) == true else { return false }
            case .angles:
                guard dynamicAnglesScriptInstances[key.objectID]?
                    .applyScriptPropertiesSuperseding(
                        properties,
                        pointerPosition: previousPointer,
                        runtimeSeconds: runtimeSeconds
                    ) == true else { return false }
            case .color:
                guard dynamicColorScriptInstances[key.objectID]?
                    .applyScriptPropertiesSuperseding(
                        properties,
                        pointerPosition: previousPointer,
                        runtimeSeconds: runtimeSeconds
                    ) == true else { return false }
            case .layerVisible:
                guard let instance = layerScriptInstances[key.objectID],
                      let output = instance.applyScriptPropertiesSuperseding(
                        properties,
                        runtimeSeconds: runtimeSeconds
                      ) else { return false }
                applyLayerScriptOutput(output, ownObjectID: key.objectID)
            case .layerAlpha:
                guard let instance = layerAlphaScriptInstances[key.objectID],
                      let output = instance.applyScriptPropertiesSuperseding(
                        properties,
                        runtimeSeconds: runtimeSeconds
                      ) else { return false }
                applyLayerAlphaScriptOutput(output, ownObjectID: key.objectID)
            case .textContent:
                guard textScriptInstances[key.objectID]?
                    .applyScriptPropertiesSuperseding(
                        properties,
                        runtimeSeconds: runtimeSeconds
                    ) == true else { return false }
            case .textVisible:
                guard let instance = textVisibleScriptInstances[key.objectID],
                      let output = instance.applyScriptPropertiesSuperseding(
                        properties,
                        runtimeSeconds: runtimeSeconds
                      ) else { return false }
                applyTextScriptOutput(output, ownObjectID: key.objectID)
            case .textAlpha:
                guard let instance = textAlphaScriptInstances[key.objectID],
                      let output = instance.applyScriptPropertiesSuperseding(
                        properties,
                        runtimeSeconds: runtimeSeconds
                      ) else { return false }
                liveTextAlpha[key.objectID] = output.own.alpha
            case .effectVisible, .effectConstant:
                return false
            }
        }
        return true
    }

    private func applySoundPropertyUpdates(_ plan: ScenePropertyPatchPlan) {
        guard let soundRuntime else { return }
        // Match SceneUserPropertyApplier: volume is committed before visibility
        // can start a newly selected track, avoiding one buffer at the stale gain.
        for (id, volume) in plan.soundVolume {
            soundRuntime.setVolume(volume, forSoundID: id)
        }
        for (id, visible) in plan.soundVisibility {
            soundRuntime.setVisible(visible, forSoundID: id)
        }
    }

    // MARK: - Live configuration (Wallpaper*Configurable conformance)

    func setMouseInteractionEnabled(_ enabled: Bool) {
        mouseInteractionEnabled = enabled
        if !enabled {
            previousPointerWasLive = false
            previousPointer = SIMD2<Double>(0.5, 0.5)
            previousLayerScriptPointerFrame = .neutral
            // Follow Cursor off also clears pointer-spawned particles; otherwise they linger at the last cursor spot and would reappear on reload.
            for system in particleSystems where system.tracksPointer {
                system.clearLiveParticles()
            }
            // Re-present so the cleared state shows at once even if the scene is paused.
            surfaceControl.setNeedsRedraw()
        }
        synchronizeFrameDemand()
        pushPointerEventMonitoring()
    }

    /// For a static scene, re-present once so the new fit shows immediately rather than waiting for the next content change.
    func setPresentFitMode(_ mode: WPEPresentFitMode) {
        guard mode != presentFitMode else { return }
        presentFitMode = mode
        // Fit mode is a MetalFX plan input (center never scales, cover/contain
        // need an exact aspect), so it refreshes the verdict like any other.
        refreshUpscalePlan(reason: "fitMode")
        if !needsContinuousFrames, outputTexture != nil {
            surfaceControl.drawImmediately()
        }
    }

    func setClickCaptureEnabled(_ enabled: Bool) {
        surfaceControl.setClickCaptureEnabled(enabled)
        // Record before the demand re-evaluation so `pointerDrivenContent` sees
        // this toggle instead of the possibly-stale mailbox copy.
        lastPushedClickCaptureEnabled = enabled
        synchronizeFrameDemand()
        pushPointerEventMonitoring(clickCaptureEnabled: enabled)
    }

    func synchronizeFrameDemand() {
        let continuous = needsPacingLoop
        if currentProfile == .quality, lastAppliedContinuousFrames != continuous {
            lastAppliedContinuousFrames = continuous
            surfaceControl.applyPacing(WPERenderPacingUpdate(
                isPaused: !continuous,
                enableSetNeedsDisplay: !continuous
            ))
        }
        publishRuntimeActivity()
    }

    func publishRuntimeActivity() {
        guard let onRuntimeActivityChange else { return }
        let activity = WPESceneRuntimeActivity(
            // `didLoad &&` is required: activity must never read "working" between a retire and the load that rebuilds demand flags.
            producesFrames: didLoad && needsPacingLoop,
            audible: soundRuntime != nil
        )
        guard activity != lastPublishedRuntimeActivity else { return }
        lastPublishedRuntimeActivity = activity
        onRuntimeActivityChange(activity)
    }

    /// Suspended state is not overridden here — the ceiling takes effect on the next non-suspended transition.
    func setFrameRateCeiling(_ framesPerSecond: Int) {
        let resolved = max(1, framesPerSecond)
        guard resolved != userPreferredFPS else { return }
        userPreferredFPS = resolved
        applyEffectiveFrameRate()
    }

    var effectiveFPS: Int {
        guard adaptiveThrottleActive else { return userPreferredFPS }
        return min(userPreferredFPS, max(Self.adaptiveThrottleFloorFPS, userPreferredFPS / 2))
    }

    private func applyEffectiveFrameRate() {
        guard currentProfile != .suspended else { return }
        surfaceControl.applyPacing(WPERenderPacingUpdate(preferredFramesPerSecond: effectiveFPS))
    }

    func setAdaptiveFrameRateThrottle(_ active: Bool) {
        guard active != adaptiveThrottleActive else { return }
        adaptiveThrottleActive = active
        applyEffectiveFrameRate()
    }

    /// Cached so calls that arrive before deferred audio startup still take effect once the runtime exists.
    func setAudioMuted(_ muted: Bool) {
        pendingAudioMuted = muted
        soundRuntime?.setMuted(muted)
    }

    /// Cached so pre-load calls survive across the deferred audio-startup boundary.
    func setAudioVolume(_ volume: Double) {
        pendingAudioVolume = volume
        soundRuntime?.setMasterVolume(effectiveAudioVolume)
    }

    var effectiveAudioVolume: Double {
        WPEEngineAudioSettings.effectiveVolume(
            master: pendingAudioVolume, preset: presetAudioSettings
        )
    }

    /// Static-scene + dynamic-content combos must not short-circuit MTKView into the paused/on-demand path or they freeze after the first frame.
    var needsContinuousFrames: Bool { !frameDemand.isEmpty }

    /// Each bit is "needs the loop RIGHT NOW", not "scene contains this subsystem". A wrong shrink freezes a live animation.
    var frameDemand: WPEFrameDemand {
        var demand: WPEFrameDemand = []
        if hasAnimatedShaderPasses { demand.insert(.animatedShaders) }
        if sceneSupportsAudioProcessing { demand.insert(.audioReactive) }
        if !dynamicTextureSources.isEmpty { demand.insert(.dynamicTextures) }
        if particleSystems.contains(where: { !$0.isPermanentlyIdle && !$0.isBlockedOnAbsentPointer }) {
            demand.insert(.particles)
        }
        if !dynamicOriginScriptInstances.isEmpty
            || !dynamicScaleScriptInstances.isEmpty
            || !dynamicAnglesScriptInstances.isEmpty
            || !dynamicColorScriptInstances.isEmpty
            || !sharedOriginReadFans.isEmpty
            || !sharedScaleReadFans.isEmpty
            || !sharedAnglesReadFans.isEmpty
            || !sharedColorReadFans.isEmpty
            || !layerScriptInstances.isEmpty
            || !layerAlphaScriptInstances.isEmpty
            || !particleAlphaScriptInstances.isEmpty
            // A scene whose only live driver is a text script must keep the loop running or it freezes at frame 0.
            || !textScriptInstances.isEmpty
            || !textVisibleScriptInstances.isEmpty
            || !textAlphaScriptInstances.isEmpty {
            demand.insert(.scripts)
        }
        if pointerDrivenContent { demand.insert(.pointer) }
        return demand
    }

    /// The cursor moves between frames, so anything that consumes it needs a live frame or a static scene never reacts to the mouse again.
    private var pointerDrivenContent: Bool {
        // `!= 0`, not `> 0`: a negative amount/influence is inverted parallax and still needs the pointer. Last-pushed click-capture takes priority over the mailbox, which is written on the main thread and may not have landed.
        (mouseInteractionEnabled
            && cameraParallaxSettings.enabled
            && cameraParallaxSettings.amount != 0
            && cameraParallaxSettings.mouseInfluence != 0)
            || lastPushedClickCaptureEnabled
            ?? mailbox.read().clickCaptureEnabled
    }

    /// Conservative: shaders, scripts, and particle attractors can consume the pointer even when `tracksPointer` is false — only a provably pointer-free scene gates monitors off.
    private var scenePointerConsumersPossible: Bool {
        (cameraParallaxSettings.enabled
            && cameraParallaxSettings.amount != 0
            && cameraParallaxSettings.mouseInfluence != 0)
            || hasAnimatedShaderPasses
            || !particleSystems.isEmpty
            || !dynamicOriginScriptInstances.isEmpty
            || !dynamicScaleScriptInstances.isEmpty
            || !dynamicAnglesScriptInstances.isEmpty
            || !dynamicColorScriptInstances.isEmpty
            || !layerScriptInstances.isEmpty
            || !layerAlphaScriptInstances.isEmpty
            || !particleAlphaScriptInstances.isEmpty
            || !textScriptInstances.isEmpty
            || !textVisibleScriptInstances.isEmpty
            || !textAlphaScriptInstances.isEmpty
            || !effectConstantScriptInstances.isEmpty
            || !effectVisibilityScriptInstances.isEmpty
    }

    /// `clickCaptureEnabled` is passed explicitly since the mailbox copy may lag onto the main thread.
    private func pushPointerEventMonitoring(clickCaptureEnabled: Bool? = nil) {
        if let clickCaptureEnabled { lastPushedClickCaptureEnabled = clickCaptureEnabled }
        let clickCapture = clickCaptureEnabled
            ?? lastPushedClickCaptureEnabled
            ?? mailbox.read().clickCaptureEnabled
        let demanded = clickCapture
            || (mouseInteractionEnabled && scenePointerConsumersPossible)
        surfaceControl.applyPacing(WPERenderPacingUpdate(
            pointerEventsEnabled: currentProfile != .suspended && demanded
        ))
    }

    /// Local `effects/…` and workshop `workshop/…` shaders sample `g_Time` / `g_AudioSpectrum*`; `solidcolor`, `genericimage2/4`, `compose`, `copy` do not.
    static func pipelineHasAnimatedPasses(_ pipeline: WPEPreparedRenderPipeline) -> Bool {
        pipeline.layers.contains { layer in
            layer.passes.contains { prepared in
                let shader = prepared.pass.shader.lowercased()
                return shader.contains("effects/") || shader.contains("workshop/")
            }
        }
    }

    /// `g_AudioSpectrum*` is matched case-insensitively. Combo 0 compiles guarded branches out, but disabled `#if` branches stay in the retained source, so a read outside those guards is still live.
    static func pipelineRequiresAudioCapture(_ pipeline: WPEPreparedRenderPipeline) -> Bool {
        pipeline.layers.contains { layer in
            layer.passes.contains { prepared in
                guard let shader = prepared.shader else { return false }
                let sources = [shader.vertexSource.lowercased(), shader.fragmentSource.lowercased()]
                guard sources.contains(where: { $0.contains("g_audiospectrum") }) else { return false }
                let audioCombos = prepared.comboValues.filter { $0.key.uppercased() == "AUDIOPROCESSING" }
                if audioCombos.isEmpty || audioCombos.values.contains(where: { $0 > 0 }) {
                    return true
                }
                return sources.contains(where: Self.mentionsAudioOutsideAudioGuards)
            }
        }
    }

    /// Walks `#if` nesting, live-biased: `#else`, `#ifdef`, and any condition that is not exactly `AUDIOPROCESSING` are treated as live.
    private static func mentionsAudioOutsideAudioGuards(_ loweredSource: String) -> Bool {
        var guardStack: [Bool] = []
        for rawLine in loweredSource.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.drop(while: { $0 == " " || $0 == "\t" })
            var handled = false
            if line.first == "#" {
                let body = line.dropFirst().drop(while: { $0 == " " || $0 == "\t" })
                let directive = body.prefix(while: { $0.isLetter })
                let condition = body.dropFirst(directive.count)
                handled = true
                switch directive {
                case "if":
                    guardStack.append(Self.isPlainAudioProcessingCondition(condition))
                case "ifdef", "ifndef":
                    guardStack.append(false)
                case "elif":
                    if !guardStack.isEmpty {
                        guardStack[guardStack.count - 1] = Self.isPlainAudioProcessingCondition(condition)
                    }
                case "else":
                    if !guardStack.isEmpty { guardStack[guardStack.count - 1] = false }
                case "endif":
                    if !guardStack.isEmpty { guardStack.removeLast() }
                default:
                    handled = false
                }
            }
            if !handled, line.contains("g_audiospectrum"), !guardStack.contains(true) {
                return true
            }
        }
        return false
    }

    /// Only the exact condition `AUDIOPROCESSING` (a trailing `//` aside) is compiled out at combo 0; `!AUDIOPROCESSING`, `== 0`, and compound conditions stay live-biased.
    private static func isPlainAudioProcessingCondition(_ condition: Substring) -> Bool {
        var text = condition
        if let comment = text.range(of: "//") { text = text[..<comment.lowerBound] }
        return text.trimmingCharacters(in: .whitespaces) == "audioprocessing"
    }

    func applyPerformanceProfile(_ profile: WallpaperPerformanceProfile) {
        currentProfile = profile
        dynamicTextureSources.values.forEach { $0.applyPerformanceProfile(profile) }
        switch profile {
        case .quality:
            let continuous = needsPacingLoop
            lastAppliedContinuousFrames = continuous
            surfaceControl.applyPacing(WPERenderPacingUpdate(
                isPaused: !continuous,
                enableSetNeedsDisplay: !continuous,
                preferredFramesPerSecond: effectiveFPS
            ))
            soundRuntime?.resume()
        case .suspended:
            // Nil, not false: the next `.quality` transition must re-apply the
            // pause state unconditionally.
            lastAppliedContinuousFrames = nil
            surfaceControl.applyPacing(WPERenderPacingUpdate(isPaused: true, enableSetNeedsDisplay: true))
            surfaceControl.releaseDrawables()
            // Pause the audio engine + FFT tap so a suspended wallpaper costs no
            // audio CPU; the decoded PCM stays resident for an instant resume.
            soundRuntime?.pause()
            // Eager .tex animations released their atlases in the profile
            // fan-out above; drop our own binding or nothing is actually freed.
            purgeReleasedAnimatedTextureBindings()
            // Discard mesh UVs before releasing their atlas pages. Resume rebuilds only glyphs used by the current strings.
            textMeshRenderer?.releaseCachedResources()
            executor.releaseTransientResources()
        }
        // Post-switch so the gate sees the profile it just entered. Also the
        // post-load demand evaluation: `load` ends by re-applying the profile.
        pushPointerEventMonitoring()
        publishRuntimeActivity()
    }

    // MARK: - Teardown

    func cleanup() {
        didLoad = false
        Task { [owner = staticTextureReloadTaskOwner] in _ = await owner.quiesce() }
        loadGeneration &+= 1
        finishAllPendingLivePosterCaptures(image: nil)
        deferredAudioStartupTask?.cancel()
        deferredAudioStartupTask = nil
        pendingAudioStartupDocument = nil
        completedPresentGeneration = nil
        failedPresentGeneration = nil
        pendingPresentRetryCount = 0
        surfaceControl.detach()
        outputTexture = nil
        outputFrameProduction = nil
        latestFrameProduction = nil
        lastFramePipeline = nil
        scenePropertyBindings = [:]
        liveLayerVisibility = [:]
        liveCreatedLayers = [:]
        createdLayerTemplatesByImagePath = [:]
        previousPointer = SIMD2<Double>(0.5, 0.5)
        previousPointerWasLive = false
        previousLayerScriptPointerFrame = .neutral
        objectParentByID = [:]
        ownVisibilityByID = [:]
        liveTextVisibility = [:]
        clearSceneScriptRuntimeState()
        sceneScriptLoadState.retireCurrent()
        releaseDynamicTextureSources()
        particleSystems.removeAll(keepingCapacity: false)
        particleTextures.removeAll(keepingCapacity: false)
        particleNormalTextures.removeAll(keepingCapacity: false)
        particleTextureLoadCache.removeAll(keepingCapacity: false)
        textObjects.removeAll(keepingCapacity: false)
        // `releaseTextTargets` owns the renderer; nil-ing it first would make its atlas release a no-op.
        releaseTextTargets()
        transformHostLocalTransformsByID.removeAll(keepingCapacity: false)
        layerAncestorLocalTransformsByID.removeAll(keepingCapacity: false)
        onDemandVideoKeyByID.removeAll(keepingCapacity: false)
        onDemandVideoKeysByConsumerID.removeAll(keepingCapacity: false)
        onDemandVideoKeysByImagePath.removeAll(keepingCapacity: false)
        onDemandVideoLoading.removeAll(keepingCapacity: false)
        createdLayerTemplatesByImagePath.removeAll(keepingCapacity: false)
        soundRuntime?.stop()
        soundRuntime = nil
        cameraParallaxSettings = .disabled
        sceneSupportsAudioProcessing = false
        cameraParallaxSmoother.reset()
        lastRuntimeUniforms = nil
        lastFramePipeline = nil
        cachedSnapshot = nil
        resolutionTracer.reset()
        executor.releaseTransientResources()
        stopEngineAssetsAccessIfNeeded()
        #if DEBUG
        releaseDebugActorIfNeeded()
        #endif
    }
    nonisolated func stopEngineAssetsAccessIfNeeded() {
        guard let url = activeEngineAssetsRootURL else { return }
        url.stopAccessingSecurityScopedResource()
        activeEngineAssetsRootURL = nil
    }

    // MARK: - Frame production (driven by the surface's `draw(in:)`)

    func renderAndPresentFrame() {
        guard didLoad else { return }
        do {
            let textureToPresent: MTLTexture?
            // Adopt what the last present actually drew to. Retrying before present would re-read the same unset layer — `nextDrawable()` is what sizes it — and a static scene would never get a second chance.
            adoptPresentedDrawableSize()
            // `defer`, not a trailing call: a later throw would skip the drain, and a static scene would never request another tick.
            defer { adoptPresentSideDemotion() }
            var mergedPresentResult: Bool?
            // `pendingForcedRerender` promotes one static tick into a real
            // render — the cached frame is at a superseded render scale.
            let mustRerender = needsContinuousFrames || pendingForcedRerender
            pendingForcedRerender = false
            if mustRerender {
                #if DEBUG
                frameEncodeCountForTesting += 1
                #endif
                let deferredPresent: WPEMetalRenderExecutor.DeferredPresentEncoder?
                if executor.synchronizeFrameCompletion {
                    deferredPresent = nil
                } else {
                    let layer = metalLayer.layer
                    let fitMode = presentFitMode
                    deferredPresent = { [self] texture, commandBuffer in
                        // Drain posters here: a throw earlier leaves them pending.
                        let livePosterCaptures = takePendingLivePosterCaptures()
                        let presentCompletion = makeReadinessPresentCompletion(
                            livePosterCaptures: livePosterCaptures,
                            frameProduction: latestFrameProduction
                        )
                        do {
                            let presented = try executor.encodePresent(
                                texture: texture,
                                layer: layer,
                                fitMode: fitMode,
                                worldSourceSize: sceneRenderSize,
                                presentCompletion: presentCompletion,
                                into: commandBuffer
                            )
                            if !presented {
                                livePosterCaptures?.finish(image: nil)
                            }
                            mergedPresentResult = presented
                            return presented
                        } catch {
                            livePosterCaptures?.finish(image: nil)
                            throw error
                        }
                    }
                }
                let frame = try renderCurrentFrame(
                    inputs: makeFrameInputs(),
                    deferredPresent: deferredPresent
                )
                outputTexture = frame
                outputFrameProduction = latestFrameProduction
                textureToPresent = frame
            } else {
                textureToPresent = outputTexture
            }
            guard let texture = textureToPresent else { return }
            let presented: Bool
            if let mergedPresentResult {
                presented = mergedPresentResult
            } else {
                let livePosterCaptures = takePendingLivePosterCaptures()
                let presentCompletion = makeReadinessPresentCompletion(
                    livePosterCaptures: livePosterCaptures,
                    frameProduction: outputFrameProduction
                )
                do {
                    presented = try executor.present(
                        texture: texture,
                        layer: metalLayer.layer,
                        fitMode: presentFitMode,
                        worldSourceSize: sceneRenderSize,
                        presentCompletion: presentCompletion
                    )
                    if !presented {
                        livePosterCaptures?.finish(image: nil)
                    }
                } catch {
                    livePosterCaptures?.finish(image: nil)
                    throw error
                }
            }
            switch WPEStaticPresentRetry.outcome(
                presented: presented,
                sceneHasFrameDemand: needsContinuousFrames,
                retryCount: pendingPresentRetryCount
            ) {
            case .idle:
                pendingPresentRetryCount = 0
            case .retry(let count):
                pendingPresentRetryCount = count
            case .failed:
                pendingPresentRetryCount = 0
                // Once this generation is ready, a later static re-present miss
                // must not flip session prep to `.failed`.
                if completedPresentGeneration != loadGeneration {
                    failedPresentGeneration = loadGeneration
                }
            }
            didLogFrameFailure = false
            // Do not `setNeedsRedraw()` here — the render-thread pacer would re-enter `renderFrame()` on this stack.
            synchronizeFrameDemand()
        } catch is WPEMetalFrameInFlightBudgetExhausted {
            // GPU still busy on a prior frame — skip this vsync rather than block this display's render actor. Not a failure.
            return
        } catch {
            // Per-frame path: log only the first failure of a streak (resets on
            // recovery) so a persistently-broken pipeline can't flood the log.
            if !didLogFrameFailure {
                Logger.warning("Scene \(descriptor.workshopID) frame render/present failed: \(error.localizedDescription)", category: .screenManager)
                didLogFrameFailure = true
            }
        }
    }
}

/// Empty ⇒ the scene is static right now and may sit on the paused/on-demand path.
struct WPEFrameDemand: OptionSet, Sendable {
    let rawValue: UInt8
    static let animatedShaders = Self(rawValue: 1 << 0)
    static let audioReactive = Self(rawValue: 1 << 1)
    static let dynamicTextures = Self(rawValue: 1 << 2)
    static let particles = Self(rawValue: 1 << 3)
    static let scripts = Self(rawValue: 1 << 4)
    static let pointer = Self(rawValue: 1 << 5)
}

struct WPESceneRuntimeActivity: Equatable, Sendable {
    /// Mirrors `needsContinuousFrames` (false while hibernated/unloaded).
    let producesFrames: Bool
    /// A scene sound runtime exists (conservative: counts even while muted).
    let audible: Bool
}
#endif
