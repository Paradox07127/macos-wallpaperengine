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

    /// The teardown half of `reload`: drops every loaded runtime resource —
    /// static/dynamic textures, particles, text, scripts (JSContexts), sound,
    /// executor transients — while keeping the descriptor, resolvers, and asset
    /// provider so a later `load` can rebuild the scene from disk.
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
        // `destroy()` is an event on the current generation. Retire only after
        // the instances have synchronously received it and released their JSC
        // callbacks; late queued completions are rejected from this point on.
        sceneScriptLoadState.retireCurrent()
        loadDiagnostics = nil
        resolutionTracer.reset()
        releaseDynamicTextureSources()
        particleSystems.removeAll(keepingCapacity: false)
        particleTextures.removeAll(keepingCapacity: false)
        particleNormalTextures.removeAll(keepingCapacity: false)
        particleTextureLoadCache.removeAll(keepingCapacity: false)
        textObjects.removeAll(keepingCapacity: false)
        // `releaseTextTargets` owns the renderer; nil-ing it first here made its
        // atlas release a no-op.
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
        // Load rebuilds both (Load.swift). Left stale, a hibernated renderer's
        // frameDemand stays non-empty and the wake's `.quality` command unpauses
        // the display link for the whole reload — seconds of no-op vsync ticks
        // on a heavy scene.
        hasAnimatedShaderPasses = false
        sceneSupportsAudioProcessing = false
        executor.releaseTransientResources()
    }

    /// Deep hibernate: the suspend path's resource-release depth, not a third performance
    /// profile. Runs the reload teardown without the reload — the session wakes a
    /// hibernated renderer by calling `reload()`, which rebuilds everything from the
    /// retained descriptor/provider. Returns false when nothing is loaded (mid-load or
    /// already hibernated), so the caller doesn't mark the session hibernated on a no-op.
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
        // Audio is prepared only after first present. A property mutation during
        // that window must reload from the newly persisted descriptor; otherwise
        // the detached preparation would later publish values from the old document.
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

        // Feed changed values through every layer/text `applyUserProperties`.
        if !layerScriptInstances.isEmpty || !layerAlphaScriptInstances.isEmpty
            || !textVisibleScriptInstances.isEmpty || !textAlphaScriptInstances.isEmpty {
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
            // These dictionaries use compiled gate/pass identities. Keep the
            // typed parser address, but reload until the compiled ID is carried
            // back into the property target without guessing.
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
            // Follow Cursor off: the pointer-spawned particle emitters stop (their
            // spawn is gated on a live pointer), so also clear whatever they already
            // emitted — otherwise those particles linger at the cursor's last spot
            // (and reappear on reload) instead of being prohibited outright.
            for system in particleSystems where system.tracksPointer {
                system.clearLiveParticles()
            }
            // Re-present so the cleared state shows at once even if the scene is paused.
            surfaceControl.setNeedsRedraw()
        }
        synchronizeFrameDemand()
        pushPointerEventMonitoring()
    }

    /// Updates how the scene is fitted to the screen. For a static (non-continuous)
    /// scene, re-present once so the new fit shows immediately rather than waiting
    /// for the next content change.
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

    /// Re-evaluates frame demand after anything that can flip it at runtime — a
    /// mouse-interaction toggle, an on-demand video release/rebuild, or a particle
    /// emitter finishing — and pushes the paused/continuous state to the surface
    /// (dedup'd on transitions) plus the activity mirror to the session.
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

    /// Pushes the "would this renderer do real work under `.quality`" mirror to
    /// the session (App Nap gate). Renderer-side dedupe; the callback hops to
    /// MainActor on the session side.
    func publishRuntimeActivity() {
        guard let onRuntimeActivityChange else { return }
        let activity = WPESceneRuntimeActivity(
            // retireRuntimeState clears the demand inputs, but `didLoad &&`
            // stays as the belt: activity must never read "working" between a
            // retire and the load that rebuilds those flags.
            producesFrames: didLoad && needsPacingLoop,
            audible: soundRuntime != nil
        )
        guard activity != lastPublishedRuntimeActivity else { return }
        lastPublishedRuntimeActivity = activity
        onRuntimeActivityChange(activity)
    }

    /// Applies the user-selected frame rate ceiling. `.unlimited` falls
    /// back to vsync (`unlimitedPreferredFPS`) so MTKView doesn't free-run.
    /// Suspended state is not overridden here — the ceiling takes effect on
    /// the next non-suspended transition.
    func setFrameRateLimit(_ limit: FrameRateLimit) {
        let resolved: Int
        switch limit {
        case .unlimited:
            resolved = Self.unlimitedPreferredFPS
        default:
            resolved = max(1, limit.rawValue)
        }
        guard resolved != userPreferredFPS else { return }
        userPreferredFPS = resolved
        applyEffectiveFrameRate()
    }

    /// The user ceiling, optionally halved (floored at `adaptiveThrottleFloorFPS`,
    /// never above the ceiling) while the adaptive background throttle is active.
    var effectiveFPS: Int {
        guard adaptiveThrottleActive else { return userPreferredFPS }
        return min(userPreferredFPS, max(Self.adaptiveThrottleFloorFPS, userPreferredFPS / 2))
    }

    /// Suspended scenes don't drive frames, so the ceiling re-applies on the
    /// next `.quality` transition (mirrors `setFrameRateLimit`'s old guard).
    private func applyEffectiveFrameRate() {
        guard currentProfile != .suspended else { return }
        surfaceControl.applyPacing(WPERenderPacingUpdate(preferredFramesPerSecond: effectiveFPS))
    }

    func setAdaptiveFrameRateThrottle(_ active: Bool) {
        guard active != adaptiveThrottleActive else { return }
        adaptiveThrottleActive = active
        applyEffectiveFrameRate()
    }

    /// Forwards the inspector's mute toggle into the scene's audio
    /// runtime. Cached so calls that arrive before the deferred audio
    /// startup (which fires after the first present) still take effect once
    /// the runtime exists.
    func setAudioMuted(_ muted: Bool) {
        pendingAudioMuted = muted
        soundRuntime?.setMuted(muted)
    }

    /// Forwards the inspector's audio slider into the scene's audio
    /// runtime as a master gain multiplied into each scene-declared
    /// `sound.volume`. Cached so pre-load calls survive across the
    /// deferred audio-startup boundary.
    func setAudioVolume(_ volume: Double) {
        pendingAudioVolume = volume
        soundRuntime?.setMasterVolume(effectiveAudioVolume)
    }

    /// The user's master level scaled by the applied preset's own.
    var effectiveAudioVolume: Double {
        WPEEngineAudioSettings.effectiveVolume(
            master: pendingAudioVolume, preset: presetAudioSettings
        )
    }

    /// True when something on stage actually changes between frames — a dynamic
    /// texture (animated `.tex` / video), a live particle system, or a
    /// SceneScript-driven transform. Static-scene + dynamic-content combos must
    /// NOT short-circuit MTKView into the paused/on-demand path or they freeze
    /// after the first frame.
    var needsContinuousFrames: Bool { !frameDemand.isEmpty }

    /// Per-category frame demand. Each bit answers "does this subsystem need the loop
    /// running RIGHT NOW", not "does the scene contain this subsystem": `.particles`
    /// excludes permanently finished emitters (one-shot/duration-bounded, last particle
    /// died) and pointer-locked emitters empty while the cursor is off this display
    /// (pointer enter wakes one frame via `WPEPointerPublisher.onPointerEnteredView`).
    /// Fully released on-demand videos carry no demand — a reveal is script-driven
    /// (`.scripts` demand) or property-patch-driven (the static patch renders a frame,
    /// whose `reconcileVideoResidency` rebuild re-raises `.dynamicTextures` via the
    /// `dynamicTextureSources` didSet). Every other category stays whole-scene
    /// conservative: missing a shrink costs CPU, a wrong shrink freezes a live animation.
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
            // Text scripts tick per frame too (content writes `shared` state;
            // visibility/alpha drive fades) — a scene whose only live driver is a
            // text script must keep the loop running or it freezes at frame 0.
            || !textScriptInstances.isEmpty
            || !textVisibleScriptInstances.isEmpty
            || !textAlphaScriptInstances.isEmpty {
            demand.insert(.scripts)
        }
        if pointerDrivenContent { demand.insert(.pointer) }
        return demand
    }

    /// The cursor moves between frames, so anything that consumes it needs a live frame to
    /// re-sample — otherwise a static scene renders once at load and never reacts to the
    /// mouse again (the "no interaction" bug). Camera parallax (Follow Cursor toggle) and
    /// click capture both qualify; pointer-only shaders are already "animated"
    /// (effects/workshop) and covered by `hasAnimatedShaderPasses`.
    private var pointerDrivenContent: Bool {
        // `!= 0`, not `> 0`: a negative amount/influence is an INVERTED parallax (WPE
        // multiplies the sign straight in), so it still needs the pointer. The last-pushed
        // click-capture value takes priority over the mailbox for the same reason as in
        // `pushPointerEventMonitoring`: the mailbox copy is written on the main thread and
        // may not have landed when the toggle's demand re-evaluation runs on the render actor.
        (mouseInteractionEnabled
            && cameraParallaxSettings.enabled
            && cameraParallaxSettings.amount != 0
            && cameraParallaxSettings.mouseInfluence != 0)
            || lastPushedClickCaptureEnabled
            ?? mailbox.read().clickCaptureEnabled
    }

    /// Whether anything in the loaded scene could consume the mailbox pointer.
    /// Deliberately conservative: effects/workshop shaders can sample `g_PointerPosition*`,
    /// any script instance can read the pointer or register cursor handlers at runtime, and
    /// particle systems can follow it through pointer-locked control points/attractors even
    /// when `tracksPointer` is false — all keep the monitors on. Only a provably pointer-free scene gates them off.
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
            || !textScriptInstances.isEmpty
            || !textVisibleScriptInstances.isEmpty
            || !textAlphaScriptInstances.isEmpty
            || !effectConstantScriptInstances.isEmpty
            || !effectVisibilityScriptInstances.isEmpty
    }

    /// Pushes the NSEvent-monitor gate to the surface: every mouse move wakes the main
    /// thread while monitors are installed, so they run only when the renderer is
    /// unsuspended AND the pointer can be consumed. Mirrors `sampleFrameContext`'s discard
    /// rule (Follow Cursor + click capture both off forces `.inactive`, so the mailbox feed
    /// is provably unread); `clickCaptureEnabled` is passed explicitly since the mailbox copy may lag onto the main thread.
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

    /// A pass animates per-frame when its shader samples `g_Time` /
    /// `g_AudioSpectrum*` — i.e. WPE local effects (`effects/…`) and workshop
    /// custom shaders (`workshop/…`). The static base shaders (`solidcolor`,
    /// `genericimage2/4`, `compose`, `copy`) do not, so a scene built only on
    /// those is genuinely static and may stay on the paused/on-demand path.
    static func pipelineHasAnimatedPasses(_ pipeline: WPEPreparedRenderPipeline) -> Bool {
        pipeline.layers.contains { layer in
            layer.passes.contains { prepared in
                let shader = prepared.pass.shader.lowercased()
                return shader.contains("effects/") || shader.contains("workshop/")
            }
        }
    }

    /// A pass consumes the system-audio spectrum when its shader text reads
    /// `g_AudioSpectrum*` — matched case-insensitively, because the runtime resolves frame
    /// globals through `canonicalNameByLowercased`. With every AUDIOPROCESSING combo at 0 the
    /// guarded branches are compiled out (the preprocessor keeps disabled `#if` branches in
    /// the retained source), but a read outside those guards is still live.
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

    /// Lowercased source in. Walks `#if` nesting: a `g_audiospectrum` mention
    /// counts only when an enclosing conditional is provably compiled out at
    /// combo 0. Biased toward `true` — the `#else` arm of an audio guard,
    /// `#ifdef` (the prelude always #defines the combo), and every condition
    /// that is not exactly `AUDIOPROCESSING` are all treated as live.
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

    /// Only the exact condition `AUDIOPROCESSING` (a trailing `//` comment
    /// aside) is provably compiled out at combo 0; `#if FOO /* audio… */`,
    /// `!AUDIOPROCESSING`, `== 0`, and compound conditions stay live-biased.
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
            // Restart scene audio that a prior `.suspended` paused. No-op when
            // audio never started (deferred startup) or is already running.
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
            // The atlas is append-only while live strings change. Suspension is
            // a GPU-idle boundary, and memory pressure already resolves to this
            // profile, so discard mesh UVs before releasing their atlas pages.
            // Resume rebuilds only glyphs used by the current strings.
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
        // Owner is an actor now; quiesce fire-and-forget from this sync teardown.
        // It cancels in-flight reload tasks; the discarded Drain isn't awaited.
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
        // `releaseTextTargets` owns the renderer; nil-ing it first here made its
        // atlas release a no-op.
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
            // nil → present still needs its own command buffer.
            // Adopt what the LAST present actually drew to. Retrying before the
            // present would re-read the same unset layer — `nextDrawable()` is
            // what sizes it — and a static scene pauses after frame one, so a
            // pre-present retry never gets a second chance.
            adoptPresentedDrawableSize()
            // `defer`, not a trailing call: the demote is decided inside
            // `encodePresent`, and a later throw (a present-pass PSO or encoder
            // failure) would otherwise skip the drain. On a static scene nothing
            // requests another tick, so the purge and the forced redraw would
            // never happen at all.
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
            // A frame can retire the last demand source (a one-shot emitter's final particle
            // dying, a patch-hidden video releasing): settle the loop as soon as that happens
            // instead of ticking a finished scene. Dedup'd inside, so steady continuous scenes
            // pay two bool sweeps. Present retry keeps the link unpaused for the next vsync;
            // do not `setNeedsRedraw()` here — the render-thread pacer would re-enter `renderFrame()` on this stack.
            synchronizeFrameDemand()
        } catch is WPEMetalFrameInFlightBudgetExhausted {
            // GPU still busy on a prior frame — skip this vsync rather than
            // block this display's render actor (keeps other displays at full
            // rate). The previously presented frame stays on screen; not a failure.
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

/// One bit per subsystem that needs the render loop running this instant.
/// Empty ⇒ the scene is static right now and may sit on the paused/on-demand
/// path. See `WPEMetalSceneRenderer.frameDemand` for the per-bit semantics.
struct WPEFrameDemand: OptionSet, Sendable {
    let rawValue: UInt8
    static let animatedShaders = Self(rawValue: 1 << 0)
    static let audioReactive = Self(rawValue: 1 << 1)
    static let dynamicTextures = Self(rawValue: 1 << 2)
    static let particles = Self(rawValue: 1 << 3)
    static let scripts = Self(rawValue: 1 << 4)
    static let pointer = Self(rawValue: 1 << 5)
}

/// Renderer→session mirror of what would do real work under `.quality`, pushed
/// on change so the App Nap assertion can be released for a playing-but-static
/// scene without reaching across the render actor synchronously.
struct WPESceneRuntimeActivity: Equatable, Sendable {
    /// Mirrors `needsContinuousFrames` (false while hibernated/unloaded).
    let producesFrames: Bool
    /// A scene sound runtime exists (conservative: counts even while muted).
    let audible: Bool
}
#endif
