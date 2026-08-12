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
        sceneScriptLoadState.retireCurrent()
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
        outputTexture = nil
        outputFrameProduction = nil
        latestFrameProduction = nil
        renderGraph = nil
        renderPipeline = nil
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
        loadDiagnostics = nil
        resolutionTracer.reset()
        releaseDynamicTextureSources()
        particleSystems.removeAll(keepingCapacity: false)
        particleTextures.removeAll(keepingCapacity: false)
        particleNormalTextures.removeAll(keepingCapacity: false)
        textObjects.removeAll(keepingCapacity: false)
        textMeshRenderer = nil
        releaseTextTargets()
        transformHostLocalTransformsByID.removeAll(keepingCapacity: false)
        onDemandVideoKeyByID.removeAll(keepingCapacity: false)
        onDemandVideoLoading.removeAll(keepingCapacity: false)
        createdLayerTemplatesByImagePath.removeAll(keepingCapacity: false)
        soundRuntime?.stop()
        soundRuntime = nil
        sceneRenderSize = CGSize(width: 1, height: 1)
        cameraUniforms = .identity
        lastRuntimeUniforms = nil
        lastFramePipeline = nil
        cachedSnapshot = nil
        executor.releaseTransientResources()
        try await load(on: actor)
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
        refreshLiveness()
    }

    /// Updates how the scene is fitted to the screen. For a static (non-continuous)
    /// scene, re-present once so the new fit shows immediately rather than waiting
    /// for the next content change.
    func setPresentFitMode(_ mode: WPEPresentFitMode) {
        guard mode != presentFitMode else { return }
        presentFitMode = mode
        if !needsContinuousFrames, outputTexture != nil {
            surfaceControl.drawImmediately()
        }
    }

    func setClickCaptureEnabled(_ enabled: Bool) {
        surfaceControl.setClickCaptureEnabled(enabled)
        refreshLiveness()
    }

    /// Re-evaluates the paused/continuous state after a mouse-interaction toggle
    /// flips at runtime, so turning Follow Cursor / Interaction on un-pauses a
    /// previously-static scene (and turning them off lets it re-pause).
    private func refreshLiveness() {
        guard currentProfile == .quality else { return }
        surfaceControl.applyPacing(WPERenderPacingUpdate(
            isPaused: !needsContinuousFrames,
            enableSetNeedsDisplay: !needsContinuousFrames
        ))
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
        soundRuntime?.setMasterVolume(volume)
    }

    /// True when something on stage actually changes between frames — a dynamic
    /// texture (animated `.tex` / video), a live particle system, or a
    /// SceneScript-driven transform. Static-scene + dynamic-content combos must
    /// NOT short-circuit MTKView into the paused/on-demand path or they freeze
    /// after the first frame.
    var needsContinuousFrames: Bool {
        hasAnimatedShaderPasses
            || sceneSupportsAudioProcessing
            || !dynamicTextureSources.isEmpty
            // On-demand videos may all be released (hidden) yet still need a live
            // loop so a reveal triggers their rebuild via reconcileVideoResidency.
            || !onDemandVideoKeyByID.isEmpty
            || !particleSystems.isEmpty
            || !dynamicOriginScriptInstances.isEmpty
            || !dynamicScaleScriptInstances.isEmpty
            || !dynamicAnglesScriptInstances.isEmpty
            || !dynamicColorScriptInstances.isEmpty
            || !layerScriptInstances.isEmpty
            || !layerAlphaScriptInstances.isEmpty
            // Text scripts tick per frame too (content writes `shared` state;
            // visibility/alpha drive fades) — a scene whose only live driver is a
            // text script must keep the loop running or it freezes at frame 0.
            || !textScriptInstances.isEmpty
            || !textVisibleScriptInstances.isEmpty
            || !textAlphaScriptInstances.isEmpty
            || pointerDrivenContent
    }

    /// The cursor moves between frames, so anything that consumes it needs a
    /// live frame to re-sample — otherwise a static scene renders once at load
    /// and never reacts to the mouse again (the "no interaction" bug). Camera
    /// parallax (gated by the Follow Cursor toggle) and click capture both
    /// qualify; pointer-only shaders are already "animated" (effects/workshop)
    /// and covered by `hasAnimatedShaderPasses`.
    private var pointerDrivenContent: Bool {
        // `!= 0`, not `> 0`: a negative amount/influence is an INVERTED parallax
        // (WPE multiplies the sign straight in), so it still needs the pointer.
        (mouseInteractionEnabled
            && cameraParallaxSettings.enabled
            && cameraParallaxSettings.amount != 0
            && cameraParallaxSettings.mouseInfluence != 0)
            || mailbox.read().clickCaptureEnabled
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

    func applyPerformanceProfile(_ profile: WallpaperPerformanceProfile) {
        currentProfile = profile
        dynamicTextureSources.values.forEach { $0.applyPerformanceProfile(profile) }
        switch profile {
        case .quality:
            surfaceControl.applyPacing(WPERenderPacingUpdate(
                isPaused: !needsContinuousFrames,
                enableSetNeedsDisplay: !needsContinuousFrames,
                preferredFramesPerSecond: effectiveFPS
            ))
            // Restart scene audio that a prior `.suspended` paused. No-op when
            // audio never started (deferred startup) or is already running.
            soundRuntime?.resume()
        case .suspended:
            surfaceControl.applyPacing(WPERenderPacingUpdate(isPaused: true, enableSetNeedsDisplay: true))
            surfaceControl.releaseDrawables()
            // Pause the audio engine + FFT tap so a suspended wallpaper costs no
            // audio CPU; the decoded PCM stays resident for an instant resume.
            soundRuntime?.pause()
            // The atlas is append-only while live strings change. Suspension is
            // a GPU-idle boundary, and memory pressure already resolves to this
            // profile, so discard mesh UVs before releasing their atlas pages.
            // Resume rebuilds only glyphs used by the current strings.
            textMeshRenderer?.releaseCachedResources()
            executor.releaseTransientResources()
        }
    }

    // MARK: - Teardown

    func cleanup() {
        sceneScriptLoadState.retireCurrent()
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
        releaseDynamicTextureSources()
        particleSystems.removeAll(keepingCapacity: false)
        particleTextures.removeAll(keepingCapacity: false)
        particleNormalTextures.removeAll(keepingCapacity: false)
        textObjects.removeAll(keepingCapacity: false)
        textMeshRenderer = nil
        releaseTextTargets()
        transformHostLocalTransformsByID.removeAll(keepingCapacity: false)
        onDemandVideoKeyByID.removeAll(keepingCapacity: false)
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
            if needsContinuousFrames {
                let frame = try renderCurrentFrame(inputs: makeFrameInputs())
                outputTexture = frame
                outputFrameProduction = latestFrameProduction
                textureToPresent = frame
            } else {
                textureToPresent = outputTexture
            }
            guard let texture = textureToPresent else { return }
            let livePosterCaptures = takePendingLivePosterCaptures()
            let presentCompletion = makeReadinessPresentCompletion(
                livePosterCaptures: livePosterCaptures
            )
            var presented = false
            do {
                presented = try executor.present(
                    texture: texture,
                    layer: metalLayer.layer,
                    fitMode: presentFitMode,
                    presentCompletion: presentCompletion
                )
                if !presented {
                    Self.finishLivePosterCaptures(livePosterCaptures, image: nil)
                }
            } catch {
                Self.finishLivePosterCaptures(livePosterCaptures, image: nil)
                throw error
            }
            didLogFrameFailure = false
        } catch is WPEMetalFrameInFlightBudgetExhausted {
            // GPU still busy on a prior frame — skip this vsync rather than
            // block the @MainActor (keeps other displays at full rate). The
            // previously presented frame stays on screen; not a failure.
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
#endif
