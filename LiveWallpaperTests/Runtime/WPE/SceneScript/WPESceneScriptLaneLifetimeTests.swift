#if !LITE_BUILD
import Foundation
import JavaScriptCore
@testable import LiveWallpaper
import Testing

struct WPESceneScriptLaneLifetimeTests {
    private final class WeakVM {
        weak var value: JSVirtualMachine?

        init(_ value: JSVirtualMachine) {
            self.value = value
        }
    }

    private func reserveWithoutKeepingLane(
        _ dispatcher: WPESceneScriptBatchDispatcher
    ) -> (DispatchQueue, WeakVM) {
        autoreleasepool {
            let lane = dispatcher.reserveLane()
            return (lane.queue, WeakVM(lane.virtualMachine))
        }
    }

    @Test("Unused script lanes allocate no VM and reservations preserve round-robin sharing")
    func lanesAllocateOnDemand() {
        let dispatcher = WPESceneScriptBatchDispatcher(width: 2)
        #expect(dispatcher.allocatedLaneCountForTesting == 0)
        let first = dispatcher.reserveLane()
        #expect(dispatcher.allocatedLaneCountForTesting == 1)
        let second = dispatcher.reserveLane()
        #expect(dispatcher.allocatedLaneCountForTesting == 2)
        let third = dispatcher.reserveLane()
        #expect(first.virtualMachine !== second.virtualMachine)
        #expect(first.virtualMachine === third.virtualMachine)
        #expect(first.queue === third.queue)
    }

    @Test("Scene retirement releases unused VMs even while the dispatcher stays alive")
    func retirementReleasesVM() {
        let dispatcher = WPESceneScriptBatchDispatcher(width: 1)
        let (queue, vm) = reserveWithoutKeepingLane(dispatcher)
        #expect(vm.value != nil)
        dispatcher.releaseLanesForSceneRetirement()
        #expect(dispatcher.allocatedLaneCountForTesting == 0)
        queue.sync {}
        #expect(vm.value == nil)
        withExtendedLifetime(dispatcher) {}
    }

    @Test("Retirement leaves live engines usable and old invalidations cannot evict new lanes")
    func retirementPreservesOutstandingLane() {
        let dispatcher = WPESceneScriptBatchDispatcher(width: 1)
        let original = dispatcher.reserveLane()
        dispatcher.releaseLanesForSceneRetirement()
        dispatcher.releaseLanesForSceneRetirement()
        let replacement = dispatcher.reserveLane()
        #expect(original.queue !== replacement.queue)
        #expect(original.virtualMachine !== replacement.virtualMachine)
        #expect(!original.invalidate())
        #expect(dispatcher.reserveLane().virtualMachine === replacement.virtualMachine)
        let originalStillWorks = original.queue.sync {
            autoreleasepool {
                JSContext(virtualMachine: original.virtualMachine)?
                    .evaluateScript("20 + 22")?.toInt32()
            }
        }
        #expect(originalStillWorks == 42)
    }

    @Test("A blocked retired lane neither blocks retirement nor the next scene")
    func blockedLaneRetiresWithoutWaiting() throws {
        let dispatcher = WPESceneScriptBatchDispatcher(width: 1)
        let (oldQueue, oldVM) = reserveWithoutKeepingLane(dispatcher)
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        oldQueue.async {
            started.signal()
            release.wait()
        }
        defer { release.signal() }
        try #require(started.wait(timeout: .now() + 1) == .success)
        let retired = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            dispatcher.releaseLanesForSceneRetirement()
            retired.signal()
        }
        try #require(retired.wait(timeout: .now() + 1) == .success)
        #expect(oldVM.value != nil, "VM ownership must be released by its blocked lane")
        let replacement = dispatcher.reserveLane()
        #expect(replacement.queue !== oldQueue)
        let replacementRan = DispatchSemaphore(value: 0)
        replacement.queue.async { replacementRan.signal() }
        #expect(replacementRan.wait(timeout: .now() + 1) == .success)
        release.signal()
        oldQueue.sync {}
        #expect(oldVM.value == nil)
    }

    @Test("Dropping the dispatcher releases its remaining VM ownership")
    func dispatcherDeinitReleasesVM() throws {
        var dispatcher: WPESceneScriptBatchDispatcher? = WPESceneScriptBatchDispatcher(width: 1)
        let (queue, vm) = try reserveWithoutKeepingLane(#require(dispatcher))
        dispatcher = nil
        queue.sync {}
        #expect(vm.value == nil)
    }
}

@MainActor
struct WPESceneScriptLaneRetirementIntegrationTests {
    @Test("A script-free renderer does not allocate batch VMs during load")
    func staticRendererDoesNotAllocateLanes() async throws {
        let fixture = try FrameDemandFixture.make()
        defer { fixture.cleanup() }
        let stack = try FrameDemandRendererStack.make(fixture)
        defer { stack.renderer.cleanup() }
        #expect(stack.renderer.sceneScriptBatchDispatcher.allocatedLaneCountForTesting == 0)
        try await stack.load()
        #expect(stack.renderer.sceneScriptBatchDispatcher.allocatedLaneCountForTesting == 0)
    }

    @Test("Renderer retirement drops batch VM ownership", arguments: [true, false])
    func rendererRetiresLanes(hibernate: Bool) async throws {
        let fixture = try FrameDemandFixture.make()
        defer { fixture.cleanup() }
        let stack = try FrameDemandRendererStack.make(fixture)
        defer { stack.renderer.cleanup() }
        try await stack.load()
        let dispatcher = stack.renderer.sceneScriptBatchDispatcher
        _ = dispatcher.reserveLane()
        #expect(dispatcher.allocatedLaneCountForTesting == 1)
        if hibernate {
            #expect(await stack.actor.hibernate())
        } else {
            stack.renderer.cleanup()
        }
        #expect(dispatcher.allocatedLaneCountForTesting == 0)
    }
}
#endif
