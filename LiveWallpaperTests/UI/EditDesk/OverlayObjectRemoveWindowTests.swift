import AppKit
@testable import LiveWallpaper
import LiveWallpaperCore
import SwiftUI
import Testing

/// The canvas objects' corner remove button, clicked with real mouse events in a window parked off screen.
/// Clicks rather than an AX press: an offscreen SwiftUI host exposes no accessibility tree to find the button in.
/// The canvas draws the 1728×1117 board at half size, so one board point is half a window point.
@Suite("Overlay object remove button in a window", .serialized)
@MainActor
struct OverlayObjectRemoveWindowTests {
    @Test("Clicking a selected widget's corner button removes the widget")
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

    @Test("Clicking the selected Clock layer's corner button turns the clock off")
    func removesClock() async {
        let fixture = RemoveWindowFixture(overlay: MonitorOverlayConfiguration(
            enabled: true, clock: ClockOverlayConfiguration(enabled: true), board: MonitorBoardConfiguration(widgets: [])
        ))
        defer { fixture.close() }
        #expect(fixture.session.overlay.clock.enabled)
        fixture.session.select(.clock)
        let clock = fixture.session.rect(for: .clock)
        await fixture.click(board: fixture.button(corner: CGPoint(x: clock.maxX, y: clock.minY)))
        #expect(await fixture.settle { !fixture.session.overlay.clock.enabled }, "the corner button did not turn the clock off")
        #expect(fixture.store.snapshot.overlay.clock.enabled == false)
    }
}

@MainActor
private final class RemoveWindowFixture {
    private static let logicalSize = CGSize(width: 1728, height: 1117)
    private static let scale: CGFloat = 0.5
    let store: RemoveWindowStore
    let session = OverlayEditorSession(defaults: UserDefaults(suiteName: "OverlayObjectRemoveWindowTests") ?? .standard)
    let window: NSWindow
    private let size = CGSize(width: logicalSize.width * scale, height: logicalSize.height * scale)

    init(overlay: MonitorOverlayConfiguration) {
        store = RemoveWindowStore(overlay: overlay, logicalSize: Self.logicalSize)
        session.transition(to: store.identity, store: store, editing: true)
        window = ParkedTestWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: OverlayCanvas(session: session, cover: nil, size: size))
        host.frame = CGRect(origin: .zero, size: size)
        window.contentView = host
        window.parkOffScreen()
        // A click in a window that is not key only activates it and never reaches the button.
        window.makeKey()
        host.layoutSubtreeIfNeeded()
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

    /// The remove button's centre, in board points: 4pt on screen left of and below the object's top-right `corner`.
    func button(corner: CGPoint) -> CGPoint {
        CGPoint(x: corner.x - 4 / Self.scale, y: corner.y + 4 / Self.scale)
    }

    /// `point` is in board points with a top-left origin; window coordinates start bottom-left.
    func click(board point: CGPoint) async {
        await settle { false }
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
