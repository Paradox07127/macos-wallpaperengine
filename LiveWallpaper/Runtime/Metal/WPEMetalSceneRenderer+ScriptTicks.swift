#if !LITE_BUILD
import Foundation
import LiveWallpaperCore
import LiveWallpaperProWPE

extension WPEMetalSceneRenderer {
    // MARK: - Script Tick Dispatch

    func consumeSceneScriptLayerOutputs() {
        guard sceneScriptLoadState.currentFailureReason == nil else { return }
        let layerFamilies: [([String: WPELayerScriptInstance], (WPELayerScriptOutput, String) -> Void)] = [
            (layerScriptInstances, { self.applyLayerScriptOutput($0, ownObjectID: $1) }),
            (layerAlphaScriptInstances, { self.applyLayerAlphaScriptOutput($0, ownObjectID: $1) }),
            (textVisibleScriptInstances, { self.applyLayerScriptOutput($0, ownObjectID: $1) }),
            (textAlphaScriptInstances, { self.applyTextAlphaScriptOutput($0, ownObjectID: $1) }),
            (particleAlphaScriptInstances, { self.applyParticleAlphaScriptOutput($0, ownObjectID: $1) }),
        ]
        for (instances, publish) in layerFamilies {
            for (objectID, instance) in instances.sorted(by: { $0.key < $1.key }) {
                if let output = instance.takeSharedLayerOutput() {
                    publish(output, objectID)
                }
            }
        }
        for (objectID, instance) in textScriptInstances.sorted(by: { $0.key < $1.key }) {
            if let output = instance.takeLayerOutput() {
                applyLayerScriptOutput(output, ownObjectID: objectID)
            }
        }
        for instances in [
            dynamicOriginScriptInstances, dynamicScaleScriptInstances,
            dynamicAnglesScriptInstances, dynamicColorScriptInstances, particleRateScriptInstances,
        ] {
            for (_, instance) in instances.sorted(by: { $0.key < $1.key }) {
                consumeTransformScriptLayerOutput(instance)
            }
        }
        for (_, instance) in effectConstantScriptInstances.sorted(
            by: { ($0.key.passID, $0.key.uniform) < ($1.key.passID, $1.key.uniform) }
        ) {
            consumeTransformScriptLayerOutput(instance)
        }
        for (_, instance) in effectVisibilityScriptInstances.sorted(by: { $0.key < $1.key }) {
            consumeTransformScriptLayerOutput(instance)
        }
    }

    private func consumeTransformScriptLayerOutput(_ instance: WPEDynamicTransformScriptInstance) {
        guard let output = instance.takeLayerOutput(), let objectID = instance.ownObjectID else { return }
        applyLayerScriptOutput(output, ownObjectID: objectID)
    }

    static func currentSceneScriptLanguage() -> String {
        AppLanguagePreference.current(in: .appScoped()).wallpaperEngineLanguageCode()
    }

    func installSceneScriptLanguageObservers(on actor: WPEDisplayRenderActor) {
        guard sceneScriptLanguageObservers.isEmpty else { return }
        let center = NotificationCenter.default
        let submitCurrent: @Sendable () -> Void = { [weak actor] in
            actor?.submitConfig(.sceneScriptLanguage(Self.currentSceneScriptLanguage()))
        }
        sceneScriptLanguageObservers = [
            center.addObserver(
                forName: UserDefaults.didChangeNotification,
                object: nil,
                queue: nil
            ) { _ in submitCurrent() },
            center.addObserver(
                forName: NSLocale.currentLocaleDidChangeNotification,
                object: nil,
                queue: nil
            ) { _ in submitCurrent() },
        ]
    }

    func setSceneScriptLanguage(_ language: String) {
        guard sceneScriptGeneralSettings.updateLanguage(language) else { return }
        guard didLoad else { return }
        applySceneScriptGeneralSettingsIfChanged()
    }

    func applyInitialSceneScriptGeneralSettings() {
        dispatchSceneScriptGeneralSettings(
            language: sceneScriptGeneralSettings.takeInitialLanguage()
        )
    }

    /// Subsequent contract: emit only when the language key changed. Every JS call receives a fresh plain object with its own `language` property, so authored `hasOwnProperty('language')` checks behave exactly as in WPE.
    func applySceneScriptGeneralSettingsIfChanged() {
        guard !hasPendingAuthoredLayerBatch else { return }
        guard let language = sceneScriptGeneralSettings.takeChangedLanguage() else { return }
        dispatchSceneScriptGeneralSettings(language: language)
    }

