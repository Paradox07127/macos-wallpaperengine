import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

@Suite("Preview work gate")
struct PreviewWorkGateTests {
    private actor Peak {
        private var current = 0
        private(set) var highWater = 0

        func enter() {
            current += 1
            highWater = max(highWater, current)
        }

        func leave() {
            current -= 1
        }
    }

    @Test("Concurrency never exceeds the limit, and work still overlaps")
    func boundsConcurrency() async {
        let gate = PreviewWorkGate(limit: 3)
        let peak = Peak()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 24 {
                group.addTask {
                    await gate.run {
                        await peak.enter()
                        try? await Task.sleep(for: .milliseconds(5))
                        await peak.leave()
                    }
                }
            }
        }

        let highWater = await peak.highWater
        #expect(highWater <= 3, "Ran \(highWater) at once against a limit of 3.")
        #expect(highWater > 1, "Nothing ever overlapped, so the ceiling proves nothing.")
        #expect(await gate.activeCount == 0, "A slot leaked.")
    }

    @Test("Every waiter is eventually admitted")
    func admitsEveryWaiter() async {
        let gate = PreviewWorkGate(limit: 2)
        let completed = Counter()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 50 {
                group.addTask {
                    await gate.run { await completed.bump() }
                }
            }
        }

        #expect(await completed.value == 50)
        #expect(await gate.activeCount == 0)
    }

    @Test("A cancelled caller still releases its slot")
    func cancelledCallerReleasesSlot() async {
        let gate = PreviewWorkGate(limit: 1)
        let task = Task {
            await gate.run {
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        task.cancel()
        await task.value
        #expect(await gate.activeCount == 0)

        await gate.run {}
        #expect(await gate.activeCount == 0)
    }

    @Test("Waiting for a slot is itself cancellable work")
    func waitingForASlotIsCancellable() async {
        let gate = PreviewWorkGate(limit: 1)
        let occupied = Counter()

        let holder = Task { await gate.run { try? await Task.sleep(for: .milliseconds(120)) } }
        try? await Task.sleep(for: .milliseconds(20))
        let queued = Task {
            await gate.run {
                guard !Task.isCancelled else { return }
                await occupied.bump()
            }
        }
        queued.cancel()
        await holder.value
        await queued.value

        #expect(await occupied.value == 0)
        #expect(await gate.activeCount == 0)
    }

    @Test("A waiter cancelled while queued leaves the queue instead of holding a place")
    func cancelledWaiterLeavesTheQueue() async {
        let gate = PreviewWorkGate(limit: 1)
        let ran = Counter()

        let holder = Task { await gate.run { try? await Task.sleep(for: .milliseconds(300)) } }
        try? await Task.sleep(for: .milliseconds(30))

        let abandoned = (0 ..< 5).map { _ in
            Task { await gate.run { await ran.bump() } }
        }
        try? await Task.sleep(for: .milliseconds(30))
        #expect(await gate.queuedCount == 5)
        abandoned.forEach { $0.cancel() }
        try? await Task.sleep(for: .milliseconds(50))

        // They are gone from the queue *before* the lane frees up.
        #expect(await gate.queuedCount == 0)

        for task in abandoned {
            await task.value
        }
        await holder.value
        #expect(await gate.activeCount == 0)
    }

    @Test("Cancellation bookkeeping does not accumulate")
    func cancellationBookkeepingStaysBounded() async {
        let gate = PreviewWorkGate(limit: 1)
        // Churn admitted-then-cancelled callers: the cancel lands after the slot
        // was already handed out.
        for _ in 0 ..< 40 {
            let task = Task { await gate.run { try? await Task.sleep(for: .milliseconds(1)) } }
            task.cancel()
            await task.value
        }
        #expect(await gate.activeCount == 0)
        #expect(await gate.queuedCount == 0)
        #expect(await gate.retainedCancellationIDs == 0, "Cancellation bookkeeping leaked.")
    }

    private actor Counter {
        private(set) var value = 0
        func bump() {
            value += 1
        }
    }
}

@MainActor
@Suite("Shared preview requests", .serialized)
struct PreviewRequestPoolTests {
    private final class Probe {
        var started = 0
        var active = 0
        var peak = 0
        var release: CheckedContinuation<Void, Never>?
    }

    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline {
            await Task.yield()
        }
        #expect(condition())
    }

    @Test func oneProducerSurvivesOneConsumersCancellation() async {
        let pool = PreviewRequestPool<Int>(gate: PreviewWorkGate(limit: 2))
        let probe = Probe()
        let first = Task {
            await pool.value(for: "shared") {
                probe.started += 1
                await withCheckedContinuation { probe.release = $0 }
                return 42
            }
        }
        await waitUntil { probe.release != nil }
        let second = Task { await pool.value(for: "shared") { probe.started += 1; return 99 } }
        await waitUntil { pool.waiterCount == 2 }
        first.cancel()
        #expect(await first.value == nil)
        #expect(pool.requestCount == 1)
        probe.release?.resume()
        #expect(await second.value == 42)
        #expect(probe.started == 1)
        #expect(pool.requestCount == 0)
    }

    @Test func lateCancelledProducerCannotCompleteReplacement() async {
        let pool = PreviewRequestPool<Int>(gate: PreviewWorkGate(limit: 2))
        let old = Probe()
        let next = Probe()
        let first = Task {
            await pool.value(for: "same") {
                await withCheckedContinuation { old.release = $0 }
                return 1
            }
        }
        await waitUntil { old.release != nil }
        pool.invalidate("same")
        #expect(await first.value == nil)
        let replacement = Task {
            await pool.value(for: "same") {
                await withCheckedContinuation { next.release = $0 }
                return 2
            }
        }
        await waitUntil { next.release != nil }
        old.release?.resume()
        for _ in 0 ..< 10 {
            await Task.yield()
        }
        #expect(pool.requestCount == 1)
        next.release?.resume()
        #expect(await replacement.value == 2)
        #expect(pool.requestCount == 0)
    }

    @Test func manyDifferentCardsStayWithinBudget() async {
        let pool = PreviewRequestPool<Int>(gate: PreviewWorkGate(limit: 2))
        let probe = Probe()
        let tasks = (0 ..< 100).map { index in
            Task {
                await pool.value(for: String(index)) {
                    probe.active += 1
                    probe.peak = max(probe.peak, probe.active)
                    defer { probe.active -= 1 }
                    try? await Task.sleep(for: .milliseconds(2))
                    return index
                }
            }
        }
        for (index, task) in tasks.enumerated() {
            #expect(await task.value == index)
        }
        #expect(probe.peak == 2)
        #expect(pool.requestCount == 0)
        #expect(pool.waiterCount == 0)
    }

    @Test func lastQueuedConsumerLeavesWithoutStartingProducer() async {
        let gate = PreviewWorkGate(limit: 1)
        let pool = PreviewRequestPool<Int>(gate: gate)
        let probe = Probe()
        let holder = Task {
            await pool.value(for: "holder") {
                await withCheckedContinuation { probe.release = $0 }
                return 1
            }
        }
        await waitUntil { probe.release != nil }
        let abandoned = Task { await pool.value(for: "queued") { probe.started += 1; return 2 } }
        await waitUntil { pool.requestCount == 2 }
        abandoned.cancel()
        #expect(await abandoned.value == nil)
        probe.release?.resume()
        #expect(await holder.value == 1)
        #expect(probe.started == 0)
        #expect(pool.requestCount == 0)
    }
}

