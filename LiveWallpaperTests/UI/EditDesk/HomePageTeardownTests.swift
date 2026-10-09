import AppKit
@testable import LiveWallpaper
import LiveWallpaperCore
import SwiftUI
import Testing

@MainActor
@Suite("Home page teardown", .serialized)
struct HomePageTeardownTests {
    @MainActor
    private final class Released {
        weak var stage: EditDeskStageModel?
        weak var library: SavedLibraryModel?
    }

    /// Holds its queue the way a page's state does; work that captures it closes the same loop a page's apply does.
    @MainActor
    private final class QueueOwner {
        let queue = HomePage.ApplyQueue()
        var ran = false
    }

    @MainActor
    private final class Gate {
        private var continuation: CheckedContinuation<Void, Never>?

        var isWaiting: Bool {
            continuation != nil
        }

        func wait() async {
            await withCheckedContinuation { continuation = $0 }
        }

        func open() {
            continuation?.resume()
            continuation = nil
        }
    }

    private static func views(_ root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap { views($0) }
    }

    private static func settle(seconds: Double, until condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private static func makeManager() -> ScreenManager {
        ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false, startAutomation: false,
            powerMonitor: FakePowerMonitor(), fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(), displayRegistry: FakeDisplayRegistry(screens: []),
            featureCatalog: .unconfigured
        ))
    }

    /// Hosts the home page in a window, runs `whileShown` against its stage, then closes the window.
    private static func showAndClose(
        _ manager: ScreenManager,
        whileShown: (EditDeskStageModel, EditDeskRouter) async -> Void = { _, _ in }
    ) async throws -> Released {
        let released = Released()
        let model = SavedLibraryModel(inputs: SavedLibraryModel.Inputs())
        released.library = model
        let router = EditDeskRouter(initialNavigation: nil, initialAddWallpaperRequest: nil, isWorkshopAvailable: { false })
        let hosting = NSHostingView(rootView: HomePage(router: router, toasts: EditDeskToastCenter(), library: model).environment(manager))
        hosting.sizingOptions = []
        let window = ParkedTestWindow(
            contentRect: CGRect(origin: .zero, size: StageGeometry.designWindow),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        hosting.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
        window.contentView = hosting
        window.parkOffScreen()
        await settle(seconds: 2) {
            hosting.layoutSubtreeIfNeeded()
            return views(hosting).contains { $0 is EditDeskStageView }
        }
        let stageView = try #require(views(hosting).lazy.compactMap { $0 as? EditDeskStageView }.first)
        released.stage = stageView.model
        await whileShown(stageView.model, router)
        window.orderOut(nil)
        window.contentView = nil
        window.close()
        return released
    }

    @Test("Closing the window that hosts the home page releases its stage model and library")
    func closingTheWindowReleasesTheStageAndLibrary() async throws {
        let manager = Self.makeManager()
        defer { manager.tearDownForTermination() }
        let released = try await Self.showAndClose(manager)
        await Self.settle(seconds: 6) { released.stage == nil && released.library == nil }
        #expect(released.stage == nil, "the stage model outlived the window that hosted the home page")
        #expect(released.library == nil, "the library outlived the window that hosted the home page")
    }

    @Test("Closing the window after the home page ran an apply releases its stage model and library", .timeLimit(.minutes(1)))
    func closingAfterAnApplyReleasesTheStageAndLibrary() async throws {
        let manager = Self.makeManager()
        defer { manager.tearDownForTermination() }
        let released = try await Self.showAndClose(manager) { stage, router in
            // A card the library lacks fails its apply at once; the event loop handles the snap only after queueing that apply.
            stage.emit(.dropped(card: "missing", onto: 1))
            stage.emit(.snapped(2))
            await Self.settle(seconds: 2) { router.page == .library }
            #expect(router.page == .library, "the page never consumed the drop, so no apply ran")
        }
        await Self.settle(seconds: 6) { released.stage == nil && released.library == nil }
        #expect(released.stage == nil, "an apply the page ran kept its stage model alive after the window closed")
        #expect(released.library == nil, "an apply the page ran kept its library alive after the window closed")
    }

    @Test("A finished apply lets go of the owner its work captured", .timeLimit(.minutes(1)))
    func aFinishedApplyReleasesItsWork() async {
        weak var released: QueueOwner?
        do {
            let owner = QueueOwner()
            released = owner
            owner.queue.run(for: 1) { _ in owner.ran = true }
            await Self.settle(seconds: 2) { owner.queue.isIdle }
            #expect(owner.ran)
        }
        await Self.settle(seconds: 2) { released == nil }
        #expect(released == nil, "the queue's finished task kept the work, and with it the queue's owner")
    }

    @Test("An apply still running when its owner is dropped releases the owner once it finishes", .timeLimit(.minutes(1)))
    func aRunningApplyReleasesItsWorkOnceFinished() async {
        let gate = Gate()
        weak var released: QueueOwner?
        do {
            let owner = QueueOwner()
            released = owner
            owner.queue.run(for: 1) { _ in
                await gate.wait()
                owner.ran = true
            }
            await Self.settle(seconds: 2) { gate.isWaiting }
            #expect(gate.isWaiting)
        }
        gate.open()
        await Self.settle(seconds: 2) { released == nil }
        #expect(released == nil, "the apply finished but its task kept the work, and with it the queue's owner")
    }
}