    private func dispatchSceneScriptGeneralSettings(language: String) {
        for (objectID, instance) in layerScriptInstances.sorted(by: { $0.key < $1.key }) {
            if let output = instance.applyGeneralSettings(language: language) {
                applyLayerScriptOutput(output, ownObjectID: objectID)
            }
        }
        for (objectID, instance) in layerAlphaScriptInstances.sorted(by: { $0.key < $1.key }) {
            if let output = instance.applyGeneralSettings(language: language) {
                applyLayerAlphaScriptOutput(output, ownObjectID: objectID)
            }
        }
        for (objectID, instance) in textVisibleScriptInstances.sorted(by: { $0.key < $1.key }) {
            if let output = instance.applyGeneralSettings(language: language) {
                applyTextScriptOutput(output, ownObjectID: objectID)
            }
        }
        for (objectID, instance) in textAlphaScriptInstances.sorted(by: { $0.key < $1.key }) {
            if let output = instance.applyGeneralSettings(language: language) {
                applyTextAlphaScriptOutput(output, ownObjectID: objectID)
            }
        }
        for (objectID, instance) in particleAlphaScriptInstances.sorted(by: { $0.key < $1.key }) {
            if let output = instance.applyGeneralSettings(language: language) {
                applyParticleAlphaScriptOutput(output, ownObjectID: objectID)
            }
        }
        for key in textScriptInstances.keys.sorted() {
            _ = textScriptInstances[key]?.applyGeneralSettings(language: language)
        }
        for instances in [
            dynamicOriginScriptInstances,
            dynamicScaleScriptInstances,
            dynamicAnglesScriptInstances,
            dynamicColorScriptInstances,
            particleRateScriptInstances,
        ] {
            for key in instances.keys.sorted() {
                _ = instances[key]?.applyGeneralSettings(language: language)
            }
        }
        for (_, instance) in effectConstantScriptInstances.sorted(
            by: { ($0.key.passID, $0.key.uniform) < ($1.key.passID, $1.key.uniform) }
        ) {
            _ = instance.applyGeneralSettings(language: language)
        }
        for key in effectVisibilityScriptInstances.keys.sorted() {
            _ = effectVisibilityScriptInstances[key]?.applyGeneralSettings(language: language)
        }
        consumeSceneScriptLayerOutputs()
    }


    func tickLayerScript(
        _ instance: WPELayerScriptInstance,
        runtimeSeconds: Double,
        pointerFrame: WPEPointerFrame
    ) -> WPELayerScriptOutput? {
        let (output, job) = instance.batchTick(
            runtimeSeconds: runtimeSeconds,
            pointerFrame: pointerFrame
        )
        if let job {
            pendingSceneScriptBatchJobs.append(job)
        }
        return output
    }

    func tickTransformScript(
        _ instance: WPEDynamicTransformScriptInstance,
        pointer: SIMD2<Double>,
        runtimeSeconds: Double
    ) -> SIMD3<Double>? {
        let (value, job) = instance.batchTick(
            pointerPosition: pointer,
            runtimeSeconds: runtimeSeconds
        )
        if let job {
            pendingSceneScriptBatchJobs.append(job)
        }
        return value
    }

    func tickTextScript(
        _ instance: WPESceneScriptInstance,
        runtimeSeconds: Double
    ) -> String {
        let (value, job) = instance.batchTickString(runtimeSeconds: runtimeSeconds)
        if let job {
            pendingSceneScriptBatchJobs.append(job)
        }
        return value
    }

