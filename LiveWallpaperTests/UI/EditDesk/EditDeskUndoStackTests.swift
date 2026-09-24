import AppKit
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

@MainActor
@Suite("Edit Desk undo stack", .serialized)
struct EditDeskUndoStackTests {
    private let manager = UndoTestManager()
    private let bookmarks = BookmarkStore(persistence: UndoTestBookmarks())

    private func stack(timeout: Duration = .seconds(5)) -> EditDeskUndoStack {
        EditDeskUndoStack(
            manager: manager,
            router: ApplyRouter(manager: manager, bookmarks: bookmarks, sceneCapable: true, confirmationTimeout: timeout),
            bookmarks: bookmarks
        )
    }

    /// The displays a configuration step names; empty for the other kinds.
    private static func fingerprints(_ step: EditDeskUndoStack.Step?) -> [String] {
        guard case let .displays(displays)? = step?.change else { return [] }
        return displays.map(\.fingerprint)
    }

    private static func page(_ name: String) -> WallpaperContent {
        .html(source: .inline(name), config: .default)
    }

    /// Records a confirmed apply of `content` on `screens`.
    @discardableResult
    private func apply(_ content: WallpaperContent, on screens: [Screen], in stack: EditDeskUndoStack) -> UUID? {
        let recording = stack.begin(.applyWallpaper, displays: screens)
        var stepID: UUID?
        for screen in screens {
            manager.show(content, on: screen)
            stepID = recording.settle(screen.id, applied: true) ?? stepID
        }
        return stepID
    }

    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline {
            await Task.yield()
        }
        #expect(condition())
    }

    @Test("Undo restores the rebound configuration from before the apply; redo restores the one undo replaced", .timeLimit(.minutes(1)))
    func undoRestoresBeforeAndRedoRestoresAfter() async throws {
        let stack = stack()
        let before = try #require(manager.configuration(on: manager.left))
        let stepID = try #require(apply(Self.page("B"), on: [manager.left], in: stack))
        let moved = manager.reconnect(manager.left)
        let applied = try #require(manager.configuration(on: moved))

        let undone = try #require(await stack.undo())
        #expect(undone.stepID == stepID)
        #expect(undone.restored == [moved.name])
        #expect(manager.restores.map(\.configuration) == [before.reboundToDisplay(moved.id, fingerprint: moved.displayFingerprint)])
        #expect(stack.undoSteps.isEmpty)
        #expect(stack.redoSteps.count == 1)

        _ = try #require(await stack.redo())
        #expect(manager.restores.last?.configuration == applied)
        #expect(stack.undoSteps.count == 1)
        #expect(stack.redoSteps.isEmpty)
    }

    @Test("Undoing a clear puts the configuration back; redoing it clears again", .timeLimit(.minutes(1)))
    func clearUndoRedo() async throws {
        let stack = stack()
        let before = try #require(manager.configuration(on: manager.left))
        let recording = stack.begin(.clearWallpaper, displays: [manager.left])
        manager.clearWallpaperForScreen(manager.left)
        _ = try #require(await recording.settle(showing: nil))
        manager.cleared.removeAll()

        _ = try #require(await stack.undo())
        #expect(manager.restores.map(\.configuration) == [before.reboundToDisplay(manager.left.id, fingerprint: manager.left.displayFingerprint)])
        #expect(manager.configuration(on: manager.left)?.activeWallpaper == before.activeWallpaper)

        _ = try #require(await stack.redo())
        #expect(manager.cleared == [manager.left.id])
        #expect(manager.configuration(on: manager.left) == nil)
        #expect(stack.undoSteps.map(\.action) == [.clearWallpaper])
    }

    @Test("Applying to every display is one step, holding only the displays that took it")
    func applyToAllIsOneStepOfConfirmedDisplays() throws {
        let stack = stack()
        let recording = stack.begin(.applyToAllDisplays, displays: [manager.left, manager.right])
        manager.show(Self.page("B"), on: manager.left)
        #expect(recording.settle(manager.left.id, applied: true) == nil, "recorded before every display had settled")
        let stepID = try #require(recording.settle(manager.right.id, applied: false))
        #expect(stack.undoSteps.map(\.id) == [stepID])
        #expect(Self.fingerprints(stack.undoSteps.first) == [manager.left.displayFingerprint])
    }

    @Test("The 21st step drops the oldest, and a new step empties the redo stack", .timeLimit(.minutes(1)))
    func twentyStepsAndANewStepClearsRedo() async throws {
        let stack = stack()
        let ids = (0 ..< 21).map { apply(Self.page("Step \($0)"), on: [manager.left], in: stack) }
        #expect(stack.undoSteps.count == 20)
        #expect(stack.undoSteps.first?.id == ids[1])
        _ = try #require(await stack.undo())
        #expect(stack.redoSteps.count == 1)
        apply(Self.page("New"), on: [manager.left], in: stack)
        #expect(stack.redoSteps.isEmpty)
    }

    @Test("A display changed from outside the stack is skipped without a restore, and the step is gone", .timeLimit(.minutes(1)))
    func outsideChangeIsSkipped() async throws {
        let stack = stack()
        let stepID = try #require(apply(Self.page("B"), on: [manager.left], in: stack))
        manager.show(Self.page("C"), on: manager.left)
        let outcome = try #require(await stack.undo())
        #expect(outcome.stepID == stepID)
        #expect(outcome.skipped == [.init(name: manager.left.name, reason: .changedAfterward)])
        #expect(manager.restores.isEmpty)
        #expect(stack.undoSteps.isEmpty)
        #expect(stack.redoSteps.isEmpty)
    }

    @Test("Same content but a schedule or playlist switch since: skipped, naming that source", .timeLimit(.minutes(1)))
    func automaticSwitchIsSkipped() async throws {
        let stack = stack()
        apply(Self.page("B"), on: [manager.left], in: stack)
        apply(Self.page("B2"), on: [manager.right], in: stack)
        manager.noteSwitch(on: manager.left, .schedule)
        manager.noteSwitch(on: manager.right, .playlist)
        let playlist = try #require(await stack.undo())
        #expect(playlist.skipped == [.init(name: manager.right.name, reason: .automaticSwitch(.playlist))])
        let schedule = try #require(await stack.undo())
        #expect(schedule.skipped == [.init(name: manager.left.name, reason: .automaticSwitch(.schedule))])
        #expect(manager.restores.isEmpty)
    }

    @Test("In a two-display step a changed display is skipped, the other is restored, and redo holds only it", .timeLimit(.minutes(1)))
    func oneDisplayOfAStepIsSkipped() async throws {
        let stack = stack()
        apply(Self.page("B"), on: [manager.left, manager.right], in: stack)
        manager.show(Self.page("C"), on: manager.right)
        let outcome = try #require(await stack.undo())
        #expect(outcome.restored == [manager.left.name])
        #expect(outcome.skipped == [.init(name: manager.right.name, reason: .changedAfterward)])
        #expect(manager.restores.map(\.screenID) == [manager.left.id])
        #expect(stack.redoSteps.map(Self.fingerprints) == [[manager.left.displayFingerprint]])
    }

    @Test("A disconnected display is skipped; a restore that never confirms fails and stays off the redo stack", .timeLimit(.minutes(1)))
    func disconnectedAndUnconfirmed() async throws {
        let stack = stack(timeout: .milliseconds(200))
        apply(Self.page("B"), on: [manager.right], in: stack)
        apply(Self.page("B2"), on: [manager.left], in: stack)
        manager.confirmsRestores = false
        let unconfirmed = try #require(await stack.undo())
        #expect(unconfirmed.failed == [manager.left.name])
        #expect(unconfirmed.restored.isEmpty)
        #expect(stack.redoSteps.isEmpty)

        let unplugged = manager.right
        manager.disconnect(unplugged)
        let skipped = try #require(await stack.undo())
        #expect(skipped.skipped == [.init(name: unplugged.name, reason: .disconnected)])
        #expect(manager.restores.map(\.screenID) == [manager.left.id], "a disconnected display was restored")
    }

    @Test("Undo waits for a change still settling and undoes that change", .timeLimit(.minutes(1)))
    func undoWaitsForAnUnsettledChange() async throws {
        let stack = stack()
        apply(Self.page("B"), on: [manager.right], in: stack)
        let recording = stack.begin(.applyWallpaper, displays: [manager.left])
        let undo = Task { await stack.undo() }
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        #expect(manager.restores.isEmpty, "undid an older step instead of waiting")
        manager.show(Self.page("C"), on: manager.left)
        recording.settle(manager.left.id, applied: true)
        let outcome = try #require(await undo.value)
        #expect(outcome.stepID == recording.id)
        #expect(manager.restores.map(\.screenID) == [manager.left.id])
    }

    @Test("Two undos run one after the other, and a step recorded during an undo keeps its result off the redo stack", .timeLimit(.minutes(1)))
    func undosRunInOrder() async throws {
        let stack = stack()
        apply(Self.page("B"), on: [manager.left], in: stack)
        let newer = try #require(apply(Self.page("B2"), on: [manager.right], in: stack))
        manager.confirmsRestores = false
        let first = Task { await stack.undo() }
        let second = Task { await stack.undo() }
        await waitUntil { manager.restores.count == 1 }
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        #expect(manager.restores.map(\.screenID) == [manager.right.id], "the second undo started before the first finished")

        let fresh = try #require(apply(Self.page("E"), on: [manager.left], in: stack))
        manager.commitHeldRestores()
        let firstOutcome = await first.value
        #expect(firstOutcome?.stepID == newer)
        await waitUntil { manager.restores.count == 2 }
        manager.commitHeldRestores()
        let secondOutcome = await second.value
        #expect(secondOutcome?.stepID == fresh)
        #expect(
            stack.redoSteps.map(Self.fingerprints) == [[manager.left.displayFingerprint]],
            "the first undo's result reached the redo stack after a newer step"
        )
    }

    @Test("removeAll empties both stacks; ⌘Z goes to a text field being edited and to the stack otherwise", .timeLimit(.minutes(1)))
    func removeAllAndKeyRoute() async throws {
        let stack = stack()
        apply(Self.page("B"), on: [manager.left], in: stack)
        apply(Self.page("B2"), on: [manager.right], in: stack)
        _ = try #require(await stack.undo())
        #expect(stack.undoSteps.count == 1)
        #expect(stack.redoSteps.count == 1)
        stack.removeAll()
        #expect(stack.undoSteps.isEmpty)
        #expect(stack.redoSteps.isEmpty)

        #expect(EditDeskUndoKeyRoute.route(firstResponder: NSTextView(), keyWindowIsMain: true) == .text)
        #expect(EditDeskUndoKeyRoute.route(firstResponder: NSView(), keyWindowIsMain: true) == .stack)
        #expect(EditDeskUndoKeyRoute.route(firstResponder: nil, keyWindowIsMain: true) == .stack)
    }

    @Test("While a sheet, panel or popover is key, ⌘Z leaves the stack alone; a text field there keeps its own undo")
    func keyRouteIgnoresAnotherKeyWindow() {
        #expect(EditDeskUndoKeyRoute.route(firstResponder: NSView(), keyWindowIsMain: false) == .ignore)
        #expect(EditDeskUndoKeyRoute.route(firstResponder: nil, keyWindowIsMain: false) == .ignore)
        #expect(EditDeskUndoKeyRoute.route(firstResponder: NSTextView(), keyWindowIsMain: false) == .text)
    }

    @Test("A deadline whose sleep ends after its wait did cannot resume the next command's wait")
    func deadlineResumesOnlyItsOwnWait() throws {
        let source = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Support/EditDeskUndoStack.swift")
        let start = try #require(source.range(of: "private func waitForPendingRecordings()"))
        let body = try #require(source[start.upperBound...].components(separatedBy: "\n    }\n").first)
        let sleep = try #require(body.range(of: "try await Task.sleep(for: timeout)"))
        let resume = try #require(body.range(of: "settleWaiter?.resume()"))
        let check = body.range(of: "guard !Task.isCancelled else { return }")
        #expect(
            check.map { sleep.upperBound < $0.lowerBound && $0.upperBound < resume.lowerBound } == true,
            "a deadline already past its sleep when its wait ended resumes whichever wait is current"
        )
    }

    @Test("A removed library entry goes back at its old index with its ID; redo takes it out; its cover is kept meanwhile", .timeLimit(.minutes(1)))
    func removedBookmarkComesBack() async throws {
        let stack = stack()
        var announced: [UUID] = []
        stack.onRecord = { _, stepID in announced.append(stepID) }
        let first = bookmarks.add(label: "First", content: Self.page("1"))
        let middle = bookmarks.add(label: "Middle", content: Self.page("2"))
        let last = bookmarks.add(label: "Last", content: Self.page("3"))
        bookmarks.setCover("middle.png", for: middle.id)
        let removed = try #require(bookmarks.bookmarks.first { $0.id == middle.id })
        bookmarks.remove(middle.id)

        stack.recordRemoval(of: removed, at: 1)
        #expect(announced == stack.undoSteps.map(\.id))
        #expect(stack.retainedCoverFileNames == ["middle.png"])

        let undone = try #require(await stack.undo())
        #expect(undone.restored == ["Middle"])
        #expect(bookmarks.bookmarks.map(\.id) == [first.id, middle.id, last.id])
        #expect(bookmarks.bookmarks.dropFirst().first == removed)

        _ = try #require(await stack.redo())
        #expect(bookmarks.bookmarks.map(\.id) == [first.id, last.id])
        #expect(stack.retainedCoverFileNames == ["middle.png"], "undo can bring the entry back again")
    }

    @Test("A removed widget goes back at its old index after the editor's pending write lands; redo takes it off by ID", .timeLimit(.minutes(1)))
    func removedWidgetComesBack() async throws {
        let stack = stack()
        let cpu = MonitorWidgetPlacement(kind: .cpu, size: .small, x: 0.1, y: 0.1)
        let gpu = MonitorWidgetPlacement(kind: .gpu, size: .small, x: 0.5, y: 0.1)
        manager.setMonitorOverlayBoard(MonitorBoardConfiguration(widgets: [cpu, gpu]), for: manager.left)
        // The editor still holds the debounced write without the CPU widget; a widget moved into its spot since.
        let pending = MonitorBoardConfiguration(widgets: [gpu, MonitorWidgetPlacement(kind: .memory, size: .small, x: 0.1, y: 0.1)])
        var flushes = 0
        stack.recordRemoval(of: [(cpu, 0)], from: manager.left) {
            flushes += 1
            manager.setMonitorOverlayBoard(pending, for: manager.left)
        }

        let undone = try #require(await stack.undo())
        #expect(undone.restored == [manager.left.name])
        #expect(flushes == 1)
        #expect(manager.monitorOverlay(for: manager.left).board.widgets == [cpu] + pending.widgets, "the pending write landed over the restored widget")

        _ = try #require(await stack.redo())
        #expect(flushes == 2)
        #expect(manager.monitorOverlay(for: manager.left).board.widgets == pending.widgets)
    }

    @Test("Undoing a scene change lands the owner's pending edit, then commits the earlier descriptor; another scene there is skipped", .timeLimit(.minutes(1)))
    func sceneChangeUndoesAfterTheFlush() async throws {
        let stack = stack()
        let before = SceneDescriptor(workshopID: "123", cacheRelativePath: "123", entryFile: "scene.json", capabilityTier: .imageOnly)
        manager.show(.scene(before.withPresetLayer(id: "night", snapshot: [:])), on: manager.left)
        var events: [String] = []
        manager.onSceneUpdate = { events.append("update \($0.presetID ?? "none")") }
        stack.recordSceneChange(.changePreset, from: before, on: manager.left) { events.append("flush") }

        let undone = try #require(await stack.undo())
        #expect(undone.restored == [manager.left.name])
        #expect(events == ["flush", "update none"])
        #expect(manager.configuration(on: manager.left)?.activeWallpaper == .scene(before))

        let other = SceneDescriptor(workshopID: "456", cacheRelativePath: "456", entryFile: "scene.json", capabilityTier: .imageOnly)
        manager.show(.scene(other), on: manager.left)
        let redone = try #require(await stack.redo())
        #expect(redone.skipped == [.init(name: manager.left.name, reason: .changedAfterward)])
        #expect(events == ["flush", "update none"], "a scene that is no longer on the display was flushed or committed")
    }
}

