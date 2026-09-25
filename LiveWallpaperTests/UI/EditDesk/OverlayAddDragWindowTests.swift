import AppKit
@testable import LiveWallpaper
import LiveWallpaperCore
import SwiftUI
import Testing

/// The add strip's tiles driven by real mouse and key events in an ordered-in window parked off screen.
/// The workspace is 1280×764 with the inspector closed and the strip expanded.
@Suite("Overlay add strip drag in a window", .serialized)
@MainActor
struct OverlayAddDragWindowTests {
    private static let size = CGSize(width: 1280, height: 764)
    /// The CPU tile's centre, top-left origin: column 1 of 7 (172.57 wide, 8 apart, 12 in), row 0 of the strip.
    private static let cpuTile = CGPoint(x: 12 + (1208.0 / 7 + 8) + 1208.0 / 14, y: 764 - 150 + 4 + 30 + 4 + 23)
    /// Inside the canvas, which aspect-fits 1728×1117 into 1280×614 less 12 a side.
    private static let onCanvas = CGPoint(x: 640, y: 300)

    @Test("A short click on a tile adds once; a drag past six points never counts as a click")
    func clickVersusDrag() async {
        let fixture = DragWindowFixture(size: Self.size)
        defer { fixture.close() }
        let before = fixture.session.interaction.placements.count
        await fixture.click(Self.cpuTile)
        #expect(await fixture.settle { fixture.session.interaction.placements.count == before + 1 }, "a click did not add")
        let afterClick = fixture.session.interaction.placements.count
        let end = CGPoint(x: Self.cpuTile.x + 40, y: Self.cpuTile.y + 5)
        await fixture.press(Self.cpuTile)
        await fixture.drag(through: [CGPoint(x: Self.cpuTile.x + 3, y: Self.cpuTile.y), CGPoint(x: Self.cpuTile.x + 20, y: Self.cpuTile.y), end])
        await fixture.release(end)
        await fixture.settle { false }
        #expect(fixture.session.interaction.placements.count == afterClick, "a drag released on the strip added a widget")
        #expect(fixture.session.addDrop == nil)
    }

    @Test("A tile dragged onto the canvas lands under the release point")
    func dropOnCanvas() async throws {
        let fixture = DragWindowFixture(size: Self.size)
        defer { fixture.close() }
        let before = fixture.session.interaction.placements.count
        await fixture.press(Self.cpuTile)
        await fixture.drag(through: [
            CGPoint(x: Self.cpuTile.x + 20, y: Self.cpuTile.y - 20), CGPoint(x: 500, y: 450), Self.onCanvas,
        ])
        #expect(await fixture.settle { fixture.session.addDrop != nil }, "the drag never reached the session")
        await fixture.release(Self.onCanvas)
        #expect(await fixture.settle { fixture.session.interaction.placements.count == before + 1 }, "the drop added nothing")
        let added = try #require(fixture.session.interaction.placements.last)
        #expect(added.kind == .cpu)
        let box = OverlayGeometry.aspectFit(
            logicalSize: fixture.session.logicalSize,
            in: CGRect(x: 0, y: 0, width: Self.size.width, height: Self.size.height - 150).insetBy(dx: 12, dy: 12)
        )
        let scale = box.width / fixture.session.logicalSize.width
        let pointer = CGPoint(x: (Self.onCanvas.x - box.minX) / scale, y: (Self.onCanvas.y - box.minY) / scale)
        let origin = fixture.session.interaction.pixelOrigin(for: added)
        let footprint = fixture.session.interaction.footprint(for: added)
        let reach = LayoutEngine.snapThreshold / scale
        #expect(abs(origin.x + footprint.width / 2 - pointer.x) <= reach, "centre x \(origin.x + footprint.width / 2) vs pointer \(pointer.x)")
        #expect(abs(origin.y + footprint.height / 2 - pointer.y) <= reach, "centre y \(origin.y + footprint.height / 2) vs pointer \(pointer.y)")
    }

    @Test("Escape during a drag cancels the drag and does not reach the page's Escape")
    func escapeCancelsDrag() async {
        let fixture = DragWindowFixture(size: Self.size)
        defer { fixture.close() }
        fixture.escape()
        #expect(await fixture.settle { fixture.closes == 1 }, "the page's Escape never fired, so this harness proves nothing")
        let before = fixture.session.interaction.placements.count
        await fixture.press(Self.cpuTile)
        await fixture.drag(through: [CGPoint(x: Self.cpuTile.x + 20, y: Self.cpuTile.y - 20), Self.onCanvas])
        #expect(await fixture.settle { fixture.session.addDrop != nil }, "the drag never reached the session")
        fixture.escape()
        await fixture.settle { false }
        #expect(fixture.closes == 1, "Escape closed the page while a tile was being dragged")
        #expect(fixture.session.addDrop == nil, "Escape left the drag running")
        let later = CGPoint(x: Self.onCanvas.x + 10, y: Self.onCanvas.y + 10)
        await fixture.drag(through: [later])
        await fixture.release(later)
        await fixture.settle { false }
        #expect(fixture.session.interaction.placements.count == before, "the cancelled drag still dropped a widget")
    }
}

