#if !LITE_BUILD
import AppKit
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import Testing

@MainActor
@Suite("Ordered scene-layer publication", .serialized)
struct WPEOrderedLayerPublicationTests {
    private nonisolated static func waitForSignal(_ semaphore: DispatchSemaphore) -> Bool {
        semaphore.wait(timeout: .now() + 5) == .success
    }

    private func makeRenderer(_ fixture: MetalSceneFixture) throws -> WPEMetalSceneRenderer {
        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor, cacheRootURL: fixture.root, dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64), device: #require(MTLCreateSystemDefaultDevice())
        )
        let token = renderer.sceneScriptLoadState.begin(generation: renderer.loadGeneration)
        let shared = WPESharedScriptState(sceneScriptLoadToken: token, layers: [
            .init(id: "102", name: "A", size: .zero, origin: .zero, index: 0, parentName: nil),
            .init(id: "101", name: "B", size: .zero, origin: .zero, index: 1, parentName: nil),
            .init(id: "100", name: "C", size: .zero, origin: .zero, index: 2, parentName: nil),
        ])
        #expect(shared.configureAuthoredLayerOrdering(ownerIDs: ["102", "101"]))
        renderer.sceneScriptSharedState = shared
        for (id, name) in [("102", "A"), ("101", "B")] {
            renderer.layerScriptInstances[id] = try WPELayerScriptInstance(script: """
                                                                           export function update(value) {
                                                                               shared.calls = (shared.calls || '') + '\(name)';
                                                                               shared['\(name)Before'] = thisScene.enumerateLayers().map(h => h.name).join('');
                                                                               thisScene.sortLayer('\(name)', 2);
                                                                               return value;
                                                                           }
                                                                           """, shared: shared, ownLayerName: name, ownObjectID: id,
                                                                           batchDispatcher: renderer.sceneScriptBatchDispatcher)
        }
        return renderer
    }

    private func finishPending(_ renderer: WPEMetalSceneRenderer) async throws {
        renderer.submitSceneScriptFrameJobs()
        renderer.pendingSceneScriptBatchJobs.removeAll()
        let completion = try #require(renderer.orderedLayerScriptBatch?.completion)
        let completed = await Task.detached { completion.wait(timeout: .now() + 5) }.value
        #expect(completed)
    }

    private func installEventOnlyOwners(_ renderer: WPEMetalSceneRenderer) throws {
        let shared = try #require(renderer.sceneScriptSharedState)
        for (id, name) in [("102", "A"), ("101", "B")] {
            renderer.layerScriptInstances[id] = try WPELayerScriptInstance(script: """
                                                                           export function cursorClick() { thisLayer.visible = false; thisLayer.alpha = 0.25; }
                                                                           """, shared: shared, ownLayerName: name, ownObjectID: id,
                                                                           batchDispatcher: renderer.sceneScriptBatchDispatcher)
        }
    }

    private func enqueueClick(_ renderer: WPEMetalSceneRenderer, id: String) async throws {
        let owner = try #require(renderer.layerScriptInstances[id])
        let job = try #require(owner.batchCursorEvents([
            .init(event: .click, pointerFrame: .neutral, runtimeSeconds: 0),
        ]))
        let completion = try #require(renderer.sceneScriptBatchDispatcher.submit([job], trackingCompletion: true))
        #expect(await Task.detached { completion.wait(timeout: .now() + 5) }.value)
    }

    @Test("Event-only owners keep cursor outputs even without any update jobs")
    func eventOnlyOutputsAreDrained() async throws {
        let fixture = try MetalSceneFixture.solidColorScene()
        defer { fixture.cleanup() }
        let renderer = try makeRenderer(fixture)
        defer { renderer.cleanup() }
        try installEventOnlyOwners(renderer)
        try await enqueueClick(renderer, id: "102")
        renderer.tickOrderedLayerScripts(time: 0, pointerFrame: .neutral)
        #expect(renderer.liveLayerVisibility["102"] == false)
        #expect(renderer.liveLayerAlpha["102"] == 0.25)
        #expect(renderer.pendingOrderedLayerScriptBatch == nil)
    }

    @Test("A stale batch cannot consume pending events from replacement owners")
    func replacementEventsSurviveStaleBatch() async throws {
        let fixture = try MetalSceneFixture.solidColorScene()
        defer { fixture.cleanup() }
        let renderer = try makeRenderer(fixture)
        defer { renderer.cleanup() }
        renderer.tickOrderedLayerScripts(time: 0, pointerFrame: .neutral)
        try await finishPending(renderer)
        let old = try #require(renderer.sceneScriptSharedState)
        renderer.loadGeneration += 1
        let token = renderer.sceneScriptLoadState.begin(generation: renderer.loadGeneration)
        let next = WPESharedScriptState(sceneScriptLoadToken: token, layers: old.layers)
        #expect(next.configureAuthoredLayerOrdering(ownerIDs: ["102", "101"]))
        renderer.sceneScriptSharedState = next
        renderer.committedAuthoredLayerOrder = next.authoredLayerOrderSnapshot()
        try installEventOnlyOwners(renderer)
        try await enqueueClick(renderer, id: "102")
        renderer.tickOrderedLayerScripts(time: 1, pointerFrame: .neutral)
        #expect(renderer.liveLayerVisibility["102"] == false)
        #expect(renderer.liveLayerAlpha["102"] == 0.25)
        #expect(next.authoredLayerOrderSnapshot().objectIDs == ["102", "101", "100"])
        #expect(old.authoredLayerOrderSnapshot().objectIDs == ["102", "101", "100"])
    }

    @Test("Nonempty output cannot replace a failed execution receipt")
    func failedExecutionReceiptVetoesPublication() async throws {
        let fixture = try MetalSceneFixture.solidColorScene()
        defer { fixture.cleanup() }
        let renderer = try makeRenderer(fixture)
        defer { renderer.cleanup() }
        renderer.tickOrderedLayerScripts(time: 0, pointerFrame: .neutral)
        let draft = try #require(renderer.pendingOrderedLayerScriptBatch)
        renderer.pendingOrderedLayerScriptBatch = .init(
            shared: draft.shared, generation: draft.generation, baseline: draft.baseline,
            requiredOwnerIDs: draft.requiredOwnerIDs, hasCompleteAdmission: true,
            completionChecks: [{ true }, { false }]
        )
        try await finishPending(renderer)
        renderer.tickOrderedLayerScripts(time: 1, pointerFrame: .neutral)
        #expect(renderer.committedAuthoredLayerOrder?.objectIDs == ["102", "101", "100"])
        #expect(renderer.sceneScriptSharedState?.authoredLayerOrderSnapshot().objectIDs == ["102", "101", "100"])
        try await finishPending(renderer)
    }

    @Test("A delayed chain keeps the last complete order and fixed authored callback traversal")
    func incompleteBatchDoesNotPublishPrefix() async throws {
        let fixture = try MetalSceneFixture.solidColorScene()
        defer { fixture.cleanup() }
        let renderer = try makeRenderer(fixture)
        defer { renderer.cleanup() }
        renderer.tickOrderedLayerScripts(time: 0, pointerFrame: .neutral)
        let gate = DispatchSemaphore(value: 0)
        let started = DispatchSemaphore(value: 0)
        let blocker = WPESceneScriptBatchDispatcher.Job(queue: DispatchQueue(label: "order-publication-test")) {
            started.signal()
            _ = gate.wait(timeout: .now() + 5)
        }
        renderer.pendingSceneScriptBatchJobs.insert(blocker, at: 1)
        renderer.submitSceneScriptFrameJobs()
        renderer.pendingSceneScriptBatchJobs.removeAll()
        let completion = try #require(renderer.orderedLayerScriptBatch?.completion)
        defer { gate.signal() }
        #expect(await Task.detached { Self.waitForSignal(started) }.value)
        #expect(renderer.sceneScriptSharedState?.authoredLayerOrderSnapshot().objectIDs == ["101", "100", "102"])
        #expect(renderer.committedAuthoredLayerOrder?.objectIDs == ["102", "101", "100"])
        #expect(renderer.frameLayerPresentation.isEmpty)
        renderer.tickOrderedLayerScripts(time: 1, pointerFrame: .neutral)
        #expect(renderer.pendingSceneScriptBatchJobs.isEmpty)
        #expect(renderer.pendingOrderedLayerScriptBatch == nil)
        #expect(renderer.sceneScriptSharedState?.get("calls") as? String == "A")
        gate.signal()
        #expect(await Task.detached { completion.wait(timeout: .now() + 5) }.value)
        renderer.tickOrderedLayerScripts(time: 2, pointerFrame: .neutral)
        #expect(renderer.sceneScriptSharedState?.get("calls") as? String == "AB")
        #expect(renderer.sceneScriptSharedState?.get("ABefore") as? String == "ABC")
        #expect(renderer.sceneScriptSharedState?.get("BBefore") as? String == "BCA")
        #expect(renderer.committedAuthoredLayerOrder?.objectIDs == ["100", "102", "101"])
        #expect(renderer.frameLayerPresentation["100"]?.sortIndex == 0)
        #expect(renderer.frameLayerPresentation["102"]?.sortIndex == 1)
        #expect(renderer.frameLayerPresentation["101"]?.sortIndex == 2)
        try await finishPending(renderer)
    }

    @Test("Partial job admission settles claims without publishing another owner's sort")
    func partialAdmissionRollsBack() async throws {
        let fixture = try MetalSceneFixture.solidColorScene()
        defer { fixture.cleanup() }
        let renderer = try makeRenderer(fixture)
        defer { renderer.cleanup() }
        let b = try #require(renderer.layerScriptInstances["101"])
        let (_, busy) = b.batchTick(runtimeSeconds: 0, consumeOutput: false)
        let busyJob = try #require(busy)
        renderer.tickOrderedLayerScripts(time: 0, pointerFrame: .neutral)
        #expect(renderer.pendingOrderedLayerScriptBatch?.hasCompleteAdmission == false)
        try await finishPending(renderer)
        renderer.tickOrderedLayerScripts(time: 1, pointerFrame: .neutral)
        #expect(renderer.committedAuthoredLayerOrder?.objectIDs == ["102", "101", "100"])
        #expect(renderer.sceneScriptSharedState?.authoredLayerOrderSnapshot().objectIDs == ["102", "101", "100"])
        #expect(renderer.frameLayerPresentation.isEmpty)
        let completion = try #require(renderer.sceneScriptBatchDispatcher.submit([busyJob], trackingCompletion: true))
        #expect(await Task.detached { completion.wait(timeout: .now() + 5) }.value)
        try await finishPending(renderer)
    }

    @Test("A failed batch restores working order but cannot publish across a replacement load", arguments: [false, true])
    func failedAndRetiredPublicationIsRejected(replacement: Bool) async throws {
        let fixture = try MetalSceneFixture.solidColorScene()
        defer { fixture.cleanup() }
        let renderer = try makeRenderer(fixture)
        defer { renderer.cleanup() }
        let shared = try #require(renderer.sceneScriptSharedState)
        renderer.tickOrderedLayerScripts(time: 0, pointerFrame: .neutral)
        try await finishPending(renderer)
        if replacement {
            renderer.loadGeneration += 1
            let token = renderer.sceneScriptLoadState.begin(generation: renderer.loadGeneration)
            let next = WPESharedScriptState(sceneScriptLoadToken: token, layers: shared.layers)
            #expect(next.configureAuthoredLayerOrdering(ownerIDs: ["102", "101"]))
            #expect(next.moveAuthoredLayer(objectID: "100", to: 0, ownerID: "102"))
            renderer.sceneScriptSharedState = next
            renderer.committedAuthoredLayerOrder = next.authoredLayerOrderSnapshot()
            renderer.layerScriptInstances.removeAll()
        } else {
            shared.sceneScriptLoadToken?.failClosed(.executionTimedOut(operation: .tick))
        }
        renderer.tickOrderedLayerScripts(time: 1, pointerFrame: .neutral)
        let expected = replacement ? ["100", "102", "101"] : ["102", "101", "100"]
        #expect(renderer.committedAuthoredLayerOrder?.objectIDs == expected)
        #expect(shared.authoredLayerOrderSnapshot().objectIDs == ["102", "101", "100"])
        if replacement {
            #expect(renderer.sceneScriptSharedState?.authoredLayerOrderSnapshot().objectIDs == expected)
        } else {
            #expect(renderer.frameLayerPresentation.isEmpty)
        }
        #expect(renderer.pendingOrderedLayerScriptBatch == nil)
    }
}
#endif
