import CoreGraphics
@testable import LiveWallpaper
import Testing

@MainActor
@Suite("Detail transition coordinator")
struct DetailTransitionTests {
    @Test("Open hands the hero over once the tile lands; close reveals the tile before returning it")
    func openThenClose() async throws {
        let stage = FakeStage()
        let coordinator = DetailTransitionCoordinator(stage: stage) { .zero }
        var released = 0
        coordinator.onRelease = { released += 1 }

        coordinator.request(1)
        try await settle { stage.log == ["fly 1"] }
        #expect(coordinator.phase == .flyingIn && coordinator.busy && !coordinator.heroVisible)
        stage.land()
        try await settle { coordinator.phase == .shown }
        #expect(coordinator.heroVisible && stage.concealed[1] == true && !coordinator.busy)

        coordinator.request(nil)
        try await settle { stage.log.last == "return 1" }
        #expect(!coordinator.heroVisible && stage.concealed[1] == false && coordinator.busy)
        stage.land()
        try await settle { coordinator.phase == .idle }
        #expect(coordinator.shownDisplayID == nil && released == 1 && !coordinator.busy)
    }

    @Test("Re-requesting the display while its tile is still returning flies it in again")
    func reopenWhileReturning() async throws {
        let stage = FakeStage()
        let coordinator = DetailTransitionCoordinator(stage: stage) { .zero }
        coordinator.request(1)
        try await settle { stage.log == ["fly 1"] }
        stage.land()
        try await settle { coordinator.phase == .shown }

        coordinator.request(nil)
        try await settle { stage.log.last == "return 1" }
        coordinator.request(1)
        // The engine resumes the superseded await itself; here both returns park until the tile lands.
        try await settle { stage.log.filter { $0 == "return 1" }.count == 2 }
        stage.land()
        try await settle { stage.log.filter { $0 == "fly 1" }.count == 2 }
        stage.land()
        try await settle { coordinator.phase == .shown }
        #expect(coordinator.shownDisplayID == 1 && coordinator.heroVisible && stage.concealed[1] == true)
        #expect(!coordinator.busy)
    }

    @Test("The same target while it is flying in is left to finish")
    func sameTargetWhileFlyingIn() async throws {
        let stage = FakeStage()
        let coordinator = DetailTransitionCoordinator(stage: stage) { .zero }
        coordinator.request(1)
        try await settle { stage.log == ["fly 1"] }
        coordinator.request(1)
        stage.land()
        try await settle { coordinator.phase == .shown }
        #expect(stage.log == ["fly 1", "conceal 1 true"])
    }

    @Test("Resizing the window while the tile is flying or shown moves the destination with the hero")
    func resizeMovesTheFlightDestination() async throws {
        let stage = FakeStage()
        var hero = CGRect(x: 0, y: 0, width: 100, height: 50)
        let coordinator = DetailTransitionCoordinator(stage: stage) { hero }

        coordinator.request(1)
        try await settle { stage.log == ["fly 1"] }
        hero = CGRect(x: 0, y: 0, width: 200, height: 100)
        coordinator.windowDidResize()
        #expect(stage.destinations[1] == hero, "a tile still flying in has to land on the hero's new frame")

        stage.land()
        try await settle { coordinator.phase == .shown }
        hero = CGRect(x: 0, y: 0, width: 300, height: 150)
        coordinator.windowDidResize()
        #expect(stage.destinations[1] == hero, "the tile parked under the hero has to move with it")

        coordinator.request(nil)
        try await settle { stage.log.last == "return 1" }
        stage.destinations = [:]
        hero = CGRect(x: 0, y: 0, width: 400, height: 200)
        coordinator.windowDidResize()
        #expect(stage.destinations.isEmpty, "a tile on its way home is not flying to the hero any more")
    }

    @Test("Switching screens keeps detail visible and loads the new writer before any flight finishes")
    func directSwitchNeverShowsOverview() async throws {
        let stage = FakeStage()
        let coordinator = DetailTransitionCoordinator(stage: stage) { .zero }
        var shown: [CGDirectDisplayID] = []
        var releases = 0
        coordinator.onShow = { shown.append($0) }
        coordinator.onRelease = { releases += 1 }
        coordinator.request(1)
        try await settle { stage.log == ["fly 1"] }
        stage.land()
        try await settle { coordinator.phase == .shown }
        coordinator.request(2)
        #expect(coordinator.shownDisplayID == 2 && coordinator.heroVisible)
        #expect(shown == [1, 2] && releases == 0)
        try await settle { stage.log.last == "return 1" }
        stage.land()
        try await settle { stage.log.last == "fly 2" }
        #expect(coordinator.heroVisible)
        stage.land()
        try await settle { coordinator.phase == .shown }
        #expect(stage.concealed[2] == true && !coordinator.busy)
    }

