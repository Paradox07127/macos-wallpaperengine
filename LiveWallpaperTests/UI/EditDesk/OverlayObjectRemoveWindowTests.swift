import AppKit
@testable import LiveWallpaper
import LiveWallpaperCore
import SwiftUI
import Testing

/// The canvas objects' corner remove button, clicked with real mouse events in a window parked off screen.
/// An offscreen SwiftUI host has no accessibility tree, so VoiceOver's Remove is driven as its session call; `OverlayRuntimeContractTests` ties the two.
/// The canvas draws the 1728×1117 board at half size, so one board point is half a window point.
@Suite("Overlay object remove button in a window", .serialized)
@MainActor
struct OverlayObjectRemoveWindowTests {
    enum Object: CaseIterable, Sendable {
        case widget, clock, music
    }

    enum Path: CaseIterable, Sendable {
        case removeButton, voiceOver
    }

    @Test("Clicking a selected widget's corner button removes the widget as one undo step with one notice", .timeLimit(.minutes(1)))
    func removesWidget() async throws {
        let fixture = RemoveWindowFixture(overlay: MonitorOverlayConfiguration(
            enabled: true, board: MonitorBoardConfiguration(widgets: [MonitorWidgetPlacement(kind: .cpu, size: .small, x: 0.3, y: 0.4)])
        ))
        defer { fixture.close() }
        let widget = try #require(fixture.session.interaction.placements.first)
        #expect(fixture.session.interaction.placements.count == 1)
        fixture.session.select(.widget(widget.id))
        let geometry = fixture.session.interaction.geometry
        let footprint = fixture.session.interaction.footprint(for: widget)
        let origin = geometry.clampOrigin(fixture.session.interaction.pixelOrigin(for: widget), footprint: footprint)
        let tile = geometry.renderRect(forRawRect: CGRect(origin: origin, size: footprint))
        await fixture.click(board: fixture.button(corner: CGPoint(x: tile.maxX, y: tile.minY)))
        #expect(await fixture.settle { fixture.session.interaction.placements.isEmpty }, "the corner button did not remove the widget")
        #expect(await fixture.settle { fixture.store.snapshot.overlay.board.widgets.isEmpty }, "the removal never reached the store")
        #expect(fixture.stack.undoSteps.map(\.action) == [.removeWidget])
        #expect(fixture.notices == [RemoveWindowFixture.widgetRemoved])
    }

    @Test("The button sits in from the corner, so a click a corner-centred button missed removes the widget")
    func buttonSitsInsideTheCorner() async throws {
        let fixture = RemoveWindowFixture(overlay: MonitorOverlayConfiguration(
            enabled: true, board: MonitorBoardConfiguration(widgets: [MonitorWidgetPlacement(kind: .cpu, size: .small, x: 0.3, y: 0.4)])
        ))
        defer { fixture.close() }
        let widget = try #require(fixture.session.interaction.placements.first)
        fixture.session.select(.widget(widget.id))
        let geometry = fixture.session.interaction.geometry
        let footprint = fixture.session.interaction.footprint(for: widget)
        let origin = geometry.clampOrigin(fixture.session.interaction.pixelOrigin(for: widget), footprint: footprint)
        let tile = geometry.renderRect(forRawRect: CGRect(origin: origin, size: footprint))
        // 8pt left of the button's centre on screen: inside its 10pt radius, 12pt from the corner and outside a circle centred there.
        let centre = fixture.button(corner: CGPoint(x: tile.maxX, y: tile.minY))
        await fixture.click(board: CGPoint(x: centre.x - 8 / fixture.renderScale, y: centre.y))
        #expect(await fixture.settle { fixture.session.interaction.placements.isEmpty }, "the click landed on the widget, not its remove button")
    }

    @Test("Clicking the selected Clock or Music layer's corner button turns that layer off", .timeLimit(.minutes(1)),
          arguments: [Object.clock, .music])
    func removesLayer(_ object: Object) async throws {
        let fixture = RemoveWindowFixture(overlay: RemoveWindowFixture.layers)
        defer { fixture.close() }
        let selection = try fixture.selection(object)
        #expect(fixture.isOn(selection, in: fixture.session.overlay))
        fixture.session.select(selection)
        await fixture.click(board: fixture.button(corner: fixture.corner(of: selection)))
        #expect(await fixture.settle { !fixture.isOn(selection, in: fixture.session.overlay) }, "the corner button did not turn the layer off")
        #expect(fixture.store.snapshot.overlay.clock.enabled == (selection != .clock))
        #expect(fixture.store.snapshot.overlay.music.enabled == (selection != .music))
    }

