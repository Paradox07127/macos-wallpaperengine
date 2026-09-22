import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

@MainActor
@Suite("Overlay editor session")
struct OverlayEditorSessionTests {
    @Test("Music and clock clear the board selection; board selection returns to the session")
    func singleSelection() throws {
        let store = FakeOverlayStore()
        let session = opened(store)
        let id = try #require(session.interaction.placements.first?.id)
        session.select(.widget(id))
        session.select(.music)
        #expect(session.selection == .music)
        #expect(session.interaction.selectedID == nil)
        session.deleteSelection()
        #expect(session.interaction.placements.count == 1)
        session.interaction.select(id)
        #expect(session.selection == .widget(id))
        session.select(.clock)
        #expect(session.interaction.selectedID == nil)
        session.deleteSelection()
        #expect(session.interaction.placements.count == 1)
        session.interaction.select(id)
        session.deleteSelection()
        #expect(session.selection == nil)
        #expect(session.interaction.placements.isEmpty)
        session.detach()
    }

    @Test("Switching identity flushes the old writer before ending gestures, unbinding and loading")
    func identityTransitionOrder() throws {
        let store = FakeOverlayStore()
        let session = opened(store)
        let id = try #require(session.interaction.placements.first?.id)
        session.interaction.perform(.delete(id: id))
        session.onLifecycleStep = { step in store.events.append("\(step)") }
        store.events = []
        session.transition(to: store.displays[1], store: store, editing: true)
        #expect(store.events == ["flush", "board 1", "endGestures", "unbind", "load", "read 2"])
        #expect(store.snapshots[store.displays[0]]?.overlay.board.widgets.isEmpty == true)
        #expect(session.identity == store.displays[1])
        session.detach()
    }

