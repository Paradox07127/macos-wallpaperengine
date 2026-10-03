import AppKit
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

private final class BarrierCommitTestNSScreen: NSScreen {
    var displayID: UInt32 = 1
    override var frame: NSRect {
        NSRect(x: CGFloat(displayID) * 800, y: 0, width: 800, height: 600)
    }

    override var deviceDescription: [NSDeviceDescriptionKey: Any] {
        [NSDeviceDescriptionKey("NSScreenNumber"): displayID]
    }

    override var localizedName: String {
        "Barrier Commit Test"
    }
}

@MainActor
private final class BarrierTestSession: WallpaperRuntimeSession {
    let wallpaperType: WallpaperType = .scene
    let wallpaperWindow: NSWindow? = nil
    let videoPlayer: WallpaperVideoPlayer? = nil
    var summary: WallpaperSessionSummary {
        .notConfigured
    }

    var isCurrent = true
    /// Reaches 2 in the same turn the candidate arrives at the barrier.
    private(set) var showCallCount = 0
    private(set) var cleanupCallCount = 0

    func show() {
        showCallCount += 1
    }

    func applyPerformanceProfile(_: WallpaperPerformanceProfile) {}
    func updateFrame(to _: CGRect) {}
    func prepareForDisplay(timeout _: Duration) async -> WallpaperPreparationResult {
        .ready
    }

    func cleanup() {
        cleanupCallCount += 1
    }
}

@MainActor
private final class PrepareGate {
    private var result: WallpaperPreparationResult?
    private var waiter: CheckedContinuation<WallpaperPreparationResult, Never>?

    func wait() async -> WallpaperPreparationResult {
        if let result {
            return result
        }
        return await withCheckedContinuation { waiter = $0 }
    }

    func open(_ result: WallpaperPreparationResult = .ready) {
        self.result = result
        waiter?.resume(returning: result)
        waiter = nil
    }
}

@Suite("Wallpaper start barrier at commit")
@MainActor
struct WallpaperStartBarrierCommitTests {
    private func makeScreen(id: UInt32) -> Screen {
        let nsScreen = BarrierCommitTestNSScreen()
        nsScreen.displayID = id
        return Screen(nsScreen: nsScreen)
    }

    private func commit(
        _ candidate: BarrierTestSession,
        to screen: Screen,
        gate: PrepareGate? = nil,
        batch: WallpaperOpeningBatch? = nil
    ) -> Task<WallpaperPreparationResult, Never> {
        Task { @MainActor in
            await WallpaperSessionTransaction.prepareAndCommit(
                candidate,
                to: screen,
                replacing: nil,
                timeout: .seconds(60),
                isStillCurrent: { candidate.isCurrent },
                prepare: { _, _ in
                    if let gate {
                        return await gate.wait()
                    }
                    return .ready
                },
                claimOpening: { batch?.claim(screen.id) }
            )
        }
    }

    /// Starts B first and waits for its first show, so B has joined before A can arrive.
    private func startPair(
        _ a: BarrierTestSession, on screenA: Screen,
        _ b: BarrierTestSession, on screenB: Screen,
        gateB: PrepareGate,
        group: WallpaperSwitchGroup?,
        batch: WallpaperOpeningBatch? = nil
    ) async throws -> (a: Task<WallpaperPreparationResult, Never>, b: Task<WallpaperPreparationResult, Never>) {
        let taskB = WallpaperSwitchGroup.$current.withValue(group) { commit(b, to: screenB, gate: gateB, batch: batch) }
        try await waitUntil { b.showCallCount == 1 }
        let taskA = WallpaperSwitchGroup.$current.withValue(group) { commit(a, to: screenA, batch: batch) }
        return (taskA, taskB)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out waiting for the condition")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func settle() async {
        for _ in 0 ..< 20 {
            await Task.yield()
        }
    }

