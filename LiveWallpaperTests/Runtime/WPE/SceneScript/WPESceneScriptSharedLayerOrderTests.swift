import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Testing

@Suite(.serialized)
@MainActor
struct WPESceneScriptSharedLayerOrderTests {
    private func state(token: WPESceneScriptInstanceLimitToken? = nil) -> WPESharedScriptState {
        WPESharedScriptState(sceneScriptLoadToken: token, layers: [
            .init(id: "102", name: "A", size: .zero, origin: .zero, index: 0, parentName: nil,
                  initialConfiguration: .object(["name": .string("A"), "marker": .string("A")])),
            .init(id: "101", name: "B", size: .zero, origin: .zero, index: 1, parentName: nil,
                  initialConfiguration: .object(["name": .string("B"), "marker": .string("B")])),
            .init(id: "100", name: "C", size: .zero, origin: .zero, index: 2, parentName: nil,
                  initialConfiguration: .object(["name": .string("C"), "marker": .string("C")])),
        ])
    }

    @Test("Oracle inputs update the VM bag without callbacks and cannot cross retired loads")
    func oracleInputBagReceipts() throws {
        let token = WPESceneScriptInstanceLimitToken(generation: 40)
        let shared = state(token: token)
        let script = """
        export function update(value) {
            shared.stage = engine.userProperties.stage;
            shared.label = engine.userProperties.label;
            shared.enabled = engine.userProperties.enabled;
            return value;
        }
        """
        let instance = try WPELayerScriptInstance(script: script, shared: shared, ownLayerName: "A", ownObjectID: "102")
        #expect(!instance.handlesUserProperties)
        for stage in [0.0, 1, 2, 0] {
            let input: [String: WPESceneScriptPropertyValue] = [
                "stage": .number(stage), "label": .string("step-\(stage)"), "enabled": .bool(stage != 0),
            ]
            #expect(instance.injectOracleUserProperties(input) == input)
            _ = try #require(instance.tick())
            #expect(shared.get("stage") as? Double == stage)
            #expect(shared.get("label") as? String == "step-\(stage)")
            #expect(shared.get("enabled") as? Bool == (stage != 0))
        }
        let callbacks = try WPELayerScriptInstance(script: """
        export function applyUserProperties(properties) { shared.callbackRan = true; }
        export function update(value) { return value; }
        """, shared: shared, ownLayerName: "B", ownObjectID: "101")
        #expect(callbacks.injectOracleUserProperties(["stage": .number(9)]) == ["stage": .number(9)])
        #expect(shared.get("callbackRan") == nil)
        token.retire()
        #expect(instance.injectOracleUserProperties(["stage": .number(99)]) == nil)
        let replacement = state(token: WPESceneScriptInstanceLimitToken(generation: 41))
        let fresh = try WPELayerScriptInstance(script: script, shared: replacement, ownLayerName: "A", ownObjectID: "102")
        #expect(fresh.injectOracleUserProperties(["stage": .number(7)]) == ["stage": .number(7)])
        _ = try #require(fresh.tick())
        #expect(replacement.get("stage") as? Double == 7)
        #expect(shared.get("stage") as? Double == 0)
        _ = fresh.destroy()
        #expect(fresh.injectOracleUserProperties(["stage": .number(8)]) == nil)
    }

