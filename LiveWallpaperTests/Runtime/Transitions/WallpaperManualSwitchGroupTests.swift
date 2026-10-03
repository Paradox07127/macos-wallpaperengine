import AppKit
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

private final class ManualSwitchGroupTestNSScreen: NSScreen {
    var displayID: UInt32 = 1
    override var frame: NSRect {
        NSRect(x: CGFloat(displayID) * 800, y: 0, width: 800, height: 600)
    }

    override var deviceDescription: [NSDeviceDescriptionKey: Any] {
        [NSDeviceDescriptionKey("NSScreenNumber"): displayID]
    }

    override var localizedName: String {
        "Manual Switch Group Test"
    }
}

private enum TestAttempt {}
private let attempt = ObjectIdentifier(TestAttempt.self)

@MainActor
private final class Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let released = waiters
        waiters = []
        for waiter in released {
            waiter.resume()
        }
    }
}

@MainActor
private final class Arrivals {
    private(set) var finished: Set<CGDirectDisplayID> = []
    private(set) var starts: [CGDirectDisplayID: WallpaperSpanStart] = [:]

    func record(_ display: CGDirectDisplayID, _ start: WallpaperSpanStart?) {
        finished.insert(display)
        starts[display] = start
    }

    /// Joins the current group's barrier and waits for release, as a display reaching commit would.
    func joinAndArrive(_ screen: Screen) async {
        guard let barrier = WallpaperSwitchGroup.current?.barrier else {
            Issue.record("The work must run inside a switch group")
            return
        }
        barrier.join(screen.id, attempt: attempt)
        let start = await barrier.arrive(screen.id, attempt: attempt, frame: screen.frame)
        record(screen.id, start)
    }