    func drainMediaEvents(runtimeSeconds: Double) {
        // Ordered scenes consume this same mailbox in their callback chain.
        guard sceneScriptSharedState?.isAuthoredLayerOrderingEnabled != true else { return }
        guard let mailbox = mediaEventMailbox else { return }
        let events = mailbox.drain()
        // The whole drain goes to each instance as one batch: dispatched per event, the single in-flight async slot would admit the first and silently drop the rest of a cold-start burst.
        for instance in layerScriptInstances.values {
            instance.liveDispatchMediaEvents(events, runtimeSeconds: runtimeSeconds)
        }
        for instance in layerAlphaScriptInstances.values {
            instance.liveDispatchMediaEvents(events, runtimeSeconds: runtimeSeconds)
        }
        for instance in textVisibleScriptInstances.values {
            instance.liveDispatchMediaEvents(events, runtimeSeconds: runtimeSeconds)
        }
        for instance in textAlphaScriptInstances.values {
            instance.liveDispatchMediaEvents(events, runtimeSeconds: runtimeSeconds)
        }
        for instance in particleAlphaScriptInstances.values {
            instance.liveDispatchMediaEvents(events, runtimeSeconds: runtimeSeconds)
        }
        for event in events {
            for instance in textScriptInstances.values {
                instance.dispatchMediaEvent(event, runtimeSeconds: runtimeSeconds)
            }
        }
        for instance in dynamicOriginScriptInstances.values {
            instance.liveDispatchMediaEvents(events, runtimeSeconds: runtimeSeconds)
        }
        for instance in dynamicScaleScriptInstances.values {
            instance.liveDispatchMediaEvents(events, runtimeSeconds: runtimeSeconds)
        }
        for instance in dynamicAnglesScriptInstances.values {
            instance.liveDispatchMediaEvents(events, runtimeSeconds: runtimeSeconds)
        }
        for instance in dynamicColorScriptInstances.values {
            instance.liveDispatchMediaEvents(events, runtimeSeconds: runtimeSeconds)
        }
        for instance in particleRateScriptInstances.values {
            instance.liveDispatchMediaEvents(events, runtimeSeconds: runtimeSeconds)
        }
        for instance in effectConstantScriptInstances.values {
            instance.liveDispatchMediaEvents(events, runtimeSeconds: runtimeSeconds)
        }
        for instance in effectVisibilityScriptInstances.values {
            instance.liveDispatchMediaEvents(events, runtimeSeconds: runtimeSeconds)
        }
    }

    /// Load/settings property pushes stay bounded-synchronous, and fold their
    /// result through the outcome slot so an in-flight tick can't overwrite it.
    func applyScriptUserProperties(
        _ instance: WPELayerScriptInstance,
        _ properties: [String: WPESceneScriptPropertyValue],
        runtimeSeconds: Double? = nil
    ) -> WPELayerScriptOutput? {
        guard instance.handlesUserProperties else { return nil }
        if hasPendingAuthoredLayerBatch,
           let id = layerScriptInstances.first(where: { $0.value === instance })?.key {
            var pending = pendingOrderedLayerProperties[id]
                ?? .init(instance: instance, values: [:], runtimeSeconds: runtimeSeconds)
            pending.values.merge(properties) { _, new in new }
            pending.runtimeSeconds = runtimeSeconds
            pendingOrderedLayerProperties[id] = pending
            return nil
        }
        return instance.applyUserPropertiesSuperseding(
            properties,
            runtimeSeconds: runtimeSeconds
        )
    }

    /// Called only after `updateSurfaceGeometry` accepts a positive changed size; construction merely seeds `engine.screenResolution` and never emits the startup event prohibited by WPE's contract.
    func dispatchSceneScriptResizeScreen(_ size: SIMD2<Double>) {
        if hasPendingAuthoredLayerBatch {
            pendingOrderedLayerResize = size
            return
        }
        for (objectID, instance) in layerScriptInstances.sorted(by: { $0.key < $1.key }) {
            if let output = instance.resizeScreen(size) {
                applyLayerScriptOutput(output, ownObjectID: objectID)
            }
        }
        for (objectID, instance) in layerAlphaScriptInstances.sorted(by: { $0.key < $1.key }) {
            if let output = instance.resizeScreen(size) {
                applyLayerAlphaScriptOutput(output, ownObjectID: objectID)
            }
        }
        for (objectID, instance) in textVisibleScriptInstances.sorted(by: { $0.key < $1.key }) {
            if let output = instance.resizeScreen(size) {
                applyTextScriptOutput(output, ownObjectID: objectID)
            }
        }
        for (objectID, instance) in textAlphaScriptInstances.sorted(by: { $0.key < $1.key }) {
            if let output = instance.resizeScreen(size) {
                applyTextAlphaScriptOutput(output, ownObjectID: objectID)
            }
        }
        for (objectID, instance) in particleAlphaScriptInstances.sorted(by: { $0.key < $1.key }) {
            if let output = instance.resizeScreen(size) {
                applyParticleAlphaScriptOutput(output, ownObjectID: objectID)
            }
        }
        for objectID in textScriptInstances.keys.sorted() {
            _ = textScriptInstances[objectID]?.resizeScreen(size)
        }
        for instances in [
            dynamicOriginScriptInstances,
            dynamicScaleScriptInstances,
            dynamicAnglesScriptInstances,
            dynamicColorScriptInstances,
            particleRateScriptInstances,
        ] {
            for objectID in instances.keys.sorted() {
                _ = instances[objectID]?.resizeScreen(size)
            }
        }
        for (_, instance) in effectConstantScriptInstances.sorted(
            by: { ($0.key.passID, $0.key.uniform) < ($1.key.passID, $1.key.uniform) }
        ) {
            _ = instance.resizeScreen(size)
        }
        for key in effectVisibilityScriptInstances.keys.sorted() {
            _ = effectVisibilityScriptInstances[key]?.resizeScreen(size)
        }
        consumeSceneScriptLayerOutputs()
    }