    @Test("VoiceOver's Remove makes the corner button's session call: the object goes, a widget as one undo step with one notice",
          .timeLimit(.minutes(1)), arguments: Object.allCases)
    func voiceOverRemoves(_ object: Object) async throws {
        let fixture = RemoveWindowFixture(overlay: object == .widget ? RemoveWindowFixture.widget : RemoveWindowFixture.layers)
        defer { fixture.close() }
        let selection = try fixture.selection(object)
        fixture.voiceOverRemove(selection)
        if object == .widget {
            #expect(fixture.session.interaction.placements.isEmpty)
            #expect(await fixture.settle { fixture.store.snapshot.overlay.board.widgets.isEmpty }, "the removal never reached the store")
            #expect(fixture.stack.undoSteps.map(\.action) == [.removeWidget])
            #expect(fixture.notices == [RemoveWindowFixture.widgetRemoved])
        } else {
            #expect(!fixture.isOn(selection, in: fixture.session.overlay))
            #expect(fixture.store.snapshot.overlay.clock.enabled == (selection != .clock))
            #expect(fixture.store.snapshot.overlay.music.enabled == (selection != .music))
        }
    }

    @Test("With the session inactive, neither the corner button nor VoiceOver's Remove changes anything",
          .timeLimit(.minutes(1)), arguments: Object.allCases, Path.allCases)
    func inactiveSessionKeepsObjects(_ object: Object, _ path: Path) async throws {
        let overlay = object == .widget ? RemoveWindowFixture.widget : RemoveWindowFixture.layers
        let fixture = RemoveWindowFixture(overlay: overlay, editing: false)
        defer { fixture.close() }
        let selection = try fixture.selection(object)
        fixture.session.select(selection)
        switch path {
        case .removeButton:
            await fixture.click(board: fixture.button(corner: fixture.corner(of: selection)))
        case .voiceOver:
            fixture.voiceOverRemove(selection)
        }
        // Past the canvas's debounced board write.
        try await Task.sleep(for: .milliseconds(400))
        #expect(fixture.store.snapshot.overlay == overlay)
        #expect(fixture.session.overlay == overlay)
        #expect(fixture.session.interaction.placements.map(\.id) == overlay.board.widgets.map(\.id))
        #expect(fixture.stack.undoSteps.isEmpty && fixture.notices.isEmpty)
    }
}

@MainActor
private final class RemoveWindowFixture {
    private static let logicalSize = CGSize(width: 1728, height: 1117)
    private static let scale: CGFloat = 0.5
    let store: RemoveWindowStore
    let session = OverlayEditorSession(defaults: UserDefaults(suiteName: "OverlayObjectRemoveWindowTests") ?? .standard)
    let stack: EditDeskUndoStack
    private(set) var notices: [String] = []
    let window: NSWindow
    private let size = CGSize(width: logicalSize.width * scale, height: logicalSize.height * scale)

    static var widget: MonitorOverlayConfiguration {
        MonitorOverlayConfiguration(
            enabled: true, board: MonitorBoardConfiguration(widgets: [MonitorWidgetPlacement(kind: .cpu, size: .small, x: 0.3, y: 0.4)])
        )
    }

    static var layers: MonitorOverlayConfiguration {
        MonitorOverlayConfiguration(
            enabled: true, music: MusicOverlayConfiguration(enabled: true, x: 0.1, y: 0.1), clock: ClockOverlayConfiguration(enabled: true),
            board: MonitorBoardConfiguration(widgets: [])
        )
    }

    static var widgetRemoved: String {
        String(localized: "Widget removed", bundle: .appLanguage)
    }

