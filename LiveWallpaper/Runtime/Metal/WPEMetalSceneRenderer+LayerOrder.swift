#if !LITE_BUILD
import Foundation
import LiveWallpaperProWPE

struct WPESceneScriptDeferredLayerProperties {
    let instance: WPELayerScriptInstance
    var values: [String: WPESceneScriptPropertyValue]
    var runtimeSeconds: Double?
}

struct WPESceneScriptOrderedLayerBatchDraft {
    let shared: WPESharedScriptState
    let generation: Int
    let baseline: WPESceneScriptLayerOrderSnapshot
    let requiredOwnerIDs: Set<String>
    let hasCompleteAdmission: Bool
    let completionChecks: [@Sendable () -> Bool]
}

struct WPESceneScriptOrderedLayerBatch {
    let draft: WPESceneScriptOrderedLayerBatchDraft
    let completion: WPESceneScriptBatchDispatcher.Completion
}

extension WPEMetalSceneRenderer {
    var hasPendingAuthoredLayerBatch: Bool {
        sceneScriptSharedState?.isAuthoredLayerOrderingEnabled == true
            && (orderedLayerScriptBatch != nil || pendingOrderedLayerScriptBatch != nil)
    }

    static func permitsSharedAuthoredLayerOrdering(
        document: WPESceneDocument,
        pipeline: WPEPreparedRenderPipeline
    ) -> Bool {
        let owners = document.imageObjects.filter { $0.visibleScript != nil }
        let names = document.imageObjects.map(\.name)
        return owners.count >= 2 && document.scriptHostObjects.isEmpty
            && document.textObjects.isEmpty && document.particleObjects.isEmpty
            && document.soundObjects.isEmpty && document.transformHostObjects.isEmpty
            && Set(names).count == names.count && !names.contains("")
            && document.imageObjects.allSatisfy {
                $0.alphaScript == nil && $0.originScript == nil && $0.scaleScript == nil
                    && $0.anglesScript == nil && $0.colorScript == nil
            }
            && pipeline.layers.allSatisfy(\.permitsIndependentImageReordering)
    }

