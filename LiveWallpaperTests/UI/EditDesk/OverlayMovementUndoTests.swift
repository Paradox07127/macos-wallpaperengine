import CoreGraphics
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

@Suite("Overlay movement undo through the editor and window history", .serialized)
@MainActor
struct OverlayMovementUndoTests {
    @Test("CPU drag commits one step; immediate Undo beats debounce, Redo restores only its position")
    func cpuDragUndoRedo() async throws {
        let rig = try MovementRig(#function)
        defer { rig.close() }
        let cpu = rig.cpu
        let other = rig.overlay.board.widgets[1]
        rig.session.select(.widget(cpu.id))
        let start = rig.session.interaction.pixelOrigin(for: cpu)
        rig.session.interaction.beginDrag(cpu.id, grabOffset: .zero)
        for offset in [30.0, 60, 120] {
            rig.session.interaction.updateDrag(pointInBoard: CGPoint(x: start.x + offset, y: start.y), bypassSnap: true)
            #expect(rig.stack.undoSteps.isEmpty, "Mouse-move frames must not be history entries")
        }
        rig.session.interaction.endDrag(bypassSnap: true)
        #expect(rig.stack.undoSteps.count == 1)
        let landed = try #require(rig.session.interaction.placements.first { $0.id == cpu.id })
        #expect(landed.x != cpu.x)
        let undone = await rig.stack.undo()
        #expect(undone?.restored == [rig.manager.left.name])
        #expect(rig.overlay.board.widgets.first { $0.id == cpu.id } == cpu)
        #expect(rig.overlay.board.widgets[1] == other)
        #expect(rig.session.interaction.placements.first { $0.id == cpu.id } == cpu)
        #expect(rig.session.selection == .widget(cpu.id))
        _ = await rig.stack.redo()
        #expect(rig.overlay.board.widgets.first { $0.id == cpu.id } == landed)
        #expect(rig.overlay.board.widgets[1] == other)
    }

    @Test("Clock and music drags each form exactly one step with inverse positions")
    func singletonDrags() async throws {
        for (index, target) in [OverlaySelection.clock, .music].enumerated() {
            let rig = try MovementRig("singletonDrags\(index)")
            defer { rig.close() }
            let before = try #require(OverlayObjectPosition.read(target, in: rig.overlay))
            rig.session.updateDrag(target, translation: CGSize(width: 40, height: 10), bypassSnap: true)
            rig.session.updateDrag(target, translation: CGSize(width: 80, height: 30), bypassSnap: true)
            #expect(rig.stack.undoSteps.isEmpty)
            rig.session.endDrag()
            #expect(rig.stack.undoSteps.count == 1)
            let after = try #require(OverlayObjectPosition.read(target, in: rig.overlay))
            #expect(before != after)
            _ = await rig.stack.undo()
            #expect(OverlayObjectPosition.read(target, in: rig.overlay) == before)
            _ = await rig.stack.redo()
            #expect(OverlayObjectPosition.read(target, in: rig.overlay) == after)
        }
    }

    @Test("A held Right arrow merges repeats; key up and the next press start another step")
    func keyPhasesDefineGrouping() async throws {
        let rig = try MovementRig(#function)
        defer { rig.close() }
        rig.session.select(.clock)
        let before = rig.overlay.clock.x
        rig.session.moveSelection(.right)
        for _ in 0 ..< 3 {
            rig.session.moveSelection(.right, isRepeat: true)
        }
        #expect(rig.stack.undoSteps.count == 1)
        #expect(abs(rig.overlay.clock.x - before - 40.0 / 1920.0) < 0.000001)
        rig.session.endKeyboardMove() // Key-up/focus loss routes here in OverlayCanvas.
        rig.session.moveSelection(.right)
        #expect(rig.stack.undoSteps.count == 2)
        _ = await rig.stack.undo()
        #expect(abs(rig.overlay.clock.x - before - 40.0 / 1920.0) < 0.000001)
        _ = await rig.stack.undo()
        #expect(rig.overlay.clock.x == before)
        _ = await rig.stack.redo()
        #expect(abs(rig.overlay.clock.x - before - 40.0 / 1920.0) < 0.000001)
        rig.session.moveSelection(.left, isRepeat: true)
        #expect(rig.stack.redoSteps.isEmpty, "Editing after Undo must discard the old redo branch")
    }

    @Test("Selection changes, directions, visibility commands and unrelated history never merge into a held key")
    func keyboardBoundaries() async throws {
        let rig = try MovementRig(#function)
        defer { rig.close() }
        rig.session.select(.clock)
        rig.session.moveSelection(.right)
        rig.session.select(.music)
        rig.session.moveSelection(.right, isRepeat: true)
        #expect(rig.stack.undoSteps.count == 2)
        rig.session.select(.clock)
        rig.session.moveSelection(.right, isRepeat: true)
        rig.session.moveSelection(.down, isRepeat: true)
        #expect(rig.stack.undoSteps.count == 4)
        rig.session.setMusicEnabled(false) // A non-history command must also end the keyboard group.
        rig.session.moveSelection(.down, isRepeat: true)
        #expect(rig.stack.undoSteps.count == 5)
        let bookmark = rig.bookmarks.add(label: "Before", content: .html(source: .inline("fixture"), config: .default))
        rig.bookmarks.rename(bookmark.id, to: "After")
        rig.stack.recordRename(of: bookmark)
        rig.session.moveSelection(.down, isRepeat: true)
        #expect(rig.stack.undoSteps.count == 7)
        _ = await rig.stack.undo()
        #expect(rig.bookmarks.bookmarks.first?.label == "After")
        _ = await rig.stack.undo()
        #expect(rig.bookmarks.bookmarks.first?.label == "Before")
    }

    @Test("Move, delete, Undo delete, Undo move, Redo move and Redo delete keep widget identity")
    func deleteHistoryInterleaves() async throws {
        let rig = try MovementRig(#function)
        defer { rig.close() }
        rig.session.select(.widget(rig.cpu.id))
        rig.session.moveSelection(.right)
        let moved = try #require(rig.session.interaction.placements.first { $0.id == rig.cpu.id })
        rig.session.deleteSelection()
        #expect(rig.stack.undoSteps.count == 2)
        #expect(rig.session.selection == nil)
        _ = await rig.stack.undo()
        #expect(rig.overlay.board.widgets.first { $0.id == rig.cpu.id } == moved)
        _ = await rig.stack.undo()
        #expect(rig.overlay.board.widgets.first { $0.id == rig.cpu.id } == rig.cpu)
        _ = await rig.stack.redo()
        #expect(rig.overlay.board.widgets.first { $0.id == rig.cpu.id } == moved)
        _ = await rig.stack.redo()
        #expect(!rig.overlay.board.widgets.contains { $0.id == rig.cpu.id })
        #expect(rig.overlay.board.widgets.count == 1)
    }

    @Test("Undo restores only x/y, preserving later clock size/opacity and other object settings")
    func positionPatchPreservesStyle() async throws {
        let rig = try MovementRig(#function)
        defer { rig.close() }
        let before = rig.overlay.clock.x
        rig.session.select(.clock)
        rig.session.moveSelection(.right)
        var edited = rig.overlay
        edited.clock.width = 600
        edited.clock.opacity = 0.4
        edited.music.x = 0.7
        rig.manager.setMonitorOverlay(edited, for: rig.manager.left)
        _ = await rig.stack.undo()
        #expect(rig.overlay.clock.x == before)
        #expect(rig.overlay.clock.width == 600)
        #expect(rig.overlay.clock.opacity == 0.4)
        #expect(rig.overlay.music.x == 0.7)
        _ = await rig.stack.redo()
        #expect(rig.overlay.clock.width == 600 && rig.overlay.clock.opacity == 0.4)
    }

    @Test("An externally moved or absent object is skipped rather than overwritten or resurrected")
    func refusesChangedPosition() async throws {
        let rig = try MovementRig(#function)
        defer { rig.close() }
        rig.session.select(.clock)
        rig.session.moveSelection(.right)
        var edited = rig.overlay
        edited.clock.x = 0.1
        rig.manager.setMonitorOverlay(edited, for: rig.manager.left)
        let outcome = await rig.stack.undo()
        #expect(outcome?.skipped.first?.reason == .changedAfterward)
        #expect(rig.overlay.clock.x == 0.1)
        #expect(rig.stack.redoSteps.isEmpty)
        rig.session.refreshAppliedConfiguration()
        rig.session.moveSelection(.right)
        edited = rig.overlay
        edited.clock.enabled = false
        rig.manager.setMonitorOverlay(edited, for: rig.manager.left)
        let missing = await rig.stack.undo()
        #expect(missing?.skipped.first?.reason == .changedAfterward)
        #expect(!rig.overlay.clock.enabled)
    }

    @Test("Undo during a live pointer gesture finishes that gesture before choosing the latest step")
    func undoWhileDragging() async throws {
        let rig = try MovementRig(#function)
        defer { rig.close() }
        let before = rig.overlay.clock
        rig.session.updateDrag(.clock, translation: CGSize(width: 100, height: 0), bypassSnap: true)
        #expect(rig.stack.undoSteps.isEmpty)
        let menu = EditDeskMenuUndoManager()
        menu.stack = rig.stack
        menu.route = { .stack }
        #expect(menu.canUndo, "Window Undo must be available before a live gesture has its final commit")
        let oldGeneration = rig.session.gestureGeneration
        let outcome = await rig.stack.undo()
        #expect(rig.session.gestureGeneration != oldGeneration)
        #expect(outcome?.action == .moveOverlayObject)
        #expect(rig.overlay.clock == before)
        #expect(rig.session.drag == nil)
        #expect(rig.stack.redoSteps.count == 1)
    }

    @Test("Click-only gestures and no-op drags do not create Undo steps")
    func noOpIsNotHistory() throws {
        let rig = try MovementRig(#function)
        defer { rig.close() }
        rig.session.interaction.beginDrag(rig.cpu.id, grabOffset: .zero)
        rig.session.interaction.endDrag(bypassSnap: true)
        rig.session.updateDrag(.clock, translation: .zero, bypassSnap: true)
        rig.session.endDrag()
        #expect(rig.stack.undoSteps.isEmpty)
    }
}

@MainActor
private final class MovementRig {
    let manager: UndoTestManager
    let cpu: MonitorWidgetPlacement
    let bookmarks: BookmarkStore
    let stack: EditDeskUndoStack
    let session: OverlayEditorSession
    let store: MovementStore
    let defaults: TestScratch.DefaultsSuite
    var overlay: MonitorOverlayConfiguration {
        manager.monitorOverlay(for: manager.left)
    }

    init(_ name: String) throws {
        let manager = UndoTestManager()
        let cpu = MonitorWidgetPlacement(kind: .cpu, size: .small, x: 0.1, y: 0.1)
        let defaults = try TestScratch.defaultsSuite(prefix: "LiveWallpaperTests.MovementUndo", function: name)
        let bookmarks = BookmarkStore(persistence: MovementBookmarks())
        let stack = EditDeskUndoStack(manager: manager,
                                      router: ApplyRouter(manager: manager, bookmarks: bookmarks, sceneCapable: true), bookmarks: bookmarks)
        let store = MovementStore(manager: manager)
        manager.setMonitorOverlay(MonitorOverlayConfiguration(enabled: true,
                                                              music: MusicOverlayConfiguration(enabled: true, x: 0.1, y: 0.7),
                                                              clock: ClockOverlayConfiguration(enabled: true),
                                                              board: MonitorBoardConfiguration(widgets: [cpu,
                                                                                                         MonitorWidgetPlacement(kind: .gpu, size: .small, x: 0.65, y: 0.1)])), for: manager.left)
        let session = OverlayEditorSession(defaults: defaults.defaults)
        session.transition(to: store.identity, store: store, editing: true)
        stack.overlayEditor = session
        self.manager = manager
        self.cpu = cpu
        self.defaults = defaults
        self.bookmarks = bookmarks
        self.stack = stack
        self.store = store
        self.session = session
        let screen = manager.left
        session.onObjectMoved = { [weak session] identity, move in
            guard identity.fingerprint == screen.displayFingerprint else { return }
            stack.recordMove(move, from: screen) { session?.flushPendingEdits() }
        }
        session.onWidgetsRemoved = { [weak session] removed in
            stack.recordRemoval(of: removed, from: screen) { session?.flushPendingEdits() }
        }
    }

    func close() {
        session.detach(); defaults.discard()
    }
}

@MainActor
private final class MovementStore: OverlayEditorStore {
    let manager: UndoTestManager
    init(manager: UndoTestManager) {
        self.manager = manager
    }

    var identity: OverlayEditorIdentity {
        OverlayEditorIdentity(displayID: manager.left.id, fingerprint: manager.left.displayFingerprint)
    }

    var displays: [OverlayEditorIdentity] {
        [identity]
    }

    func read(_ identity: OverlayEditorIdentity) -> OverlayEditorSnapshot? {
        guard identity == self.identity else { return nil }
        return OverlayEditorSnapshot(overlay: manager.monitorOverlay(for: manager.left),
                                     configuration: manager.getConfiguration(for: manager.left),
                                     logicalSize: CGSize(width: 1920, height: 1080), safeArea: .none)
    }

    func writeBoard(_ board: MonitorBoardConfiguration, for _: OverlayEditorIdentity) {
        manager.setMonitorOverlayBoard(board, for: manager.left)
    }

    func writeOverlayEnabled(_ enabled: Bool, for _: OverlayEditorIdentity) {
        var overlay = manager.monitorOverlay(for: manager.left); overlay.enabled = enabled
        manager.setMonitorOverlay(overlay, for: manager.left)
    }

    func writeMusic(_ music: MusicOverlayConfiguration, for _: OverlayEditorIdentity) {
        var overlay = manager.monitorOverlay(for: manager.left); overlay.music = music
        manager.setMonitorOverlay(overlay, for: manager.left)
    }

    func writeClock(_ clock: ClockOverlayConfiguration, for _: OverlayEditorIdentity) {
        var overlay = manager.monitorOverlay(for: manager.left); overlay.clock = clock
        manager.setMonitorOverlay(overlay, for: manager.left)
    }

    func writeEffect(_ effect: ParticleEffect, for _: OverlayEditorIdentity) {
        manager.updateParticleEffect(effect, for: manager.left)
    }

    func copy(_: OverlayKind, from _: OverlayEditorIdentity) {}
}

@MainActor
private final class MovementBookmarks: BookmarkPersisting {
    var entries: [WallpaperBookmark] = []
    func load() -> [WallpaperBookmark] {
        entries
    }

    func save(_ bookmarks: [WallpaperBookmark]) {
        entries = bookmarks
    }
}
