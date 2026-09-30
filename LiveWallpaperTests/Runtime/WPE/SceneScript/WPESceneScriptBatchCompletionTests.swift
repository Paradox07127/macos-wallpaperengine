#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import os
import Testing

@Suite("SceneScript batch observation preserves real worker ownership")
struct WPESceneScriptBatchCompletionTests {
    @Test func noWorkCompletesAndDefaultSubmitNeedsNoTicket() throws {
        let dispatcher = WPESceneScriptBatchDispatcher(width: 1)
        #expect(dispatcher.submit([]) == nil)
        let ticket = try #require(dispatcher.submit([], trackingCompletion: true))
        #expect(ticket.wait(timeout: .now()))
    }

    @Test func orderedObservationKeepsInterleavedLaneSubmissionOrder() throws {
        let dispatcher = WPESceneScriptBatchDispatcher(width: 2)
        let first = DispatchQueue(label: "wpe.test.ordered.first")
        let second = DispatchQueue(label: "wpe.test.ordered.second")
        let state = OSAllocatedUnfairLock(initialState: [Int]())
        let ticket = try #require(dispatcher.submit([
            .init(queue: first, work: { state.withLock { $0.append(1) } }),
            .init(queue: second, work: { state.withLock { $0.append(2) } }),
            .init(queue: first, work: { state.withLock { $0.append(3) } }),
        ], trackingCompletion: true, order: .submissionOrder))
        #expect(ticket.wait(timeout: .now() + 1))
        #expect(state.withLock { $0 } == [1, 2, 3])
    }

    @Test func completionWaitsForEveryOwningQueueAndTimesOutWithoutCancelling() throws {
        let dispatcher = WPESceneScriptBatchDispatcher(width: 2)
        let first = DispatchQueue(label: "wpe.test.batch.first")
        let second = DispatchQueue(label: "wpe.test.batch.second")
        let held = DispatchSemaphore(value: 0)
        let began = DispatchSemaphore(value: 0)
        let firstFinished = DispatchSemaphore(value: 0)
        let secondFinished = DispatchSemaphore(value: 0)
        defer { held.signal() }
        let ticket = try #require(dispatcher.submit([
            .init(queue: first, work: { firstFinished.signal() }),
            .init(queue: second, work: { began.signal(); held.wait(); secondFinished.signal() }),
        ], trackingCompletion: true))
        #expect(began.wait(timeout: .now() + 1) == .success)
        #expect(firstFinished.wait(timeout: .now() + 1) == .success)
        #expect(!ticket.wait(timeout: .now()))
        #expect(secondFinished.wait(timeout: .now()) == .timedOut)
        held.signal()
        #expect(ticket.wait(timeout: .now() + 1))
        #expect(secondFinished.wait(timeout: .now()) == .success)
    }
}
#endif