@MainActor
private final class DragWindowFixture {
    let screen = Screen(nsScreen: DragWindowTestScreen())
    let manager: ScreenManager
    let store = DragWindowStore()
    let session: OverlayEditorSession
    let window: NSWindow
    var closes = 0
    private let size: CGSize

    init(size: CGSize) {
        self.size = size
        manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false, startAutomation: false,
            powerMonitor: FakePowerMonitor(), fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(), displayRegistry: FakeDisplayRegistry(screens: [screen]),
            featureCatalog: FeatureCatalog(capabilities: .lite), originReconciler: PreservingOriginReconciler()
        ))
        session = OverlayEditorSession(defaults: UserDefaults(suiteName: "OverlayAddDragWindowTests") ?? .standard)
        session.transition(to: store.identity, store: store, editing: true)
        window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: DragWindowHost(fixture: self))
        host.frame = CGRect(origin: .zero, size: size)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        window.orderBack(nil)
        // Without it a synthesized key press reaches no key-equivalent handler, and the Escape control group stays silent.
        window.makeKey()
        host.layoutSubtreeIfNeeded()
    }

    func close() {
        session.detach()
        window.orderOut(nil)
        window.contentView = nil
        window.close()
        manager.tearDownForTermination()
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

    func click(_ point: CGPoint) async {
        await press(point)
        await release(point)
    }

    func press(_ point: CGPoint) async {
        await send(.leftMouseDown, point)
    }

    func drag(through points: [CGPoint]) async {
        for point in points {
            await send(.leftMouseDragged, point)
        }
    }

    func release(_ point: CGPoint) async {
        await send(.leftMouseUp, point)
    }

    /// Through `NSApp`, so local event monitors see it the way a real key press would reach them.
    func escape() {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53
        ) else { return }
        NSApp.sendEvent(event)
    }

    /// `point` has a top-left origin; window coordinates start bottom-left.
    private func send(_ type: NSEvent.EventType, _ point: CGPoint) async {
        guard let event = NSEvent.mouseEvent(
            with: type, location: NSPoint(x: point.x, y: size.height - point.y), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1
        ) else {
            Issue.record("could not build a \(type) event")
            return
        }
        window.sendEvent(event)
        try? await Task.sleep(for: .milliseconds(20))
    }
}

/// The detail page's Escape, next to the workspace the way `DisplayDetailHost` mounts it.
private struct DragWindowHost: View {
    let fixture: DragWindowFixture

    var body: some View {
        ZStack {
            OverlayWorkspace(
                session: fixture.session, cover: nil, screen: fixture.screen,
                size: CGSize(width: 1280, height: 764),
                layersVisible: .constant(false), inspectorVisible: .constant(false),
                inspectorWidth: .constant(372), liveInspectorWidth: .constant(nil),
                recapture: {}, back: {}
            )
            Button { fixture.closes += 1 } label: { EmptyView() }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
        }
        .environment(fixture.manager)
        .frame(width: 1280, height: 764)
    }
}

@MainActor
private final class DragWindowStore: OverlayEditorStore {
    let identity = OverlayEditorIdentity(displayID: 0xAD0D_0001, fingerprint: "add-drag-window")
    var snapshot: OverlayEditorSnapshot

    init() {
        let configuration = ScreenConfiguration(
            screenID: identity.displayID, wallpaper: .html(source: .inline("Test"), config: .default), particleEffect: .snow
        )
        snapshot = OverlayEditorSnapshot(
            overlay: MonitorOverlayConfiguration(
                enabled: true,
                board: MonitorBoardConfiguration(widgets: [MonitorWidgetPlacement(kind: .cpu, size: .small, x: 0.02, y: 0.7)])
            ),
            configuration: configuration, logicalSize: CGSize(width: 1728, height: 1117), safeArea: .none
        )
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

    func writeEffect(_ effect: ParticleEffect, for _: OverlayEditorIdentity) {
        snapshot.configuration?.particleEffect = effect
    }

    func copy(_: OverlayKind, from _: OverlayEditorIdentity) {}
}

private final class DragWindowTestScreen: NSScreen {
    override var frame: NSRect {
        NSRect(x: 0, y: 0, width: 1728, height: 1117)
    }

    override var visibleFrame: NSRect {
        frame
    }

    override var deviceDescription: [NSDeviceDescriptionKey: Any] {
        [NSDeviceDescriptionKey("NSScreenNumber"): UInt32(0xAD0D_0001)]
    }

    override var localizedName: String {
        "Add drag test"
    }

    /// `getScreenRefreshRate` falls back to this; AppKit traps when an `init()`-built screen is asked.
    override var maximumFramesPerSecond: Int {
        60
    }
}