    init(overlay: MonitorOverlayConfiguration, editing: Bool = true) {
        store = RemoveWindowStore(overlay: overlay, logicalSize: Self.logicalSize)
        let manager = UndoTestManager()
        let bookmarks = BookmarkStore(persistence: RemoveWindowBookmarks())
        stack = EditDeskUndoStack(
            manager: manager, router: ApplyRouter(manager: manager, bookmarks: bookmarks, sceneCapable: true), bookmarks: bookmarks
        )
        session.transition(to: store.identity, store: store, editing: editing)
        // Wired as `DisplayDetailHost` wires it.
        let screen = manager.left
        session.onWidgetsRemoved = { [weak session, stack] removed in
            stack.recordRemoval(of: removed, from: screen) { session?.flushPendingEdits() }
        }
        window = ParkedTestWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: OverlayCanvas(session: session, cover: nil, size: size))
        host.frame = CGRect(origin: .zero, size: size)
        window.contentView = host
        window.parkOffScreen()
        // A click in a window that is not key only activates it and never reaches the button.
        window.makeKey()
        host.layoutSubtreeIfNeeded()
        stack.onRecord = { [weak self] text, _ in self?.notices.append(text) }
    }

    func close() {
        session.detach()
        window.orderOut(nil)
        window.contentView = nil
        window.close()
    }

    /// Polls for up to two seconds; a condition that stays false just waits it out.
    @discardableResult
    func settle(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + (condition() ? .zero : .seconds(2))
        for _ in 0 ..< 5 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    var renderScale: CGFloat {
        Self.scale
    }

    func selection(_ object: OverlayObjectRemoveWindowTests.Object) throws -> OverlaySelection {
        switch object {
        case .widget: try .widget(#require(session.interaction.placements.first).id)
        case .clock: .clock
        case .music: .music
        }
    }

    /// The session call each object's VoiceOver Remove makes in the Edit Desk.
    func voiceOverRemove(_ selection: OverlaySelection) {
        if case let .widget(id) = selection {
            session.removeWidget(id: id)
        } else {
            session.removeSingleton(selection)
        }
    }

    func isOn(_ selection: OverlaySelection, in overlay: MonitorOverlayConfiguration) -> Bool {
        selection == .music ? overlay.music.enabled : overlay.clock.enabled
    }

    /// The top-right corner of the object as drawn, in board points.
    func corner(of selection: OverlaySelection) -> CGPoint {
        var rect = session.rect(for: selection)
        if case let .widget(id) = selection, let widget = session.interaction.placements.first(where: { $0.id == id }) {
            let geometry = session.interaction.geometry
            let footprint = session.interaction.footprint(for: widget)
            let origin = geometry.clampOrigin(session.interaction.pixelOrigin(for: widget), footprint: footprint)
            rect = geometry.renderRect(forRawRect: CGRect(origin: origin, size: footprint))
        }
        return CGPoint(x: rect.maxX, y: rect.minY)
    }

    /// The remove button's centre, in board points: 4pt on screen left of and below the object's top-right `corner`.
    func button(corner: CGPoint) -> CGPoint {
        CGPoint(x: corner.x - 4 / Self.scale, y: corner.y + 4 / Self.scale)
    }

    /// `point` is in board points with a top-left origin; window coordinates start bottom-left.
    func click(board point: CGPoint) async {
        // Commits a selection made just before the click, or the click lands on the object before its remove button is drawn.
        window.contentView?.layoutSubtreeIfNeeded()
        let location = NSPoint(x: point.x * Self.scale, y: size.height - point.y * Self.scale)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ) else {
                Issue.record("could not build a \(type) event")
                return
            }
            window.sendEvent(event)
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}

@MainActor
private final class RemoveWindowBookmarks: BookmarkPersisting {
    func load() -> [WallpaperBookmark] {
        []
    }

    func save(_: [WallpaperBookmark]) {}
}

@MainActor
private final class RemoveWindowStore: OverlayEditorStore {
    let identity = OverlayEditorIdentity(displayID: 0xAD0D_0101, fingerprint: "object-remove-window")
    var snapshot: OverlayEditorSnapshot

    init(overlay: MonitorOverlayConfiguration, logicalSize: CGSize) {
        snapshot = OverlayEditorSnapshot(overlay: overlay, configuration: nil, logicalSize: logicalSize, safeArea: .none)
    }

    var displays: [OverlayEditorIdentity] {
        [identity]
    }

    func read(_ identity: OverlayEditorIdentity) -> OverlayEditorSnapshot? {
        identity == self.identity ? snapshot : nil
    }

    func writeBoard(_ board: MonitorBoardConfiguration, for _: OverlayEditorIdentity) {
        snapshot.overlay.board = board
    }

    func writeOverlayEnabled(_ enabled: Bool, for _: OverlayEditorIdentity) {
        snapshot.overlay.enabled = enabled
    }

    func writeMusic(_ music: MusicOverlayConfiguration, for _: OverlayEditorIdentity) {
        snapshot.overlay.music = music
    }

    func writeClock(_ clock: ClockOverlayConfiguration, for _: OverlayEditorIdentity) {
        snapshot.overlay.clock = clock
    }

    func writeEffect(_: ParticleEffect, for _: OverlayEditorIdentity) {}

    func copy(_: OverlayKind, from _: OverlayEditorIdentity) {}
}