    @Test("A rapid third display request supersedes the old switch without releasing the new session")
    func rapidSwitchUsesLatestDisplay() async throws {
        let stage = FakeStage()
        let coordinator = DetailTransitionCoordinator(stage: stage) { .zero }
        coordinator.request(1)
        try await settle { stage.log == ["fly 1"] }
        stage.land()
        try await settle { coordinator.phase == .shown }
        coordinator.request(2)
        try await settle { stage.log.last == "return 1" }
        coordinator.request(3)
        try await settle { stage.log.last == "return 2" }
        stage.land()
        try await settle { stage.log.last == "fly 3" }
        #expect(coordinator.shownDisplayID == 3 && coordinator.heroVisible)
        #expect(!stage.log.contains("fly 2"))
        stage.land()
        try await settle { coordinator.phase == .shown }
        #expect(stage.concealed[3] == true && !coordinator.busy)
    }

    @Test("Flight waits for the measured preview and follows live inspector resizing")
    func measuredPreviewOwnsFlight() async throws {
        let stage = FakeStage()
        let coordinator = DetailTransitionCoordinator(stage: stage, usesMeasuredFrame: true) {
            CGRect(x: 999, y: 999, width: 1, height: 1)
        }
        coordinator.request(1)
        try await settle { coordinator.shownDisplayID == 1 }
        #expect(stage.log.isEmpty)
        let actual = CGRect(x: 24, y: 251, width: 472, height: 265.5)
        coordinator.heroDidLayout(display: 1, frame: actual)
        try await settle { stage.log == ["fly 1"] }
        #expect(stage.destinations[1] == actual)
        let expanded = CGRect(x: 24, y: 130, width: 992, height: 558)
        coordinator.heroDidLayout(display: 1, frame: expanded)
        #expect(stage.destinations[1] == expanded)
        stage.land()
        try await settle { coordinator.phase == .shown }
        #expect(coordinator.heroVisible)
    }

    @Test("Closing before layout cancels the waiting flight without leaving detail busy")
    func closeBeforeLayout() async throws {
        let stage = FakeStage()
        let coordinator = DetailTransitionCoordinator(stage: stage, usesMeasuredFrame: true) { .zero }
        coordinator.request(1)
        try await settle { coordinator.shownDisplayID == 1 }
        coordinator.request(nil)
        try await settle { stage.log == ["conceal 1 false", "return 1"] }
        stage.land()
        try await settle { coordinator.phase == .idle }
        #expect(!coordinator.busy && coordinator.shownDisplayID == nil)
        coordinator.heroDidLayout(display: 1, frame: CGRect(x: 1, y: 1, width: 100, height: 100))
        #expect(!stage.log.contains("fly 1"))
    }

    private func settle(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 200 {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("condition never held")
    }
}

@MainActor
private final class FakeStage: DetailStageFlying {
    var log: [String] = []
    var concealed: [CGDirectDisplayID: Bool] = [:]
    var destinations: [CGDirectDisplayID: CGRect] = [:]
    private var parked: [CheckedContinuation<Void, Never>] = []

    func flyTile(display: CGDirectDisplayID, to rect: CGRect) async {
        destinations[display] = rect
        log.append("fly \(display)")
        await park()
    }

    func updateFlightDestination(display: CGDirectDisplayID, to rectInWindow: CGRect) {
        destinations[display] = rectInWindow
    }

    func returnTile(display: CGDirectDisplayID) async {
        log.append("return \(display)")
        await park()
    }

    func setTileConcealed(display: CGDirectDisplayID, _ concealed: Bool) {
        self.concealed[display] = concealed
        log.append("conceal \(display) \(concealed)")
    }

    /// Resumes every awaiting flight, like the engine settling all springs at once.
    func land() {
        let waiting = parked
        parked = []
        waiting.forEach { $0.resume() }
    }

    private func park() async {
        await withCheckedContinuation { parked.append($0) }
    }
}
