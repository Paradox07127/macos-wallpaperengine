import AppKit
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

@MainActor
@Suite("Overlay Remove All and the effect panel", .serialized)
struct OverlayRemoveAllTests {
    @Test("The effect is no layer: the layer list and the add strip leave it out")
    func effectIsNoLayer() {
        let rows = OverlayLayerList.rows(
            placements: [MonitorWidgetPlacement(kind: .cpu, size: .small, x: 0.1, y: 0.1)],
            boardEnabled: true, clockEnabled: true, musicEnabled: true
        )
        #expect(!OverlayLayerList.addItems.map(\.id).contains("effect"), "the add strip still offers the effect")
        #expect(OverlayLayerList.addItems.count == 13)
    }

    @Test("The effect panel's switch turns the effect on and off through the session, and is dead without a wallpaper")
    func effectPanelSwitch() throws {
        let panel = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Overlay/OverlayEffectPanel.swift")
        let toggle = try #require(panel.range(of: "Toggle(\"\", isOn: Binding(get: { session.effectVisible }, set: { session.setEffectVisible($0) }))"),
                                  "the panel's switch no longer reads and writes the session's effect")
        let modifiers = panel[toggle.upperBound...].prefix(400)
        #expect(modifiers.contains(".toggleStyle(.switch)"))
        #expect(modifiers.contains(".controlSize(.mini)"))
        #expect(modifiers.contains(".disabled(!session.canEditEffect)"))
        #expect(panel.contains("Text(\"Apply a wallpaper to enable effects\")"))
        #expect(panel.contains("copyLayer(.weather,"), "the effect title lost Copy to Other Displays")
        #expect(panel.contains("kind: .weather"))
        #expect(panel.contains("showsVisibilityControl: false"))
        #expect(panel.contains("session.refreshAppliedConfiguration()"))
        let workspace = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Overlay/OverlayWorkspace.swift")
        #expect(workspace.contains("OverlayEffectPanel("))
        let inspector = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Overlay/ObjectInspector.swift")
        #expect(!inspector.contains("OverlaysInspectorPanel("), "the object inspector still carries the effect panel")
    }

    @Test("Remove All clears widgets, clock, music and the effect as one undo step with one notice; one undo puts all of it back",
          .timeLimit(.minutes(1)))
    func removeAllIsOneStep() async throws {
        let manager = UndoTestManager()
        let screen = manager.left
        let bookmarks = BookmarkStore(persistence: RemoveAllBookmarks())
        let stack = EditDeskUndoStack(
            manager: manager,
            router: ApplyRouter(manager: manager, bookmarks: bookmarks, sceneCapable: true, confirmationTimeout: .seconds(5)),
            bookmarks: bookmarks
        )
        var notices: [String] = []
        stack.onRecord = { text, _ in notices.append(text) }
        let cpu = MonitorWidgetPlacement(kind: .cpu, size: .small, x: 0.1, y: 0.1)
        let gpu = MonitorWidgetPlacement(kind: .gpu, size: .small, x: 0.5, y: 0.4)
        manager.setMonitorOverlay(MonitorOverlayConfiguration(
            enabled: true, music: MusicOverlayConfiguration(enabled: true), clock: ClockOverlayConfiguration(enabled: true),
            board: MonitorBoardConfiguration(widgets: [cpu, gpu])
        ), for: screen)
        manager.updateParticleEffect(.rain, for: screen)
        let defaults = try #require(UserDefaults(suiteName: "OverlayRemoveAllTests"))
        defer { defaults.removePersistentDomain(forName: "OverlayRemoveAllTests") }
        let store = RemoveAllStore(manager: manager)
        let session = OverlayEditorSession(defaults: defaults)
        session.transition(to: store.identity, store: store, editing: true)
        defer { session.detach() }
        // Wired as `DisplayDetailHost` wires them, so a per-widget removal would show up as its own step.
        session.onWidgetsRemoved = { [weak session] removed in
            stack.recordRemoval(of: removed, from: screen) { session?.flushPendingEdits() }
        }
        session.onObjectsRemoved = { [weak session] objects in
            stack.recordRemoveAll(of: objects, from: screen) { session?.flushPendingEdits() }
        }
        #expect(session.hasObjects)

        session.removeAllObjects()
        // Past the canvas's debounced write, which would report per-widget removals late.
        try await Task.sleep(for: .milliseconds(400))

        let cleared = manager.monitorOverlay(for: screen)
        #expect(cleared.board.widgets.isEmpty, "widgets are left: \(cleared.board.widgets.map(\.kind))")
        #expect(!cleared.clock.enabled && !cleared.music.enabled)
        #expect(manager.getConfiguration(for: screen)?.particleEffect == ParticleEffect.none)
        #expect(session.interaction.placements.isEmpty && !session.hasObjects)
        #expect(stack.undoSteps.count == 1, "Remove All left \(stack.undoSteps.count) undo steps")
        #expect(stack.undoSteps.last?.action == .removeAllObjects)
        #expect(notices == [String(localized: "Remove All", bundle: .appLanguage)], "Remove All posted \(notices)")

        let undone = try #require(await stack.undo())
        #expect(undone.restored == [screen.name])
        let restored = manager.monitorOverlay(for: screen)
        #expect(restored.board.widgets == [cpu, gpu], "the widgets came back as \(restored.board.widgets)")
        #expect(restored.clock.enabled && restored.music.enabled)
        #expect(manager.getConfiguration(for: screen)?.particleEffect == .rain)
        session.refreshAppliedConfiguration()
        #expect(session.interaction.placements.map(\.id) == [cpu.id, gpu.id])
        #expect(session.effectVisible && session.hasObjects)
        #expect(notices.count == 1)
    }

    @Test("The detail host records Remove All on the window's undo stack, flushing the editor first")
    func hostRecordsRemoveAll() throws {
        let host = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Detail/DisplayDetailHost.swift")
        #expect(host.contains("session.onObjectsRemoved = { [weak session, undo] objects in"))
        #expect(host.contains("undo?.recordRemoveAll(of: objects, from: screen) { session?.flushPendingEdits() }"))
        let workspace = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Overlay/OverlayWorkspace.swift")
        #expect(workspace.contains("session.removeAllObjects()"))
        #expect(workspace.contains(".disabled(!session.hasObjects)"))
    }
}