@MainActor
private final class UndoTestBookmarks: BookmarkPersisting {
    func load() -> [WallpaperBookmark] {
        []
    }

    func save(_: [WallpaperBookmark]) {}
}

/// No display number, so the fingerprint comes from the name and the ID from the frame.
private final class UndoTestNSScreen: NSScreen {
    var name = ""
    var origin = CGPoint.zero

    override var frame: NSRect {
        NSRect(origin: origin, size: CGSize(width: 800, height: 600))
    }

    override var deviceDescription: [NSDeviceDescriptionKey: Any] {
        [:]
    }

    override var localizedName: String {
        name
    }

    /// AppKit's own description traps on a screen with no display behind it, and a failed
    /// expectation describes every `Screen` it captured.
    override var debugDescription: String {
        name
    }
}

/// Also drives the undo stack in `ModalActionsTests`.
@MainActor
final class UndoTestManager: UndoRestoring {
    struct Restore: Equatable {
        let screenID: CGDirectDisplayID
        let configuration: ScreenConfiguration
        let overlay: MonitorOverlayConfiguration?
    }

    private(set) var left = UndoTestManager.makeScreen("Undo Left", x: 0)
    private(set) var right = UndoTestManager.makeScreen("Undo Right", x: 800)
    private var unplugged: Set<CGDirectDisplayID> = []
    private var configurations: [CGDirectDisplayID: ScreenConfiguration] = [:]
    private var marks: [String: AutomaticSwitchMark] = [:]
    private var overlays: [String: MonitorOverlayConfiguration] = [:]
    private var held: [Restore] = []
    private(set) var restores: [Restore] = []
    var cleared: [CGDirectDisplayID] = []
    /// When false a restore waits in `held` until `commitHeldRestores()`.
    var confirmsRestores = true
    var onSceneUpdate: (SceneDescriptor) -> Void = { _ in }

