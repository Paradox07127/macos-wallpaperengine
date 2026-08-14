#if !LITE_BUILD
    import Foundation
    import LiveWallpaperProWPE

    extension WPEMetalSceneRenderer {
        // MARK: - Script Tick Dispatch

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
    }
#endif