@MainActor
@Suite("Preview filesystem work", .serialized)
struct PreviewFilesystemWorkTests {
    @Test func synchronousWorkRunsOffMainThread() async {
        let onMain = await PreviewWorkGate(limit: 1).runDetached { Thread.isMainThread }
        #expect(onMain == false)
    }

    @Test func cancellationWithdrawsQueuedFilesystemWork() async throws {
        let gate = PreviewWorkGate(limit: 1)
        let holder = Task { await gate.run { try? await Task.sleep(for: .seconds(30)) } }
        defer { holder.cancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await gate.activeCount == 0, ContinuousClock.now < deadline {
            await Task.yield()
        }
        try #require(await gate.activeCount == 1)
        let queued = Task { await gate.runDetached { 42 } }
        defer { queued.cancel() }
        while await gate.queuedCount == 0, ContinuousClock.now < deadline {
            await Task.yield()
        }
        try #require(await gate.queuedCount == 1)
        queued.cancel()
        #expect(await queued.value == nil)
        #expect(await gate.activeCount == 1)
        #expect(await gate.queuedCount == 0)
        holder.cancel()
        await holder.value
    }

    @Test func fileAvailabilityRefreshesAfterDeletion() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("preview-location-\(UUID().uuidString)")
        try Data([1]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let bookmark = try url.bookmarkData(options: .minimalBookmark)
        let content = WallpaperContent.video(bookmarkData: bookmark)
        let present = await LibraryContentLocator.locate(content: content, wpeOrigin: nil)
        #expect(present.isAvailable)
        #expect(present.revealURL == url)
        try FileManager.default.removeItem(at: url)
        let missing = await LibraryContentLocator.locate(content: content, wpeOrigin: nil)
        #expect(!missing.isAvailable)
        #expect(missing.revealURL == nil)
    }
}
