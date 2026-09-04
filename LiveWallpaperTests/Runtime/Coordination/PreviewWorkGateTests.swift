import Testing
@testable import LiveWallpaper

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
            for _ in 0..<24 {
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
        // Control: a gate that serialised everything — or a harness that never
        // actually overlapped — would satisfy the ceiling for the wrong reason.
        #expect(highWater > 1, "Nothing ever overlapped, so the ceiling proves nothing.")
        #expect(await gate.activeCount == 0, "A slot leaked.")
    }

    @Test("Every waiter is eventually admitted")
    func admitsEveryWaiter() async {
        let gate = PreviewWorkGate(limit: 2)
        let completed = Counter()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<50 {
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
                // The contract callers follow: check cancellation first, so an
                // abandoned tile frees the lane instead of holding it.
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        task.cancel()
        await task.value
        #expect(await gate.activeCount == 0)

        // The lane is usable immediately afterwards.
        await gate.run {}
        #expect(await gate.activeCount == 0)
    }

    @Test("Waiting for a slot is itself cancellable work")
    func waitingForASlotIsCancellable() async {
        let gate = PreviewWorkGate(limit: 1)
        let occupied = Counter()

        // Fill the only lane, then queue behind it and cancel while queued.
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

        // The cancelled waiter is admitted, sees the cancellation and leaves
        // without doing the work — which is what keeps it from blocking the
        // tiles the reader is actually looking at.
        #expect(await occupied.value == 0)
        #expect(await gate.activeCount == 0)
    }

    @Test("A waiter cancelled while queued leaves the queue instead of holding a place")
    func cancelledWaiterLeavesTheQueue() async {
        let gate = PreviewWorkGate(limit: 1)
        let ran = Counter()

        // Occupy the only lane for a while.
        let holder = Task { await gate.run { try? await Task.sleep(for: .milliseconds(300)) } }
        try? await Task.sleep(for: .milliseconds(30))

        // Queue several waiters and abandon them, as a fast scroll does.
        let abandoned = (0..<5).map { _ in
            Task { await gate.run { await ran.bump() } }
        }
        try? await Task.sleep(for: .milliseconds(30))
        #expect(await gate.queuedCount == 5)
        abandoned.forEach { $0.cancel() }
        try? await Task.sleep(for: .milliseconds(50))

        // They are gone from the queue *before* the lane frees up — that is what
        // keeps a newly visible tile from waiting behind work nobody wants.
        #expect(await gate.queuedCount == 0)

        for task in abandoned { await task.value }
        await holder.value
        #expect(await gate.activeCount == 0)
    }

    @Test("Cancellation bookkeeping does not accumulate")
    func cancellationBookkeepingStaysBounded() async {
        let gate = PreviewWorkGate(limit: 1)
        // Churn admitted-then-cancelled callers: a cancel that lands after the
        // waiter was already handed a slot must not be filed away forever.
        for _ in 0..<40 {
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
        func bump() { value += 1 }
    }
}