    @Test("Shared order is an admitted identity projection with isolated rollback")
    func admittedOrderAndRollback() {
        let shared = state()
        #expect(!shared.isAuthoredLayerOrderingEnabled)
        #expect(!shared.configureAuthoredLayerOrdering(ownerIDs: ["102"]))
        #expect(!shared.configureAuthoredLayerOrdering(ownerIDs: ["102", "missing"]))
        #expect(shared.configureAuthoredLayerOrdering(ownerIDs: ["102", "101"]))
        #expect(!shared.configureAuthoredLayerOrdering(ownerIDs: ["102", "101"]))
        let initial = shared.authoredLayerOrderSnapshot()
        #expect(!shared.moveAuthoredLayer(objectID: "102", to: 2, ownerID: "100"))
        #expect(!shared.moveAuthoredLayer(objectID: "missing", to: 2, ownerID: "102"))
        #expect(!shared.moveAuthoredLayer(objectID: "102", to: 3, ownerID: "102"))
        #expect(shared.authoredLayerOrderSnapshot() == initial)
        #expect(shared.moveAuthoredLayer(objectID: "102", to: 2, ownerID: "102"))
        let moved = shared.authoredLayerOrderSnapshot()
        #expect(moved.objectIDs == ["101", "100", "102"])
        #expect(moved.hasOverride && moved.revision > initial.revision)
        #expect(shared.layers.map(\.name) == ["A", "B", "C"])
        #expect(shared.orderedLayerInfos().map(\.name) == ["B", "C", "A"])
        #expect(shared.moveAuthoredLayer(objectID: "102", to: 2, ownerID: "101"))
        #expect(shared.authoredLayerOrderSnapshot() == moved)
        #expect(!state().restoreAuthoredLayerOrder(moved))
        #expect(shared.restoreAuthoredLayerOrder(initial))
        let restored = shared.authoredLayerOrderSnapshot()
        #expect(restored.objectIDs == initial.objectIDs && !restored.hasOverride)
        #expect(restored.revision > moved.revision)
    }

    @Test("Oracle gate input receipts precede real boolean ticks and isolate retired loads")
    func oracleEffectGateInputReceipts() throws {
        let token = WPESceneScriptInstanceLimitToken(generation: 50)
        let shared = state(token: token)
        let script = """
        export function applyUserProperties(properties) { shared.callbackRan = true; }
        export function update(value) {
            shared.tickCount = Number(shared.tickCount || 0) + 1;
            return (Number(engine.userProperties.stage) & 1) === 0;
        }
        """
        let instance = try WPEDynamicTransformScriptInstance(
            script: script, seed: .zero, valueShape: .boolean, canvasSize: [256, 128], shared: shared
        )
        for (index, stage) in [1.0, 0, 2, 1].enumerated() {
            let input: [String: WPESceneScriptPropertyValue] = ["stage": .number(stage)]
            #expect(instance.injectOracleUserProperties(input) == input)
            #expect((shared.get("tickCount") as? Double ?? 0) == Double(index))
            #expect(shared.get("callbackRan") == nil)
            let result = instance.tick(pointerPosition: .zero)
            #expect(result == SIMD3<Double>(repeating: stage == 1 ? 0 : 1))
        }
        token.retire()
        #expect(instance.injectOracleUserProperties(["stage": .number(0)]) == nil)
        #expect(instance.tick(pointerPosition: .zero) == nil)
        let replacement = state(token: WPESceneScriptInstanceLimitToken(generation: 51))
        let fresh = try WPEDynamicTransformScriptInstance(
            script: script, seed: .zero, valueShape: .boolean, canvasSize: [256, 128], shared: replacement
        )
        #expect(fresh.injectOracleUserProperties(["stage": .number(0)]) == ["stage": .number(0)])
        #expect(fresh.tick(pointerPosition: .zero) == SIMD3<Double>(repeating: 1))
        #expect(shared.get("tickCount") as? Double == 4)
        fresh.destroy()
        #expect(fresh.injectOracleUserProperties(["stage": .number(1)]) == nil)
    }

    @Test("Oracle gate injection respects admission deadline without evaluating a refused input")
    func oracleEffectGateInputBudget() throws {
        let governor = WPESceneScriptExecutionGovernor(limit: 1)
        let shared = state()
        let instance = try WPEDynamicTransformScriptInstance(
            script: "export function update(value) { shared.stage = engine.userProperties.stage; return value; }",
            seed: .zero, valueShape: .boolean, canvasSize: [256, 128], shared: shared,
            tickBudget: 0.05, governor: governor
        )
        let participant = governor.makeParticipant()
        let permit = try #require(governor.tryAcquireUnreserved(for: participant))
        #expect(instance.injectOracleUserProperties(["stage": .number(99)]) == nil)
        #expect(shared.get("stage") == nil)
        permit.release()
        #expect(instance.injectOracleUserProperties(["stage": .number(1)]) == ["stage": .number(1)])
        _ = instance.tick(pointerPosition: .zero)
        #expect(shared.get("stage") as? Double == 1)
    }