    @Test("Closing flushes the pending board edit and commits the current gesture before unbinding")
    func closeCommitsFinalGesture() throws {
        let store = FakeOverlayStore()
        let session = opened(store)
        let placement = try #require(session.interaction.placements.first)
        session.interaction.moveWidget(id: placement.id, direction: .right)
        let start = try session.interaction.pixelOrigin(for: #require(session.interaction.placements.first))
        session.interaction.beginDrag(placement.id, grabOffset: .zero)
        session.interaction.updateDrag(pointInBoard: CGPoint(x: start.x + 180, y: start.y), bypassSnap: true)
        session.onLifecycleStep = { store.events.append("\($0)") }
        store.events = []
        session.detach()
        #expect(store.events == ["flush", "board 1", "endGestures", "board 1", "unbind"])
        let saved = try #require(store.snapshots[store.displays[0]]?.overlay.board.widgets.first)
        #expect(abs(saved.x * session.logicalSize.width - start.x - 180) < 0.5)
        #expect(session.interaction.drag == nil)
        #expect(session.interaction.onConfigurationEdited == nil)
        #expect(session.interaction.onSelectionChanged == nil)
        #expect(!session.isActive)
    }

    @Test("Switching sections retains selection and snap preference after flushing")
    func sectionTransition() throws {
        let store = FakeOverlayStore()
        let session = opened(store)
        let id = try #require(session.interaction.placements.first?.id)
        session.snapEnabled = false
        session.select(.widget(id))
        session.interaction.moveWidget(id: id, direction: .right)
        session.transition(to: store.displays[0], store: store, editing: false)
        #expect(!session.isActive && !session.snapEnabled)
        session.transition(to: store.displays[0], store: store, editing: true)
        #expect(session.selection == .widget(id))
        #expect(session.interaction.selectedID == id)
        #expect(!session.interaction.snapEnabled)
        session.detach()
    }

    @Test("Copy flushes first, calls all four kinds, and reports the target without weather as incomplete")
    func copyCount() throws {
        let store = FakeOverlayStore()
        let session = opened(store)
        let id = try #require(session.interaction.placements.first?.id)
        session.interaction.moveWidget(id: id, direction: .right)
        store.events = []
        let result = session.copyToOtherDisplays()
        #expect(result == OverlayEditorSession.CopyResult(copied: 1, total: 2))
        #expect(store.copiedKinds == OverlayKind.allCases)
        #expect(store.events.first == "board 1")
        let boardIndex = try #require(store.events.firstIndex(of: "board 1"))
        let copyIndex = try #require(store.events.firstIndex(where: { $0.hasPrefix("copy ") }))
        #expect(boardIndex < copyIndex)
        #expect(store.snapshots[store.displays[1]]?.overlay.board == store.snapshots[store.displays[0]]?.overlay.board)
        #expect(store.snapshots[store.displays[2]]?.configuration == nil)
        session.detach()
    }

    @Test("Missing source configuration skips effects and reports no complete copies")
    func copyWithoutSourceWallpaper() {
        let store = FakeOverlayStore()
        store.snapshots[store.displays[0]]?.configuration = nil
        let session = opened(store)
        #expect(!session.canEditEffect)
        #expect(session.copyToOtherDisplays() == OverlayEditorSession.CopyResult(copied: 0, total: 2))
        #expect(store.copiedKinds == OverlayKind.allCases)
        session.detach()
    }

    @Test("Music can overlap a widget without moving it; music and clock write only on release")
    func overlayDoesNotResolveBoardCollisions() throws {
        let store = FakeOverlayStore()
        let session = opened(store)
        session.snapEnabled = false
        let before = session.interaction.placements
        let widget = try #require(before.first)
        let target = session.interaction.geometry.renderRect(forRawRect: CGRect(
            origin: session.interaction.pixelOrigin(for: widget), size: session.interaction.footprint(for: widget)
        ))
        let music = session.rect(for: .music)
        store.events = []
        session.updateDrag(.music, translation: CGSize(width: target.minX - music.minX, height: target.minY - music.minY), bypassSnap: false)
        #expect(session.rect(for: .music).intersects(target))
        #expect(store.events.isEmpty)
        session.endDrag()
        #expect(session.interaction.placements == before)
        #expect(session.rect(for: .music).intersects(target))
        #expect(store.events == ["read 1", "music 1"])
        store.events = []
        session.updateDrag(.clock, translation: CGSize(width: 100, height: 50), bypassSnap: true)
        #expect(store.events.isEmpty)
        session.endDrag()
        #expect(store.events == ["read 1", "clock 1"])
        #expect(session.interaction.placements == before)
        session.detach()
    }

    @Test("Releasing a layer preserves unrelated configuration edited during the drag")
    func releaseUsesCurrentConfiguration() {
        let store = FakeOverlayStore()
        let session = opened(store)
        session.updateDrag(.music, translation: CGSize(width: 80, height: 0), bypassSnap: true)
        store.snapshots[store.displays[0]]?.overlay.music.level = .front
        session.endDrag()
        #expect(session.overlay.music.level == .front)
        #expect(store.snapshots[store.displays[0]]?.overlay.music.level == .front)
        session.updateDrag(.clock, translation: CGSize(width: 80, height: 0), bypassSnap: true)
        store.snapshots[store.displays[0]]?.overlay.clock.level = .front
        session.endDrag()
        #expect(session.overlay.clock.level == .front)
        #expect(store.snapshots[store.displays[0]]?.overlay.clock.level == .front)
        session.detach()
    }

    @Test("Selecting music without moving does not snap or write its position")
    func clickOnlySelects() {
        let store = FakeOverlayStore()
        let session = opened(store)
        let original = session.overlay.music
        store.events = []
        session.updateDrag(.music, translation: .zero, bypassSnap: false)
        session.endDrag()
        #expect(session.selection == .music)
        #expect(session.overlay.music == original)
        #expect(store.events.isEmpty)
        session.detach()
    }

    @Test("The board uses the editor's scaled threshold and can bypass snapping")
    func boardSnapInputs() throws {
        let store = FakeOverlayStore()
        let session = opened(store)
        session.renderScale = 0.2
        let id = try #require(session.interaction.placements.first?.id)
        session.interaction.beginDrag(id, grabOffset: .zero)
        session.interaction.updateDrag(pointInBoard: CGPoint(x: 60, y: 400), bypassSnap: false)
        #expect(session.interaction.drag?.snappedOrigin?.x == 0)
        session.interaction.updateDrag(pointInBoard: CGPoint(x: 80, y: 400), bypassSnap: false)
        #expect(session.interaction.drag?.guideX == nil)
        session.snapEnabled = false
        session.interaction.updateDrag(pointInBoard: CGPoint(x: 1, y: 400), bypassSnap: false)
        #expect(session.interaction.drag?.snappedOrigin == nil)
        session.detach()
    }

    @Test("Effects use the applied draft, remember their type, and are disabled without a configuration")
    func effectWriter() throws {
        let suite = "OverlayEditorSessionTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = FakeOverlayStore()
        store.snapshots[store.displays[0]]?.configuration?.particleEffect = .rain
        let session = OverlayEditorSession(defaults: defaults)
        session.transition(to: store.displays[0], store: store, editing: true)
        #expect(session.effectVisible && session.draft.selectedParticleEffect == .rain)
        session.setEffectVisible(false)
        #expect(!session.effectVisible)
        session.setEffectVisible(true)
        #expect(session.draft.selectedParticleEffect == .rain)
        session.transition(to: store.displays[2], store: store, editing: true)
        #expect(!session.canEditEffect && !session.effectVisible)
        store.events = []
        session.setEffectVisible(true)
        #expect(store.events.isEmpty)
        session.detach()
    }

    @Test("Music and clock switches write through the store and update the loaded overlay")
    func enabledWriters() {
        let store = FakeOverlayStore()
        let session = opened(store)
        store.events = []
        session.setMusicEnabled(false)
        #expect(store.snapshots[store.displays[0]]?.overlay.music.enabled == false)
        #expect(!session.overlay.music.enabled)
        #expect(store.events.contains("music 1"))
        session.setClockEnabled(false)
        #expect(store.snapshots[store.displays[0]]?.overlay.clock.enabled == false)
        #expect(!session.overlay.clock.enabled)
        #expect(store.events.contains("clock 1"))
        store.events = []
        session.setClockEnabled(false)
        #expect(!store.events.contains("clock 1"))
        session.setMusicEnabled(true)
        #expect(session.overlay.music.enabled)
        #expect(store.snapshots[store.displays[0]]?.overlay.music.enabled == true)
        session.detach()
    }

    @Test("Adding places a widget by first fit and reports a full board")
    func addWidgetReportsFullBoard() {
        let store = FakeOverlayStore()
        let session = opened(store)
        #expect(session.addWidget(kind: .gpu))
        #expect(session.interaction.placements.count == 2)
        #expect(session.interaction.placements.last?.kind == .gpu)
        session.detach()

        store.snapshots[store.displays[1]]?.logicalSize = CGSize(width: 200, height: 200)
        session.transition(to: store.displays[1], store: store, editing: true)
        #expect(!session.addWidget(kind: .gpu))
        #expect(session.interaction.placements.count == 1)
        session.detach()
    }

    @Test("Adding a widget to a switched-off board turns the board on first")
    func addWidgetEnablesBoard() {
        let store = FakeOverlayStore()
        store.snapshots[store.displays[0]]?.overlay.enabled = false
        let session = opened(store)
        store.events = []
        #expect(session.addWidget(kind: .gpu))
        #expect(store.snapshots[store.displays[0]]?.overlay.enabled == true)
        #expect(session.overlay.enabled)
        #expect(store.events.contains("enabled 1"))
        #expect(session.interaction.placements.count == 2)
        session.detach()
    }

    @Test("Adding to a board that is already on does not rewrite the switch")
    func addWidgetLeavesEnabledBoardAlone() {
        let store = FakeOverlayStore()
        let session = opened(store)
        store.events = []
        #expect(session.addWidget(kind: .gpu))
        #expect(!store.events.contains { $0.hasPrefix("enabled") })
        session.detach()
    }

    @Test("Removing a widget drops it and clears a selection that pointed at it")
    func removeWidgetClearsSelection() throws {
        let store = FakeOverlayStore()
        let session = opened(store)
        let id = try #require(session.interaction.placements.first?.id)
        session.select(.widget(id))
        session.removeWidget(id: id)
        #expect(session.interaction.placements.isEmpty)
        #expect(session.selection == nil)
        session.detach()
    }

    @Test("Removing an unselected widget leaves the current selection alone")
    func removeWidgetKeepsOtherSelection() throws {
        let store = FakeOverlayStore()
        let session = opened(store)
        let id = try #require(session.interaction.placements.first?.id)
        session.select(.music)
        session.removeWidget(id: id)
        #expect(session.interaction.placements.isEmpty)
        #expect(session.selection == .music)
        session.detach()
    }

    @Test("Persisted object hooks follow successful clock and music writes, never selection or disable")
    func objectPersistedSwitches() {
        let store = FakeOverlayStore()
        let session = opened(store)
        var calls = 0
        session.onObjectPersisted = { calls += 1 }
        session.setClockEnabled(false)
        session.select(.clock)
        #expect(calls == 0)
        session.setClockEnabled(true)
        #expect(calls == 1)
        session.setClockEnabled(true)
        #expect(calls == 1)
        session.setMusicEnabled(false)
        #expect(calls == 1)
        session.setMusicEnabled(true)
        #expect(calls == 2)
        session.detach()
    }

    @Test("Added widgets signal only after flush confirms their persisted identity")
    func objectPersistedAfterFlush() throws {
        let store = FakeOverlayStore()
        let session = opened(store)
        var calls = 0
        session.onObjectPersisted = {
            #expect(store.snapshots[store.displays[0]]?.overlay.board.widgets.count == 2)
            calls += 1
        }
        #expect(session.addWidget(kind: .gpu))
        #expect(calls == 0)
        session.flushPendingEdits()
        #expect(calls == 1)
        session.flushPendingEdits()
        let id = try #require(session.interaction.placements.last?.id)
        session.select(.widget(id))
        session.moveSelection(.right)
        session.flushPendingEdits()
        #expect(calls == 1)
        session.detach()
    }

    @Test("An addition removed before flush and a rejected write do not signal success")
    func objectPersistedRequiresReadback() throws {
        let store = FakeOverlayStore()
        let session = opened(store)
        var calls = 0
        session.onObjectPersisted = { calls += 1 }
        #expect(session.addWidget(kind: .gpu))
        try session.removeWidget(id: #require(session.interaction.placements.last?.id))
        session.flushPendingEdits()
        #expect(calls == 0)
        #expect(session.addWidget(kind: .gpu))
        store.rejectWrites = true
        session.flushPendingEdits()
        #expect(calls == 0)
        store.snapshots[store.displays[0]]?.overlay.clock.enabled = false
        session.setClockEnabled(true)
        #expect(calls == 0)
        session.detach()
    }

    private func opened(_ store: FakeOverlayStore) -> OverlayEditorSession {
        let session = OverlayEditorSession()
        session.transition(to: store.displays[0], store: store, editing: true)
        return session
    }
}

@MainActor
private final class FakeOverlayStore: OverlayEditorStore {
    let displays = (1 ... 3).map { OverlayEditorIdentity(displayID: UInt32($0), fingerprint: "screen-\($0)") }
    var snapshots: [OverlayEditorIdentity: OverlayEditorSnapshot] = [:]
    var events: [String] = []
    var copiedKinds: [OverlayKind] = []
    var rejectWrites = false

    init() {
        for identity in displays {
            var music = MusicOverlayConfiguration.default
            music.enabled = true
            music.x = 0.55
            music.y = 0.6
            var clock = ClockOverlayConfiguration.default
            clock.enabled = true
            clock.x = 0.1
            clock.y = 0.1
            let config = ScreenConfiguration(screenID: identity.displayID,
                                             wallpaper: .html(source: .inline("Test"), config: .default), particleEffect: .snow)
            snapshots[identity] = OverlayEditorSnapshot(
                overlay: MonitorOverlayConfiguration(enabled: true, music: music, clock: clock,
                                                     board: MonitorBoardConfiguration(widgets: [MonitorWidgetPlacement(kind: .cpu, size: .small, x: 0.3, y: 0.3)])),
                configuration: identity.displayID == 3 ? nil : config,
                logicalSize: CGSize(width: 2400, height: 1800), safeArea: .none
            )
        }
    }

    func read(_ identity: OverlayEditorIdentity) -> OverlayEditorSnapshot? {
        events.append("read \(identity.displayID)")
        return snapshots[identity]
    }

    func writeBoard(_ board: MonitorBoardConfiguration, for identity: OverlayEditorIdentity) {
        events.append("board \(identity.displayID)")
        if !rejectWrites {
            snapshots[identity]?.overlay.board = board
        }
    }

    func writeOverlayEnabled(_ enabled: Bool, for identity: OverlayEditorIdentity) {
        events.append("enabled \(identity.displayID)")
        snapshots[identity]?.overlay.enabled = enabled
    }

    func writeMusic(_ music: MusicOverlayConfiguration, for identity: OverlayEditorIdentity) {
        events.append("music \(identity.displayID)")
        snapshots[identity]?.overlay.music = music
    }

    func writeClock(_ clock: ClockOverlayConfiguration, for identity: OverlayEditorIdentity) {
        events.append("clock \(identity.displayID)")
        if !rejectWrites {
            snapshots[identity]?.overlay.clock = clock
        }
    }

    func writeEffect(_ effect: ParticleEffect, for identity: OverlayEditorIdentity) {
        events.append("effect \(identity.displayID)")
        snapshots[identity]?.configuration?.particleEffect = effect
    }

    func copy(_ kind: OverlayKind, from identity: OverlayEditorIdentity) {
        events.append("copy \(kind)")
        copiedKinds.append(kind)
        guard let source = snapshots[identity] else { return }
        for target in displays where target != identity {
            switch kind {
            case .monitor:
                snapshots[target]?.overlay.enabled = source.overlay.enabled
                snapshots[target]?.overlay.level = source.overlay.level
                snapshots[target]?.overlay.board = source.overlay.board
            case .music: snapshots[target]?.overlay.music = source.overlay.music
            case .clock: snapshots[target]?.overlay.clock = source.overlay.clock
            case .weather:
                if let configuration = source.configuration {
                    snapshots[target]?.configuration?.adoptWeatherOverlay(from: configuration)
                }
            }
        }
    }
}
