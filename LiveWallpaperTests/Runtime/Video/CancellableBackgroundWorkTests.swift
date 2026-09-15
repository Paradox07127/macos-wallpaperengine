import Foundation
@testable import LiveWallpaper
import os
import Testing

struct CancellableBackgroundWorkTests {
    @Test("Parent cancellation reaches detached work and waits for its resource release")
    func cancelsAndDrains() async throws {
        let entered = OSAllocatedUnfairLock(initialState: false)
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        let exited = OSAllocatedUnfairLock(initialState: false)
        let work = Task {
            try await CancellableBackgroundWork.run {
                defer { exited.withLock { $0 = true } }
                entered.withLock { $0 = true }
                let end = ProcessInfo.processInfo.systemUptime + 2
                while !Task.isCancelled, ProcessInfo.processInfo.systemUptime < end {
                    Thread.sleep(forTimeInterval: 0.001)
                }
                cancelled.withLock { $0 = Task.isCancelled }
                return 42
            }
        }
        for _ in 0 ..< 400 {
            if entered.withLock({ $0 }) {
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(entered.withLock { $0 })
        work.cancel()
        do {
            _ = try await work.value
            Issue.record("Cancelled work returned a result")
        } catch is CancellationError {
            #expect(cancelled.withLock { $0 })
            #expect(exited.withLock { $0 })
        }
    }

    @Test("Success and errors propagate unchanged")
    func propagatesResults() async throws {
        #expect(try await CancellableBackgroundWork.run { 42 } == 42)
        enum Expected: Error { case failed }
        do {
            _ = try await CancellableBackgroundWork.run { () -> Int in throw Expected.failed }
            Issue.record("Expected the operation error")
        } catch Expected.failed {}
    }
}