    @Test("A display that is ready first waits for its group before committing", .timeLimit(.minutes(1)))
    func waitsForTheGroup() async throws {
        let group = WallpaperSwitchGroup(pace: .manual, barrier: WallpaperStartBarrier(timeout: .seconds(30)))
        let screenA = makeScreen(id: 51)
        let screenB = makeScreen(id: 52)
        let a = BarrierTestSession()
        let b = BarrierTestSession()
        let gateB = PrepareGate()

        let tasks = try await startPair(a, on: screenA, b, on: screenB, gateB: gateB, group: group)
        try await waitUntil { a.showCallCount == 2 }
        await settle()
        #expect(screenA.runtimeSession == nil, "the first ready display committed without waiting for its group")

        gateB.open()
        #expect(await tasks.a.value == .ready)
        #expect(await tasks.b.value == .ready)
        #expect(screenA.runtimeSession === a)
        #expect(screenB.runtimeSession === b)
        let start = try #require(group.barrier.start(for: screenA.id))
        #expect(group.barrier.start(for: screenB.id) == start)
    }

    @Test("A display whose group partner fails commits without waiting out the barrier", .timeLimit(.minutes(1)))
    func partnerFailureReleases() async throws {
        let group = WallpaperSwitchGroup(pace: .manual, barrier: WallpaperStartBarrier(timeout: .seconds(30)))
        let screenA = makeScreen(id: 53)
        let screenB = makeScreen(id: 54)
        let a = BarrierTestSession()
        let b = BarrierTestSession()
        let gateB = PrepareGate()
        let began = ContinuousClock.now

        let tasks = try await startPair(a, on: screenA, b, on: screenB, gateB: gateB, group: group)
        try await waitUntil { a.showCallCount == 2 }
        gateB.open(.failed)
        #expect(await tasks.a.value == .ready)
        #expect(ContinuousClock.now - began < .seconds(20))
        #expect(await tasks.b.value == .failed)
        #expect(screenA.runtimeSession === a)
        #expect(group.barrier.start(for: screenA.id) == nil)
    }

    @Test("A display whose group partner is no longer current commits without waiting out the barrier", .timeLimit(.minutes(1)))
    func partnerNoLongerCurrentReleases() async throws {
        let group = WallpaperSwitchGroup(pace: .manual, barrier: WallpaperStartBarrier(timeout: .seconds(30)))
        let screenA = makeScreen(id: 55)
        let screenB = makeScreen(id: 56)
        let a = BarrierTestSession()
        let b = BarrierTestSession()
        let gateB = PrepareGate()
        let began = ContinuousClock.now

        let tasks = try await startPair(a, on: screenA, b, on: screenB, gateB: gateB, group: group)
        try await waitUntil { a.showCallCount == 2 }
        b.isCurrent = false
        gateB.open()
        #expect(await tasks.a.value == .ready)
        #expect(ContinuousClock.now - began < .seconds(20))
        #expect(await tasks.b.value == .cancelled)
        #expect(screenA.runtimeSession === a)
        #expect(group.barrier.start(for: screenA.id) == nil)
    }

    @Test("The barrier timeout releases the ready display, and a late partner commits at once", .timeLimit(.minutes(1)))
    func timeoutReleasesAndLatePartnerPassesThrough() async throws {
        let group = WallpaperSwitchGroup(pace: .manual, barrier: WallpaperStartBarrier(timeout: .milliseconds(50)))
        let screenA = makeScreen(id: 57)
        let screenB = makeScreen(id: 58)
        let a = BarrierTestSession()
        let b = BarrierTestSession()
        let gateB = PrepareGate()

        let tasks = try await startPair(a, on: screenA, b, on: screenB, gateB: gateB, group: group)
        #expect(await tasks.a.value == .ready)
        #expect(screenA.runtimeSession === a)
        #expect(screenB.runtimeSession == nil)

        gateB.open()
        #expect(await tasks.b.value == .ready)
        #expect(screenB.runtimeSession === b)
        #expect(group.barrier.start(for: screenB.id) == nil)
    }