    func destroySceneScriptInstances() {
        var layerIDs = Set<ObjectIdentifier>()
        for instances in [
            layerScriptInstances,
            layerAlphaScriptInstances,
            textVisibleScriptInstances,
            textAlphaScriptInstances,
            particleAlphaScriptInstances,
        ] {
            for key in instances.keys.sorted() {
                guard let instance = instances[key],
                      layerIDs.insert(ObjectIdentifier(instance)).inserted else { continue }
                _ = instance.destroy()
            }
        }

        var textIDs = Set<ObjectIdentifier>()
        for key in textScriptInstances.keys.sorted() {
            guard let instance = textScriptInstances[key],
                  textIDs.insert(ObjectIdentifier(instance)).inserted else { continue }
            _ = instance.destroy()
        }

        var dynamicIDs = Set<ObjectIdentifier>()
        for instances in [
            dynamicOriginScriptInstances,
            dynamicScaleScriptInstances,
            dynamicAnglesScriptInstances,
            dynamicColorScriptInstances,
            particleRateScriptInstances,
        ] {
            for key in instances.keys.sorted() {
                guard let instance = instances[key],
                      dynamicIDs.insert(ObjectIdentifier(instance)).inserted else { continue }
                _ = instance.destroy()
            }
        }
        for (_, instance) in effectConstantScriptInstances.sorted(
            by: { ($0.key.passID, $0.key.uniform) < ($1.key.passID, $1.key.uniform) }
        ) where dynamicIDs.insert(ObjectIdentifier(instance)).inserted {
            _ = instance.destroy()
        }
        for key in effectVisibilityScriptInstances.keys.sorted() {
            guard let instance = effectVisibilityScriptInstances[key],
                  dynamicIDs.insert(ObjectIdentifier(instance)).inserted else { continue }
            _ = instance.destroy()
        }
    }

    var hasTransformScriptInstances: Bool {
        !dynamicOriginScriptInstances.isEmpty || !dynamicScaleScriptInstances.isEmpty
            || !dynamicAnglesScriptInstances.isEmpty || !dynamicColorScriptInstances.isEmpty
            || !particleRateScriptInstances.isEmpty
            || !effectConstantScriptInstances.isEmpty
            || !effectVisibilityScriptInstances.isEmpty
    }

    func dispatchTransformScriptUserProperties(
        _ properties: [String: WPESceneScriptPropertyValue]
    ) {
        guard !properties.isEmpty else { return }
        for (_, instance) in textScriptInstances.sorted(by: { $0.key < $1.key }) {
            _ = instance.applyUserProperties(properties)
        }
        var seen: Set<ObjectIdentifier> = []
        for instances in [
            dynamicOriginScriptInstances,
            dynamicScaleScriptInstances,
            dynamicAnglesScriptInstances,
            dynamicColorScriptInstances,
            particleRateScriptInstances,
        ] {
            for key in instances.keys.sorted() {
                guard let instance = instances[key],
                      seen.insert(ObjectIdentifier(instance)).inserted else { continue }
                _ = instance.applyUserProperties(properties)
            }
        }
        for (_, instance) in effectConstantScriptInstances.sorted(
            by: { ($0.key.passID, $0.key.uniform) < ($1.key.passID, $1.key.uniform) }
        ) where seen.insert(ObjectIdentifier(instance)).inserted {
            _ = instance.applyUserProperties(properties)
        }
        for key in effectVisibilityScriptInstances.keys.sorted() {
            guard let instance = effectVisibilityScriptInstances[key],
                  seen.insert(ObjectIdentifier(instance)).inserted else { continue }
            _ = instance.applyUserProperties(properties)
        }
        consumeSceneScriptLayerOutputs()
    }
}
#endif