    @Test("Failed and retired loads cannot mutate a restored order or a replacement load")
    func completionPermissionFencesLateMutation() {
        let token = WPESceneScriptInstanceLimitToken(generation: 4)
        let shared = state(token: token)
        #expect(shared.configureAuthoredLayerOrdering(ownerIDs: ["102", "101"]))
        let initial = shared.authoredLayerOrderSnapshot()
        #expect(shared.moveAuthoredLayer(objectID: "102", to: 2, ownerID: "102"))
        token.failClosed(.executionTimedOut(operation: .tick))
        #expect(shared.restoreAuthoredLayerOrder(initial))
        let restored = shared.authoredLayerOrderSnapshot()
        #expect(!shared.moveAuthoredLayer(objectID: "101", to: 2, ownerID: "101"))
        #expect(shared.authoredLayerOrderSnapshot() == restored)
        let replacementToken = WPESceneScriptInstanceLimitToken(generation: 5)
        let replacement = state(token: replacementToken)
        #expect(replacement.configureAuthoredLayerOrdering(ownerIDs: ["102", "101"]))
        #expect(!replacement.restoreAuthoredLayerOrder(restored))
        replacementToken.retire()
        #expect(!replacement.moveAuthoredLayer(objectID: "102", to: 2, ownerID: "102"))
        let retired = state(token: replacementToken)
        #expect(!retired.configureAuthoredLayerOrdering(ownerIDs: ["102", "101"]))
    }

    private func script(owner: String) -> String {
        """
        const owner = '\(owner)';
        const names = ['A','B','C'];
        let handles;
        let previous = -1;
        function identity(handle) { return names[handles.indexOf(handle)] || '?'; }
        function key(value) { return thisScene.getInitialLayerConfig(value).marker; }
        function snapshot() {
            const numeric = [thisScene.getLayer(0),thisScene.getLayer(1),thisScene.getLayer(2)];
            const all = thisScene.enumerateLayers();
            return [handles.map(h => thisScene.getLayerIndex(h)).join(','),
                    names.map(n => thisScene.getLayerIndex(n)).join(','),
                    numeric.map(identity).join(''),all.map(identity).join(''),all.map(key).join(''),
                    names.map(n => identity(thisScene.getLayer(n))).join(''),
                    names.map(key).join(''),handles.map(key).join(''),[0,1,2].map(key).join('')].join('|');
        }
        export function init(value) { handles = names.map(n => thisScene.getLayer(n)); return value; }
        export function update(value) {
            const stage = Number(shared.stage);
            if (stage !== previous) {
                previous = stage;
                shared[owner + 'Before'] = snapshot();
                let success;
                if (stage === 0) success = thisScene.sortLayer(handles[0],0) && thisScene.sortLayer('B',1);
                else success = thisScene.sortLayer(owner === 'A' ? handles[0] : 'B',
                    owner === 'A' ? (stage === 1 ? 2 : 1) : (stage === 1 ? 0 : 2));
                shared[owner + 'Success'] = success;
                shared[owner + 'Immediate'] = snapshot();
            }
            shared[owner + 'Settled'] = snapshot();
            return value;
        }
        """
    }

    private func snapshot(_ order: String) -> String {
        let names = Array("ABC")
        let orderNames = Array(order)
        let indices = names.map { String(orderNames.firstIndex(of: $0)!) }.joined(separator: ",")
        return [indices, indices, order, order, order, "ABC", "ABC", "ABC", order].joined(separator: "|")
    }