    init() {
        for (screen, name) in [(left, "A"), (right, "A2")] {
            configurations[screen.id] = ScreenConfiguration(screenID: screen.id, wallpaper: .html(source: .inline(name), config: .default))
        }
    }

    static func makeScreen(_ name: String, x: CGFloat) -> Screen {
        let nsScreen = UndoTestNSScreen()
        nsScreen.name = name
        nsScreen.origin = CGPoint(x: x, y: 0)
        return Screen(nsScreen: nsScreen)
    }

    var screens: [Screen] {
        [left, right].filter { !unplugged.contains($0.id) }
    }

    func configuration(on screen: Screen) -> ScreenConfiguration? {
        configurations[screen.id]
    }

    func show(_ content: WallpaperContent, on screen: Screen) {
        configurations[screen.id]?.activeWallpaper = content
    }

    /// The same panel back under another display ID.
    func reconnect(_ screen: Screen) -> Screen {
        let moved = Self.makeScreen(screen.name, x: screen.frame.minX + 4000)
        configurations[moved.id] = configurations.removeValue(forKey: screen.id)?
            .reboundToDisplay(moved.id, fingerprint: moved.displayFingerprint)
        if screen === left {
            left = moved
        } else {
            right = moved
        }
        return moved
    }

    func disconnect(_ screen: Screen) {
        unplugged.insert(screen.id)
    }