@MainActor
private final class RemoveAllBookmarks: BookmarkPersisting {
    func load() -> [WallpaperBookmark] {
        []
    }

    func save(_: [WallpaperBookmark]) {}
}

/// The editor's store over `UndoTestManager`, so the session's writes and the undo stack's restores meet in one place.
@MainActor
private final class RemoveAllStore: OverlayEditorStore {
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
        return OverlayEditorSnapshot(
            overlay: manager.monitorOverlay(for: manager.left), configuration: manager.getConfiguration(for: manager.left),
            logicalSize: CGSize(width: 1728, height: 1117), safeArea: .none
        )
    }

    func writeBoard(_ board: MonitorBoardConfiguration, for _: OverlayEditorIdentity) {
        manager.setMonitorOverlayBoard(board, for: manager.left)
    }

    func writeOverlayEnabled(_ enabled: Bool, for _: OverlayEditorIdentity) {
        var overlay = manager.monitorOverlay(for: manager.left)
        overlay.enabled = enabled
        manager.setMonitorOverlay(overlay, for: manager.left)
    }

    func writeMusic(_ music: MusicOverlayConfiguration, for _: OverlayEditorIdentity) {
        var overlay = manager.monitorOverlay(for: manager.left)
        overlay.music = music
        manager.setMonitorOverlay(overlay, for: manager.left)
    }

    func writeClock(_ clock: ClockOverlayConfiguration, for _: OverlayEditorIdentity) {
        var overlay = manager.monitorOverlay(for: manager.left)
        overlay.clock = clock
        manager.setMonitorOverlay(overlay, for: manager.left)
    }

    func writeEffect(_ effect: ParticleEffect, for _: OverlayEditorIdentity) {
        manager.updateParticleEffect(effect, for: manager.left)
    }

    func copy(_: OverlayKind, from _: OverlayEditorIdentity) {}
}