    @Test("Two visible owners match Windows immediate identity and stage restoration with reversed IDs")
    func twoOwnersMatchWindowsOrderingIdentity() throws {
        let shared = state()
        #expect(shared.configureAuthoredLayerOrdering(ownerIDs: ["102", "101"]))
        let a = try WPELayerScriptInstance(script: script(owner: "A"), shared: shared, ownLayerName: "A", ownObjectID: "102")
        let b = try WPELayerScriptInstance(script: script(owner: "B"), shared: shared, ownLayerName: "B", ownObjectID: "101")
        let stages = [(0, "ABC", "ABC", "ABC"), (1, "ABC", "BCA", "BCA"),
                      (2, "BCA", "BAC", "ACB"), (0, "ACB", "ABC", "ABC")]
        for (stage, before, intermediate, settled) in stages {
            shared.set("stage", stage)
            let aOutput = try #require(a.tick())
            let bOutput = try #require(b.tick())
            #expect(shared.get("ABefore") as? String == snapshot(before))
            #expect(shared.get("AImmediate") as? String == snapshot(intermediate))
            #expect(shared.get("BBefore") as? String == snapshot(intermediate))
            #expect(shared.get("BImmediate") as? String == snapshot(settled))
            #expect(shared.get("ASuccess") as? Bool == true)
            #expect(shared.get("BSuccess") as? Bool == true)
            #expect(aOutput.presentation.values.allSatisfy { $0.sortIndex == nil })
            #expect(bOutput.presentation.values.allSatisfy { $0.sortIndex == nil })
            _ = try #require(a.tick())
            _ = try #require(b.tick())
            #expect(shared.get("ASettled") as? String == snapshot(settled))
            #expect(shared.get("BSettled") as? String == snapshot(settled))
        }
    }

    @Test("Only visible init/update may mutate shared order, and creation stays outside admission")
    func callbackPhaseAndCreatedLayerBoundaries() throws {
        let shared = state()
        #expect(shared.configureAuthoredLayerOrdering(ownerIDs: ["102", "101"]))
        let instance = try WPELayerScriptInstance(script: """
        shared.topLevelRejected = !thisScene.sortLayer('A',2);
        function reject(key) { shared[key] = !thisScene.sortLayer('C',2); }
        export function init(value) {
            shared.initAllowed = thisScene.sortLayer('A',2);
            shared.createRejected = thisScene.createLayer('models/bar.json') == null;
            return value;
        }
        export function update(value) { shared.updateAllowed = thisScene.sortLayer('B',2); return value; }
        export function applyUserProperties(properties) { reject('propertiesRejected'); }
        export function applyGeneralSettings(settings) { reject('generalRejected'); }
        export function resizeScreen(size) { reject('resizeRejected'); }
        export function cursorClick(event) { reject('cursorRejected'); }
        export function mediaPlaybackChanged(event) { reject('mediaRejected'); }
        export function destroy() { reject('destroyRejected'); }
        """, shared: shared, ownLayerName: "A", ownObjectID: "102")
        _ = try #require(instance.tick())
        let accepted = shared.authoredLayerOrderSnapshot()
        _ = try #require(instance.applyUserProperties(["stage": .number(1)]))
        _ = try #require(instance.applyGeneralSettings(language: "en"))
        _ = try #require(instance.resizeScreen(SIMD2(100, 80)))
        _ = try #require(instance.dispatchCursorEvent(.click, pointerFrame: .neutral))
        instance.liveDispatchMediaEvents([.playbackChanged(.playing)])
        _ = try #require(instance.destroy())
        for key in ["topLevelRejected", "initAllowed", "createRejected", "updateAllowed", "propertiesRejected",
                    "generalRejected", "resizeRejected", "cursorRejected", "mediaRejected", "destroyRejected"] {
            #expect(shared.get(key) as? Bool == true, "\(key)")
        }
        #expect(shared.authoredLayerOrderSnapshot() == accepted)
        let alpha = try WPELayerScriptInstance(script: """
        export function init(value) { shared.alphaRejected = !thisScene.sortLayer('A',0); return value; }
        """, shared: shared, outputMode: .returnedAlpha(initialValue: 1), ownLayerName: "A", ownObjectID: "102")
        #expect(shared.get("alphaRejected") as? Bool == true)
        #expect(alpha.initialOutput.created.isEmpty)
        #expect(shared.authoredLayerOrderSnapshot() == accepted)
    }