    func noteSwitch(on screen: Screen, _ source: AutomaticSwitchMark.Source) {
        let serial = (marks[screen.displayFingerprint]?.serial ?? 0) + 1
        marks[screen.displayFingerprint] = AutomaticSwitchMark(serial: serial, source: source)
    }

    func commitHeldRestores() {
        let committing = held
        held.removeAll()
        committing.forEach(commit)
    }

    private func commit(_ restore: Restore) {
        configurations[restore.screenID] = restore.configuration
        NotificationCenter.default.post(name: .wallpaperConfigurationDidChange, object: nil, userInfo: ["screenID": restore.screenID])
    }

    // MARK: UndoRestoring

    func restoreRecordedConfiguration(
        _ configuration: ScreenConfiguration, overlay: MonitorOverlayConfiguration?, on screen: Screen
    ) {
        let restore = Restore(screenID: screen.id, configuration: configuration, overlay: overlay)
        restores.append(restore)
        if confirmsRestores {
            commit(restore)
        } else {
            held.append(restore)
        }
    }

    func clearWallpaperForScreen(_ screen: Screen) {
        cleared.append(screen.id)
        configurations[screen.id] = nil
    }

    func monitorOverlay(for screen: Screen) -> MonitorOverlayConfiguration {
        overlays[screen.displayFingerprint] ?? .default
    }