    func tickOrderedLayerScripts(time: Double, pointerFrame: WPEPointerFrame) {
        guard let shared = sceneScriptSharedState, shared.isAuthoredLayerOrderingEnabled else { return }
        let owners = shared.layers.sorted { $0.index < $1.index }.compactMap { info in
            layerScriptInstances[info.id].map { (info.id, $0) }
        }
        for (_, instance) in owners {
            instance.observeBatchTickDeadline()
        }
        if let batch = orderedLayerScriptBatch {
            let draft = batch.draft
            if draft.shared !== shared || draft.generation != loadGeneration {
                orderedLayerScriptBatch = nil
                draft.shared.restoreAuthoredLayerOrder(draft.baseline)
            } else {
                if sceneScriptLoadState.currentFailureReason != nil {
                    shared.restoreAuthoredLayerOrder(draft.baseline)
                }
                guard batch.completion.isComplete else { return }
                orderedLayerScriptBatch = nil
                var outputs: [String: WPELayerScriptOutput] = [:]
                for (id, instance) in owners {
                    if let output = instance.takeCompletedBatchOutput() {
                        outputs[id] = output
                    }
                }
                let isComplete = draft.hasCompleteAdmission && draft.completionChecks.count == draft.requiredOwnerIDs.count
                    && draft.completionChecks.allSatisfy { $0() } && draft.requiredOwnerIDs.isSubset(of: Set(outputs.keys))
                let committed = isComplete && sceneScriptLoadState.withCurrentCompletionPermission {
                    committedAuthoredLayerOrder = shared.authoredLayerOrderSnapshot()
                    for (id, _) in owners {
                        if let output = outputs[id] {
                            applyLayerScriptOutput(output, ownObjectID: id)
                        }
                    }
                }
                if !committed {
                    draft.shared.restoreAuthoredLayerOrder(draft.baseline)
                }
            }
        }
        guard sceneScriptLoadState.currentFailureReason == nil else { return }
        applySceneScriptGeneralSettingsIfChanged()
        if let size = pendingOrderedLayerResize {
            pendingOrderedLayerResize = nil
            dispatchSceneScriptResizeScreen(size)
        }
        let properties = pendingOrderedLayerProperties
        pendingOrderedLayerProperties.removeAll()
        for (id, instance) in owners {
            if let pending = properties[id], pending.instance === instance {
                if let output = applyScriptUserProperties(instance, pending.values, runtimeSeconds: pending.runtimeSeconds) {
                    applyLayerScriptOutput(output, ownObjectID: id)
                }
            }
        }
        guard sceneScriptLoadState.currentFailureReason == nil else { return }
        if committedAuthoredLayerOrder == nil {
            committedAuthoredLayerOrder = shared.authoredLayerOrderSnapshot()
        }
        // Event-only owners have no update jobs to complete. Their non-order
        // writes still use the existing outcome slot and must be drained.
        for (id, instance) in owners {
            if let output = instance.takeCompletedBatchOutput() {
                applyLayerScriptOutput(output, ownObjectID: id)
            }
        }
        let baseline = shared.authoredLayerOrderSnapshot()
        let required = Set(owners.filter(\.1.hasFrameUpdate).map(\.0))
        var admitted: Set<String> = []
        var checks: [@Sendable () -> Bool] = []
        for (id, instance) in owners where instance.hasFrameUpdate {
            let (_, job) = instance.batchTick(runtimeSeconds: time, pointerFrame: pointerFrame, consumeOutput: false)
            if let job {
                pendingSceneScriptBatchJobs.append(job)
                admitted.insert(id)
                if let check = job.completionIsValid {
                    checks.append(check)
                }
            }
        }
        if admitted == required {
            let events = mediaEventMailbox?.drain() ?? []
            let mediaJobs = owners.compactMap { _, instance in
                instance.batchMediaEvents(events, runtimeSeconds: time)
            }
            pendingSceneScriptBatchJobs.insert(contentsOf: mediaJobs, at: 0)
        }
        guard !required.isEmpty else { return }
        // Even partial admission owns claimed slots: settle its jobs, then roll
        // back rather than exposing a prefix of the scene's callback chain.
        pendingOrderedLayerScriptBatch = .init(shared: shared, generation: loadGeneration,
                                               baseline: baseline, requiredOwnerIDs: required,
                                               hasCompleteAdmission: admitted == required, completionChecks: checks)
    }

    func submitSceneScriptFrameJobs() {
        if let draft = pendingOrderedLayerScriptBatch {
            let completion = sceneScriptBatchDispatcher.submit(pendingSceneScriptBatchJobs,
                                                               trackingCompletion: true, order: .submissionOrder)!
            orderedLayerScriptBatch = .init(draft: draft, completion: completion)
            pendingOrderedLayerScriptBatch = nil
            #if DEBUG
            lastOracleSceneScriptBatchCompletion = completion
            #endif
            return
        }
        #if DEBUG
        if let batch = orderedLayerScriptBatch, pendingSceneScriptBatchJobs.isEmpty {
            lastOracleSceneScriptBatchCompletion = batch.completion
            return
        }
        #endif
        #if DEBUG
        lastOracleSceneScriptBatchCompletion = sceneScriptBatchDispatcher.submit(
            pendingSceneScriptBatchJobs, trackingCompletion: WPEOracleMode.isEnabled,
            order: WPEOracleMode.isEnabled ? oracleSceneScriptBatchOrder : .parallelWorkers
        )
        #else
        sceneScriptBatchDispatcher.submit(pendingSceneScriptBatchJobs)
        #endif
    }

    var frameLayerPresentation: [String: WPELayerScriptPresentationMutation] {
        guard let order = committedAuthoredLayerOrder, order.hasOverride else { return liveLayerPresentation }
        var presentation = liveLayerPresentation
        for (index, id) in order.objectIDs.enumerated() {
            presentation[id, default: .init()].sortIndex = index
        }
        return presentation
    }
}
#endif