    @Test("Transform and text numeric queries see shared order without changing named identity")
    func otherFamiliesObserveCurrentOrder() throws {
        let shared = state()
        #expect(shared.configureAuthoredLayerOrdering(ownerIDs: ["102", "101"]))
        #expect(shared.moveAuthoredLayer(objectID: "102", to: 2, ownerID: "102"))
        let script = """
        export function init(value) {
            shared.query = thisScene.getInitialLayerConfig(0).marker === 'B' &&
                thisScene.getInitialLayerConfig(thisScene.getLayer(0)).marker === 'B' &&
                thisScene.getInitialLayerConfig('A').marker === 'A';
            return value;
        }
        """
        _ = try WPEDynamicTransformScriptInstance(script: script, seed: .zero, canvasSize: SIMD2(256, 128),
                                                  ownLayerName: "A", ownObjectID: "102", shared: shared)
        #expect(shared.get("query") as? Bool == true)
        shared.set("query", false)
        _ = try WPESceneScriptInstance(script: script, initialValue: "seed", shared: shared)
        #expect(shared.get("query") as? Bool == true)
    }

    @Test("Ordered batch APIs retain outputs until the complete submitted chain is drained")
    func completedBatchOutputIsExplicitlyDrained() throws {
        let shared = state()
        #expect(shared.configureAuthoredLayerOrdering(ownerIDs: ["102", "101"]))
        shared.set("stage", 2)
        let dispatcher = WPESceneScriptBatchDispatcher(width: 2)
        let a = try WPELayerScriptInstance(script: script(owner: "A"), shared: shared,
                                           ownLayerName: "A", ownObjectID: "102", batchDispatcher: dispatcher)
        let b = try WPELayerScriptInstance(script: script(owner: "B"), shared: shared,
                                           ownLayerName: "B", ownObjectID: "101", batchDispatcher: dispatcher)
        #expect(a.hasFrameUpdate && b.hasFrameUpdate)
        let aBatch = a.batchTick(consumeOutput: false)
        let bBatch = b.batchTick(consumeOutput: false)
        #expect(aBatch.output == nil && bBatch.output == nil)
        let jobs = try [#require(aBatch.job), #require(bBatch.job)]
        #expect(jobs.allSatisfy { $0.completionIsValid?() == false })
        let completion = try #require(dispatcher.submit(jobs, trackingCompletion: true, order: .submissionOrder))
        #expect(completion.wait(timeout: .now() + 5))
        #expect(jobs.allSatisfy { $0.completionIsValid?() == true })
        a.observeBatchTickDeadline()
        b.observeBatchTickDeadline()
        #expect(a.takeCompletedBatchOutput() != nil)
        #expect(b.takeCompletedBatchOutput() != nil)
        #expect(a.takeCompletedBatchOutput() == nil && b.takeCompletedBatchOutput() == nil)
        #expect(shared.get("AImmediate") as? String == shared.get("BBefore") as? String)
        #expect(shared.orderedLayerInfos().map(\.name) == ["A", "C", "B"])
    }

    @Test("Deferred shared-order cursor and media events stay pending until an admitted chain")
    func deferredEventsAndBusyCursorRemainPending() throws {
        let shared = state()
        #expect(shared.configureAuthoredLayerOrdering(ownerIDs: ["102", "101"]))
        let dispatcher = WPESceneScriptBatchDispatcher(width: 1)
        let instance = try WPELayerScriptInstance(script: """
        export function init() { shared.mediaCalls = 0; shared.cursorCalls = 0; }
        export function mediaPlaybackChanged() { shared.mediaCalls++; }
        export function cursorClick() { shared.cursorCalls++; }
        """, shared: shared, ownLayerName: "A", ownObjectID: "102", batchDispatcher: dispatcher)
        #expect(instance.batchMediaEvents([.playbackChanged(.paused)], allowSubmission: false) == nil)
        #expect(instance.batchCursorEvents([.init(event: .click, pointerFrame: .neutral, runtimeSeconds: 0)], allowSubmission: false) == nil)
        #expect(shared.get("mediaCalls") as? Double == 0)
        #expect(shared.get("cursorCalls") as? Double == 0)

        // Media admission reserves safety now; executing the cursor first must
        // defer its untouched inbox rather than retry outside the ordered chain.
        let media = try #require(instance.batchMediaEvents([.playbackChanged(.playing)]))
        #expect(instance.batchMediaEvents([.playbackChanged(.paused)]) == nil)
        let refusedCursor = try #require(instance.batchCursorEvents([]))
        let first = try #require(dispatcher.submit([refusedCursor, media], trackingCompletion: true, order: .submissionOrder))
        #expect(first.wait(timeout: .now() + 5))
        #expect(shared.get("mediaCalls") as? Double == 1)
        #expect(shared.get("cursorCalls") as? Double == 0)
        let pendingMedia = try #require(instance.batchMediaEvents([]))
        let retry = try #require(instance.batchCursorEvents([]))
        let second = try #require(dispatcher.submit([pendingMedia, retry], trackingCompletion: true, order: .submissionOrder))
        #expect(second.wait(timeout: .now() + 5))
        #expect(shared.get("mediaCalls") as? Double == 2)
        #expect(shared.get("cursorCalls") as? Double == 1)
        #expect(instance.batchMediaEvents([]) == nil)
        #expect(instance.batchCursorEvents([]) == nil)
    }

    @Test("Media and cursor queries bracket the complete shared-order update chain")
    func eventQueriesSeeCompleteOrders() throws {
        let shared = state()
        #expect(shared.configureAuthoredLayerOrdering(ownerIDs: ["102", "101"]))
        shared.set("stage", 2)
        let dispatcher = WPESceneScriptBatchDispatcher(width: 2)
        let a = try WPELayerScriptInstance(script: script(owner: "A") + """

        export function mediaPlaybackChanged() {
            shared.mediaOrder = thisScene.enumerateLayers().map(layer => layer.name).join('');
        }
        """, shared: shared, ownLayerName: "A", ownObjectID: "102", batchDispatcher: dispatcher)
        let b = try WPELayerScriptInstance(script: script(owner: "B") + """

        export function cursorClick() {
            shared.cursorOrder = thisScene.enumerateLayers().map(layer => layer.name).join('');
        }
        """, shared: shared, ownLayerName: "B", ownObjectID: "101", batchDispatcher: dispatcher)
        let media = try #require(a.batchMediaEvents([.playbackChanged(.playing)]))
        let updateA = try #require(a.batchTick(consumeOutput: false).job)
        let updateB = try #require(b.batchTick(consumeOutput: false).job)
        let cursor = try #require(b.batchCursorEvents([.init(event: .click, pointerFrame: .neutral, runtimeSeconds: 0)]))
        let completion = try #require(dispatcher.submit(
            [media, updateA, updateB, cursor], trackingCompletion: true, order: .submissionOrder
        ))
        #expect(completion.wait(timeout: .now() + 5))
        #expect(updateA.completionIsValid?() == true && updateB.completionIsValid?() == true)
        #expect(shared.get("mediaOrder") as? String == "ABC")
        #expect(shared.get("cursorOrder") as? String == "ACB")
    }

    @Test("Old event output and rejected ticks cannot forge a successful tick receipt")
    func completedTickReceiptExcludesEventsAndRejection() throws {
        let slot = WPESceneScriptOutcomeSlot<Int>()
        slot.publishEvent(7)
        let rejected = try #require(slot.beginTick())
        #expect(!slot.didComplete(rejected))
        #expect(slot.rejectTick(rejected))
        #expect(slot.takeLatest() == 7)
        #expect(!slot.didComplete(rejected))

        let completed = try #require(slot.beginTick())
        slot.publishEvent(8)
        #expect(!slot.didComplete(completed))
        #expect(slot.supersede(with: 9) == 9)
        #expect(!slot.didComplete(completed))
        #expect(slot.publishTick(10, for: completed))
        #expect(slot.didComplete(completed))
        #expect(slot.takeLatest() == 10)
        #expect(slot.didComplete(completed))
        #expect(!slot.publishTick(11, for: rejected))
        #expect(!slot.didComplete(rejected))
        #expect(slot.didComplete(completed))

        let pending = try #require(slot.beginTick())
        slot.publishEvent(12)
        #expect(!slot.didComplete(pending))
        #expect(slot.rejectTick(pending))
        #expect(!slot.didComplete(pending))
        #expect(slot.takeLatest() == 12)
    }
}