    func waitUntilFinished(_ displays: Set<CGDirectDisplayID>, within limit: Duration) async throws {
        let deadline = ContinuousClock.now + limit
        while !displays.isSubset(of: finished), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

@MainActor
private func settle() async {
    for _ in 0 ..< 50 {
        await Task.yield()
    }
}

@Suite("Wallpaper manual switch group")
@MainActor
struct WallpaperManualSwitchGroupTests {
    private func makeScreen(id: UInt32) -> Screen {
        let nsScreen = ManualSwitchGroupTestNSScreen()
        nsScreen.displayID = id
        return Screen(nsScreen: nsScreen)
    }

    private func slowGroup(_ pace: WallpaperTransitionPace) -> WallpaperSwitchGroup {
        WallpaperSwitchGroup(pace: pace, barrier: WallpaperStartBarrier(timeout: .seconds(30)))
    }

    // MARK: - runEach

    @Test("runEach reuses an enclosing manual group and opens a manual one inside an automatic group", .timeLimit(.minutes(1)))
    func runEachReusesEnclosingManualGroup() async throws {
        let screens = [makeScreen(id: 61), makeScreen(id: 62)]
        for (outer, reused) in [(slowGroup(.manual), true), (slowGroup(.automatic), false)] {
            let queue = HomePage.ApplyQueue()
            var seen: [WallpaperSwitchGroup?] = []
            WallpaperSwitchGroup.$current.withValue(outer) {
                queue.runEach(screens) { _, _ in seen.append(WallpaperSwitchGroup.current) }
            }
            while seen.count < screens.count {
                await Task.yield()
            }
            let first = try #require(seen.first ?? nil)
            #expect(seen.allSatisfy { $0 === first })
            #expect(first.pace == .manual)
            #expect((first === outer) == reused)
        }
    }

    @Test("runEach holds an early display until a later one that awaited before dispatching arrives", .timeLimit(.minutes(1)))
    func runEachExpectsEveryDisplay() async throws {
        let a = makeScreen(id: 63)
        let b = makeScreen(id: 64)
        let gate = Gate()
        let arrivals = Arrivals()
        let queue = HomePage.ApplyQueue()
        WallpaperSwitchGroup.$current.withValue(slowGroup(.manual)) {
            queue.runEach([a, b]) { screen, _ in
                if screen.id == b.id {
                    await gate.wait()
                }
                await arrivals.joinAndArrive(screen)
            }
        }
        await settle()
        #expect(!arrivals.finished.contains(a.id), "A was released before B dispatched")

        gate.open()
        try await arrivals.waitUntilFinished([a.id, b.id], within: .seconds(20))
        let start = try #require(arrivals.starts[a.id])
        #expect(arrivals.starts[b.id] == start)
    }

    @Test("runEach releases an arrived display once the other display's work ends without joining", .timeLimit(.minutes(1)))
    func runEachAbandonsDisplaysThatNeverJoin() async throws {
        let a = makeScreen(id: 65)
        let b = makeScreen(id: 66)
        let arrivals = Arrivals()
        let queue = HomePage.ApplyQueue()
        WallpaperSwitchGroup.$current.withValue(slowGroup(.manual)) {
            queue.runEach([a, b]) { screen, _ in
                if screen.id == a.id {
                    await arrivals.joinAndArrive(screen)
                }
            }
        }
        try await arrivals.waitUntilFinished([a.id], within: .seconds(5))
        #expect(arrivals.finished.contains(a.id), "A waited for B, which never joined")
        #expect(arrivals.starts[a.id] == nil)
    }

    // MARK: - Automatic selection

    private func makeOrchestrator(
        screens: [Screen], available: @MainActor @escaping (WallpaperQueueEntry) async -> Bool, arrivals: Arrivals
    ) -> WallpaperAutomationOrchestrator {
        let configurations = screens.map { screen in
            let entries = (0 ..< 2).map { index in
                WallpaperQueueEntry(
                    id: "\(screen.id)-\(index)", title: "Entry \(index)",
                    content: .html(source: .inline("\(screen.id)-\(index)"), config: .default)
                )
            }
            var configuration = ScreenConfiguration(screenID: screen.id, wallpaper: entries[0].content, fitMode: .aspectFit)
            configuration.wallpaperQueue = entries
            configuration.playlistRotationMinutes = 1
            return configuration
        }
        let store = WallpaperConfigurationStore(persistence: ManualSwitchGroupTestPersistence(configurations))
        return WallpaperAutomationOrchestrator(
            configurationStore: store, automationCoordinator: WallpaperAutomationCoordinator(),
            playableVideoLoader: FakePlayableVideoLoader(), screensProvider: { screens },
            saveConfiguration: { store.save($0) }, recordBookmarkDisplayName: { _, _ in },
            setupPreparedVideoPlayback: { _, _, _, _ in Issue.record("HTML entries must not set up video playback") },
            restoreProposedConfiguration: { _, _ in },
            bumpTransition: { _ in 0 }, isCurrentTransition: { _, _ in true },
            prepareAutomation: { screen, _, _, _ in
                await arrivals.joinAndArrive(screen)
                return .ready
            }, libraryEntryAvailable: available
        )
    }

    @Test("Automatic selection holds an early display until a later one that awaited before dispatching arrives", .timeLimit(.minutes(1)))
    func automaticSelectionExpectsItsDisplay() async throws {
        let a = makeScreen(id: 67)
        let b = makeScreen(id: 68)
        let gate = Gate()
        let arrivals = Arrivals()
        let orchestrator = makeOrchestrator(screens: [a, b], available: { entry in
            if entry.id.hasPrefix("\(b.id)-") {
                await gate.wait()
            }
            return true
        }, arrivals: arrivals)
        WallpaperSwitchGroup.$current.withValue(slowGroup(.automatic)) {
            orchestrator.advancePlaylist(for: a)
            orchestrator.advancePlaylist(for: b)
        }
        await settle()
        #expect(!arrivals.finished.contains(a.id), "A was released before B dispatched")

        gate.open()
        try await arrivals.waitUntilFinished([a.id, b.id], within: .seconds(20))
        let start = try #require(arrivals.starts[a.id])
        #expect(arrivals.starts[b.id] == start)
    }

    @Test("Automatic selection releases an arrived display once the other display's selection ends without dispatching", .timeLimit(.minutes(1)))
    func automaticSelectionAbandonsItsDisplay() async throws {
        let a = makeScreen(id: 69)
        let b = makeScreen(id: 70)
        let arrivals = Arrivals()
        let orchestrator = makeOrchestrator(screens: [a, b], available: { entry in
            !entry.id.hasPrefix("\(b.id)-")
        }, arrivals: arrivals)
        WallpaperSwitchGroup.$current.withValue(slowGroup(.automatic)) {
            orchestrator.advancePlaylist(for: a)
            orchestrator.advancePlaylist(for: b)
        }
        try await arrivals.waitUntilFinished([a.id], within: .seconds(5))
        #expect(arrivals.finished.contains(a.id), "A waited for B, which never dispatched")
        #expect(arrivals.starts[a.id] == nil)
    }
}

@MainActor
private final class ManualSwitchGroupTestPersistence: ScreenConfigurationPersisting {
    private var configurations: [ScreenConfiguration]

    init(_ configurations: [ScreenConfiguration]) {
        self.configurations = configurations
    }

    func getConfiguration(for screenID: CGDirectDisplayID) -> ScreenConfiguration? {
        configurations.first { $0.screenID == screenID }
    }

    func saveConfiguration(_ configuration: ScreenConfiguration) {
        configurations.removeAll { $0.screenID == configuration.screenID }
        configurations.append(configuration)
    }

    func cleanSettingsForScreen(_ screenID: CGDirectDisplayID) {
        configurations.removeAll { $0.screenID == screenID }
    }

    func loadConfigurations() -> [ScreenConfiguration] {
        configurations
    }

    func replaceAllConfigurations(_ configurations: [ScreenConfiguration]) {
        self.configurations = configurations
    }
}