    func setMonitorOverlayBoard(_ board: MonitorBoardConfiguration, for screen: Screen) {
        var overlay = monitorOverlay(for: screen)
        overlay.board = board
        overlays[screen.displayFingerprint] = overlay
    }

    func updateSceneDescriptor(_ descriptor: SceneDescriptor, for screen: Screen) async {
        onSceneUpdate(descriptor)
        configurations[screen.id]?.activeWallpaper = .scene(descriptor)
    }

    func automaticSwitchMark(for fingerprint: String) -> AutomaticSwitchMark? {
        marks[fingerprint]
    }

    // MARK: WallpaperApplying

    func screen(withID id: CGDirectDisplayID) -> Screen? {
        screens.first { $0.id == id }
    }

    func getConfiguration(for screen: Screen) -> ScreenConfiguration? {
        configurations[screen.id]
    }

    func updateVideoDisplayMode(_: VideoDisplayMode, for _: Screen) {}
    func applyBookmark(_: WallpaperBookmark, to _: Screen) {}
    func setVideo(url _: URL, bookmarkData _: Data, packageEntryName _: String?, for _: Screen) {}
    func setHTMLWallpaperPreservingConfig(source _: HTMLSource, for _: Screen) {}
    func applyScheme(_: ScreenScheme, to _: Screen) {}
    func captureCover(forBookmark _: UUID, from _: Screen) {}
    func replaceWallpaperQueue(_: [WallpaperQueueEntry], for _: Screen) {}
    func cancelPreparation(for _: Screen) {}

    func isCurrentPreparation(generation _: Int?, attemptID _: UUID?, on _: Screen) -> Bool {
        false
    }

    #if !LITE_BUILD
    func setSceneWallpaper(descriptor _: SceneDescriptor, origin _: WPEOrigin?, for _: Screen) {}

    func importWallpaperEngineProject(at _: URL, for _: Screen) async -> ScreenManager.WPEProjectApplyOutcome {
        .rejected(reason: "Not used by undo")
    }

    func activateWPEHistoryEntry(_: WPEHistoryEntry, for _: Screen) async {}
    #endif
}