    @Test("A candidate superseded while it waits at the barrier is discarded", .timeLimit(.minutes(1)))
    func supersededWhileWaitingIsDiscarded() async throws {
        let group = WallpaperSwitchGroup(pace: .manual, barrier: WallpaperStartBarrier(timeout: .seconds(30)))
        let screenA = makeScreen(id: 61)
        let screenB = makeScreen(id: 62)
        let a = BarrierTestSession()
        let b = BarrierTestSession()
        let gateB = PrepareGate()

        let tasks = try await startPair(a, on: screenA, b, on: screenB, gateB: gateB, group: group)
        try await waitUntil { a.showCallCount == 2 }
        a.isCurrent = false

        gateB.open()
        #expect(await tasks.a.value == .cancelled)
        #expect(await tasks.b.value == .ready)
        #expect(screenA.runtimeSession == nil)
        #expect(a.cleanupCallCount == 1)
    }

    @Test("Displays that claim the launch opening start together on the batch's barrier", .timeLimit(.minutes(1)))
    func openingBatchStartsTogether() async throws {
        let screenA = makeScreen(id: 63)
        let screenB = makeScreen(id: 64)
        let batch = WallpaperOpeningBatch(
            displayIDs: [screenA.id, screenB.id], effect: .loom, barrier: WallpaperStartBarrier(timeout: .seconds(30))
        )
        let a = BarrierTestSession()
        let b = BarrierTestSession()
        let gateB = PrepareGate()

        let tasks = try await startPair(a, on: screenA, b, on: screenB, gateB: gateB, group: nil, batch: batch)
        try await waitUntil { a.showCallCount == 2 }
        await settle()
        #expect(screenA.runtimeSession == nil)

        gateB.open()
        #expect(await tasks.a.value == .ready)
        #expect(await tasks.b.value == .ready)
        let start = try #require(batch.barrier.start(for: screenA.id))
        #expect(batch.barrier.start(for: screenB.id) == start)
    }

    @Test("Inside a switch group the group's barrier wins over the opening batch's", .timeLimit(.minutes(1)))
    func groupBarrierWinsOverBatch() async throws {
        let group = WallpaperSwitchGroup(pace: .manual, barrier: WallpaperStartBarrier(timeout: .seconds(30)))
        let screenA = makeScreen(id: 65)
        let screenB = makeScreen(id: 66)
        let batch = WallpaperOpeningBatch(
            displayIDs: [screenA.id, screenB.id], effect: .loom, barrier: WallpaperStartBarrier(timeout: .seconds(30))
        )
        let a = BarrierTestSession()
        let b = BarrierTestSession()
        let gateB = PrepareGate()

        let tasks = try await startPair(a, on: screenA, b, on: screenB, gateB: gateB, group: group, batch: batch)
        try await waitUntil { a.showCallCount == 2 }
        gateB.open()
        #expect(await tasks.a.value == .ready)
        #expect(await tasks.b.value == .ready)
        #expect(batch.claim(screenA.id) == nil, "the display never claimed the opening")
        #expect(batch.claim(screenB.id) == nil, "the display never claimed the opening")
        let start = try #require(group.barrier.start(for: screenA.id))
        #expect(group.barrier.start(for: screenB.id) == start)
        #expect(batch.barrier.start(for: screenA.id) == nil)
    }

    @Test("Without a group or an opening a ready display commits at once", .timeLimit(.minutes(1)))
    func noBarrierCommitsAtOnce() async throws {
        let screenA = makeScreen(id: 67)
        let screenB = makeScreen(id: 68)
        let a = BarrierTestSession()
        let b = BarrierTestSession()
        let gateB = PrepareGate()

        let tasks = try await startPair(a, on: screenA, b, on: screenB, gateB: gateB, group: nil)
        #expect(await tasks.a.value == .ready)
        #expect(screenA.runtimeSession === a)
        #expect(screenB.runtimeSession == nil)

        gateB.open()
        #expect(await tasks.b.value == .ready)
    }
}
