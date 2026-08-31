#if !LITE_BUILD
    import Foundation
    import LiveWallpaperCore
    import LiveWallpaperProWPE

    extension WPEMetalSceneRenderer {
        // MARK: - Script Tick Dispatch

        static func currentSceneScriptLanguage() -> String {
            AppLanguagePreference.current(in: .appScoped()).wallpaperEngineLanguageCode()
        }

        /// The same defaults domain drives SwiftUI's `@AppStorage` language
        /// picker. Foundation posts `didChangeNotification` for in-process
        /// writes; locale changes cover the `.system` preference. Both flow
        /// through the actor's FIFO config channel and are de-duplicated there.
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

        /// Official initial-full contract. Language is currently the complete
        /// documented settings bag; future keys must be added here, not inferred
        /// from the HTML wallpaper listener.
        func applyInitialSceneScriptGeneralSettings() {
            dispatchSceneScriptGeneralSettings(
                language: sceneScriptGeneralSettings.takeInitialLanguage()
            )
        }

        /// Subsequent contract: emit only when the language key changed. Every
        /// JS call receives a fresh plain object with its own `language` property,
        /// so authored `hasOwnProperty('language')` checks behave exactly as in WPE.
        func applySceneScriptGeneralSettingsIfChanged() {
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
                    liveTextAlpha[objectID] = output.own.alpha
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
        }

        // Each family applies its newest completed value and contributes its next
        // tick to this frame's batch; `renderCurrentFrame` submits the batch once,
        // so a scene's script count costs dispatches only up to the worker width.

        func tickLayerScript(
            _ instance: WPELayerScriptInstance,
            runtimeSeconds: Double,
            pointerFrame: WPEPointerFrame
        ) -> WPELayerScriptOutput? {
            let (output, job) = instance.batchTick(
                runtimeSeconds: runtimeSeconds,
                pointerFrame: pointerFrame
            )
            if let job { pendingSceneScriptBatchJobs.append(job) }
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
            if let job { pendingSceneScriptBatchJobs.append(job) }
            return value
        }

        func tickTextScript(
            _ instance: WPESceneScriptInstance,
            runtimeSeconds: Double
        ) -> String {
            let (value, job) = instance.batchTickString(runtimeSeconds: runtimeSeconds)
            if let job { pendingSceneScriptBatchJobs.append(job) }
            return value
        }

        /// Cursor events fire inside the frame path, so they are enqueued
        /// fire-and-forget: the handler's output drains through the next frame's
        /// tick (`batchTick` takes it off `asyncOutcomeSlot`), and the frame never
        /// waits on a script engine. Returning nothing is the point — an optional
        /// return here reads like the caller can apply the output in the same frame.
        func dispatchScriptCursorEvent(
            _ instance: WPELayerScriptInstance,
            event: WPELayerScriptCursorEvent,
            pointerFrame: WPEPointerFrame,
            runtimeSeconds: Double
        ) {
            instance.liveDispatchCursorEvent(
                event,
                pointerFrame: pointerFrame,
                runtimeSeconds: runtimeSeconds
            )
        }

        /// Drains this scene's media mailbox onto every script that exported a handler. The
        /// mailbox is empty on all but a handful of frames per song (the diff gate only posts
        /// when a field moved), so a media scene costs one lock-protected `isEmpty` check per
        /// frame. Layer scripts go through the fire-and-forget path like cursor events; text scripts are bounded-synchronous (no event lane).
        func drainMediaEvents(runtimeSeconds: Double) {
            guard let events = mediaEventMailbox?.drain(), !events.isEmpty else { return }
            // The whole drain goes to each instance as ONE batch: dispatched
            // per event, the single in-flight async slot admitted the first and
            // silently dropped the rest of a cold-start burst.
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
            // Text is bounded-synchronous (no event lane, nothing to drop).
            for event in events {
                for instance in textScriptInstances.values {
                    instance.dispatchMediaEvent(event, runtimeSeconds: runtimeSeconds)
                }
            }
            // The dynamic-transform runtime hosts origin/scale/angles/color
            // and the effect constant/visibility slots — where the corpus
            // actually binds its media-driven scale, position and tint.
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
            return instance.applyUserPropertiesSuperseding(
                properties,
                runtimeSeconds: runtimeSeconds
            )
        }

        /// The surface owns the only real screen-size producer. This is called
        /// only after `updateSurfaceGeometry` accepts a positive changed size;
        /// construction merely seeds `engine.screenResolution` and never emits
        /// the startup event prohibited by WPE's contract.
        func dispatchSceneScriptResizeScreen(_ size: SIMD2<Double>) {
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
                    liveTextAlpha[objectID] = output.own.alpha
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
        }

        /// Delivers `destroy()` synchronously on each instance lane before the
        /// dictionaries release their JSContexts. ObjectIdentifier de-duplicates
        /// defensive aliases, while every instance also owns a one-way latch.
        func destroySceneScriptInstances() {
            var layerIDs = Set<ObjectIdentifier>()
            for instances in [
                layerScriptInstances,
                layerAlphaScriptInstances,
                textVisibleScriptInstances,
                textAlphaScriptInstances,
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
                || !effectConstantScriptInstances.isEmpty
                || !effectVisibilityScriptInstances.isEmpty
        }

        /// The transform families' counterpart to the layer/text fan-out. The handler
        /// only mutates module state — 3146703458's scale script assigns `speed` there
        /// and nowhere else — so the next tick publishes the corrected value and
        /// nothing is applied here. De-duplicated by identity because one instance can
        /// sit in several tables.
        func dispatchTransformScriptUserProperties(
            _ properties: [String: WPESceneScriptPropertyValue]
        ) {
            guard !properties.isEmpty else { return }
            var seen: Set<ObjectIdentifier> = []
            for instances in [
                dynamicOriginScriptInstances,
                dynamicScaleScriptInstances,
                dynamicAnglesScriptInstances,
                dynamicColorScriptInstances,
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
        }
    }
#endif
