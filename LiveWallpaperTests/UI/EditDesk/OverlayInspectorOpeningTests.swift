import AppKit
@testable import LiveWallpaper
import LiveWallpaperCore
import SwiftUI
import Testing

/// Canvas gestures are real mouse events in a window parked off screen; the canvas draws the 1728×1117 board at
/// half size, so one board point is half a window point.
@Suite("Overlay inspector opens on a click, not a drag", .serialized)
@MainActor
struct OverlayInspectorOpeningTests {
    private static let cpu = MonitorWidgetPlacement(kind: .cpu, size: .small, x: 0.3, y: 0.4)

    @Test("Dragging a widget 40pt selects and moves it without asking for the inspector")
    func widgetDragDoesNotRequest() async throws {
        let fixture = OpeningCanvasFixture(overlay: MonitorOverlayConfiguration(
            enabled: true, board: MonitorBoardConfiguration(widgets: [Self.cpu])
        ))
        defer { fixture.close() }
        let widget = try #require(fixture.session.interaction.placements.first)
        let before = fixture.session.interaction.pixelOrigin(for: widget)
        await fixture.drag(board: fixture.centre(of: widget), by: CGSize(width: 40, height: 0))
        #expect(await fixture.settle { fixture.session.selection == .widget(widget.id) }, "the drag did not select the widget")
        let after = try #require(fixture.session.interaction.placements.first)
        #expect(fixture.session.interaction.pixelOrigin(for: after) != before, "control: the drag never moved the widget")
        #expect(fixture.session.inspectorRequest == 0, "a drag asked for the inspector")
    }

    @Test("Pressing a widget and releasing at once asks for the inspector once")
    func widgetClickRequests() async throws {
        let fixture = OpeningCanvasFixture(overlay: MonitorOverlayConfiguration(
            enabled: true, board: MonitorBoardConfiguration(widgets: [Self.cpu])
        ))
        defer { fixture.close() }
        let widget = try #require(fixture.session.interaction.placements.first)
        await fixture.click(board: fixture.centre(of: widget))
        #expect(await fixture.settle { fixture.session.selection == .widget(widget.id) }, "the click did not select the widget")
        #expect(await fixture.settle { fixture.session.inspectorRequest == 1 }, "a click did not ask for the inspector")
    }

    @Test("Dragging the clock 40pt selects and moves it without asking for the inspector")
    func clockDragDoesNotRequest() async {
        let fixture = OpeningCanvasFixture(overlay: MonitorOverlayConfiguration(
            enabled: true, clock: ClockOverlayConfiguration(enabled: true), board: MonitorBoardConfiguration(widgets: [])
        ))
        defer { fixture.close() }
        let before = fixture.session.rect(for: .clock)
        await fixture.drag(board: CGPoint(x: before.midX, y: before.midY), by: CGSize(width: 40, height: 0))
        #expect(await fixture.settle { fixture.session.selection == .clock }, "the drag did not select the clock")
        #expect(fixture.session.rect(for: .clock).origin != before.origin, "control: the drag never moved the clock")
        #expect(fixture.session.inspectorRequest == 0, "a drag asked for the inspector")
    }

    @Test("Pressing the clock and releasing at once asks for the inspector once")
    func clockClickRequests() async {
        let fixture = OpeningCanvasFixture(overlay: MonitorOverlayConfiguration(
            enabled: true, clock: ClockOverlayConfiguration(enabled: true), board: MonitorBoardConfiguration(widgets: [])
        ))
        defer { fixture.close() }
        let clock = fixture.session.rect(for: .clock)
        await fixture.click(board: CGPoint(x: clock.midX, y: clock.midY))
        #expect(await fixture.settle { fixture.session.selection == .clock }, "the click did not select the clock")
        #expect(await fixture.settle { fixture.session.inspectorRequest == 1 }, "a click did not ask for the inspector")
    }

    @Test("Only a request opens the inspector; a new selection keeps it as it was; no selection or another display closes it")
    func openingRule() {
        let widget = OverlaySelection.widget(UUID())
        for visible in [false, true] {
            #expect(OverlayWorkspace.inspectorVisible(visible, after: .selectionChanged, selection: widget) == visible)
            #expect(OverlayWorkspace.inspectorVisible(visible, after: .selectionChanged, selection: nil) == false)
            #expect(OverlayWorkspace.inspectorVisible(visible, after: .requested, selection: .clock) == true)
            #expect(OverlayWorkspace.inspectorVisible(visible, after: .requested, selection: nil) == false)
            #expect(OverlayWorkspace.inspectorVisible(visible, after: .displayChanged, selection: .clock) == false)
        }
    }

    @Test("Every selection's inspector paints the wallpaper inspector's column and group colours", arguments: [false, true])
    func backgroundsMatchTheWallpaperInspector(dark: Bool) async throws {
        let fixture = InspectorRenderFixture()
        defer { fixture.close() }
        let reference = try await InspectorRender.render(dark: dark, manager: fixture.manager) {
            fixture.wallpaperColumn()
        }
        let referenceGutter = reference.rgb(InspectorRender.gutter, 150)
        let referenceGroup = reference.groupFill(below: 0, gutter: referenceGutter)
        #expect(!referenceGutter.near(referenceGroup), "control: the wallpaper inspector's group fill is not found")
        for (name, selection) in fixture.selections {
            fixture.session.select(selection)
            let image = try await InspectorRender.render(dark: dark, manager: fixture.manager) {
                fixture.overlayColumn()
            }
            for y in [CGFloat(20), 150, 590] {
                let gutter = image.rgb(InspectorRender.gutter, y)
                #expect(gutter.near(referenceGutter), "\(name) column at y \(y) is \(gutter), the wallpaper column \(referenceGutter)")
            }
            let group = image.groupFill(below: ObjectInspector.headerHeight, gutter: referenceGutter)
            #expect(group.near(referenceGroup), "\(name) group is \(group), the wallpaper group \(referenceGroup)")
        }
    }
}

// MARK: - Canvas

@MainActor
private final class OpeningCanvasFixture {
    private static let logicalSize = CGSize(width: 1728, height: 1117)
    private static let scale: CGFloat = 0.5
    let session = OverlayEditorSession(defaults: UserDefaults(suiteName: "OverlayInspectorOpeningTests") ?? .standard)
    private let store: OpeningStore
    private let window: NSWindow
    private let size = CGSize(width: logicalSize.width * scale, height: logicalSize.height * scale)

    init(overlay: MonitorOverlayConfiguration) {
        store = OpeningStore(overlay: overlay, configuration: nil)
        session.transition(to: store.identity, store: store, editing: true)
        window = ParkedTestWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = FirstMouseHost(rootView: OverlayCanvas(session: session, cover: nil, size: size))
        host.frame = CGRect(origin: .zero, size: size)
        window.contentView = host
        window.parkOffScreen()
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

    /// In board points.
    func centre(of widget: MonitorWidgetPlacement) -> CGPoint {
        let interaction = session.interaction
        let footprint = interaction.footprint(for: widget)
        let origin = interaction.geometry.clampOrigin(interaction.pixelOrigin(for: widget), footprint: footprint)
        let tile = interaction.geometry.renderRect(forRawRect: CGRect(origin: origin, size: footprint))
        return CGPoint(x: tile.midX, y: tile.midY)
    }

    func click(board point: CGPoint) async {
        await settle { false }
        await send(.leftMouseDown, board: point)
        await send(.leftMouseUp, board: point)
    }

    /// `offset` is in window points.
    func drag(board start: CGPoint, by offset: CGSize) async {
        await settle { false }
        await send(.leftMouseDown, board: start)
        for step in [CGFloat(0.1), 0.5, 1] {
            let point = CGPoint(x: start.x + offset.width * step / Self.scale, y: start.y + offset.height * step / Self.scale)
            await send(.leftMouseDragged, board: point)
        }
        await send(.leftMouseUp, board: CGPoint(x: start.x + offset.width / Self.scale, y: start.y + offset.height / Self.scale))
    }

    /// `point` has a top-left origin; window coordinates start bottom-left.
    private func send(_ type: NSEvent.EventType, board point: CGPoint) async {
        guard let event = NSEvent.mouseEvent(
            with: type, location: NSPoint(x: point.x * Self.scale, y: size.height - point.y * Self.scale), modifierFlags: [],
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

/// The test app is not active, so AppKit spends each click as an activating first click, which only Buttons accept;
/// the canvas objects' gestures would never see it.
private final class FirstMouseHost<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }
}

// MARK: - Inspector backgrounds

/// Every object on, and a snow effect, so each selection's inspector has groups to paint.
@MainActor
private final class InspectorRenderFixture {
    let screen = Screen(nsScreen: OpeningTestScreen())
    let manager: ScreenManager
    let session = OverlayEditorSession(defaults: UserDefaults(suiteName: "OverlayInspectorOpeningTests") ?? .standard)
    private let store: OpeningStore

    init() {
        manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false, startAutomation: false,
            powerMonitor: FakePowerMonitor(), fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(), displayRegistry: FakeDisplayRegistry(screens: [screen]),
            featureCatalog: FeatureCatalog(capabilities: .pro), originReconciler: PreservingOriginReconciler()
        ))
        store = OpeningStore(
            overlay: MonitorOverlayConfiguration(
                enabled: true, music: MusicOverlayConfiguration(enabled: true), clock: ClockOverlayConfiguration(enabled: true),
                board: MonitorBoardConfiguration(widgets: [MonitorWidgetPlacement(kind: .cpu, size: .small, x: 0.3, y: 0.4)])
            ),
            configuration: ScreenConfiguration(
                screenID: 0x0A1D_0001, wallpaper: .html(source: .inline("Test"), config: .default), particleEffect: .snow
            )
        )
        manager.monitorOverlays[screen.displayFingerprint] = store.snapshot.overlay
        session.transition(to: store.identity, store: store, editing: true)
    }

    var selections: [(String, OverlaySelection)] {
        let widget = session.interaction.placements.first.map { OverlaySelection.widget($0.id) } ?? .board
        return [("widget", widget), ("board", .board), ("clock", .clock), ("music", .music)]
    }

    /// As `OverlayWorkspace` mounts it.
    func overlayColumn() -> some View {
        ObjectInspector(session: session, screen: screen, screenManager: manager, placements: session.interaction.placements,
                        height: InspectorRender.size.height, width: InspectorRender.size.width)
            .overlay(alignment: .leading) { Divider() }
            .contentColumnBackground()
    }

    /// As `DisplayDetail` mounts the Wallpaper tab's inspector, for a video whose groups show.
    func wallpaperColumn() -> some View {
        var draft = DraftState.default
        draft.selectedWallpaperType = .video
        return DetailInspectorPanel(
            screen: screen, draft: .constant(draft), screenManager: manager, featureCatalog: FeatureCatalog(capabilities: .pro),
            reduceMotion: false, inspectorPanelWidth: InspectorRender.size.width, isColorExpanded: .constant(false),
            onWallpaperModeChange: { _ in }, showsResetDisplaySettings: false, onResetDisplaySettings: {}
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .leading) { Divider() }
        .contentColumnBackground()
    }

    func close() {
        session.detach()
        manager.tearDownForTermination()
    }
}

private enum InspectorRender {
    static let size = CGSize(width: 372, height: 600)
    /// Between the column's leading divider and its groups' inset.
    static let gutter: CGFloat = 5

    /// Over magenta, so a strip the column leaves unpainted shows.
    @MainActor
    static func render(dark: Bool, manager: ScreenManager, @ViewBuilder _ column: () -> some View) async throws -> Pixels {
        // In a row as in `InspectorSplit`: the column's leading `Divider` takes its axis from the stack around it.
        let root = HStack(spacing: 0) { column() }
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)))
            .environment(manager)
        let host = NSHostingView(rootView: AppLanguageScope(defaults: .standard) { root })
        host.frame = CGRect(origin: .zero, size: size)
        let window = ParkedTestWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.parkOffScreen()
        defer {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        let deadline = Date().addingTimeInterval(0.7)
        while Date() < deadline {
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(10))
        }
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return try Pixels(#require(bitmap.cgImage), pointWidth: size.width)
    }
}

private struct RGB: Equatable, CustomStringConvertible {
    let r: Int
    let g: Int
    let b: Int

    /// Within 2/255 on every channel.
    func near(_ other: RGB) -> Bool {
        abs(r - other.r) <= 2 && abs(g - other.g) <= 2 && abs(b - other.b) <= 2
    }

    var description: String {
        String(format: "#%02x%02x%02x", r, g, b)
    }
}

/// sRGB bytes of a cached display; coordinates are points from the top left.
private struct Pixels {
    private let width: Int
    private let height: Int
    private let scale: CGFloat
    private let bytes: [UInt8]

    init(_ image: CGImage, pointWidth: CGFloat) {
        width = image.width
        height = image.height
        scale = CGFloat(image.width) / pointWidth
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
                .draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        self.bytes = bytes
    }

    func rgb(_ x: CGFloat, _ y: CGFloat) -> RGB {
        rgb(px: Int(x * scale), Int(y * scale))
    }

    private func rgb(px x: Int, _ y: Int) -> RGB {
        guard x >= 0, y >= 0, x < width, y < height else { return RGB(r: -1, g: -1, b: -1) }
        let offset = (y * width + x) * 4
        return RGB(r: Int(bytes[offset]), g: Int(bytes[offset + 1]), b: Int(bytes[offset + 2]))
    }

    /// The first group's fill, 4pt under its top edge and 30pt in from the inset, past the corner's curve.
    func groupFill(below top: CGFloat, gutter: RGB) -> RGB {
        let x = DesignTokens.Inspector.horizontalPadding(for: InspectorRender.size.width) + 30
        var y = top
        while y < InspectorRender.size.height - 4, rgb(x, y).near(gutter) {
            y += 1 / scale
        }
        return rgb(x, y + 4)
    }
}

@MainActor
private final class OpeningStore: OverlayEditorStore {
    let identity = OverlayEditorIdentity(displayID: 0x0A1D_0001, fingerprint: "inspector-opening")
    var snapshot: OverlayEditorSnapshot

    init(overlay: MonitorOverlayConfiguration, configuration: ScreenConfiguration?) {
        snapshot = OverlayEditorSnapshot(overlay: overlay, configuration: configuration,
                                         logicalSize: CGSize(width: 1728, height: 1117), safeArea: .none)
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

private final class OpeningTestScreen: NSScreen {
    override var frame: NSRect {
        NSRect(x: 0, y: 0, width: 1728, height: 1117)
    }

    override var visibleFrame: NSRect {
        frame
    }

    override var deviceDescription: [NSDeviceDescriptionKey: Any] {
        [NSDeviceDescriptionKey("NSScreenNumber"): UInt32(0x0A1D_0001)]
    }

    override var localizedName: String {
        "Inspector opening test"
    }

    /// `getScreenRefreshRate` falls back to this; AppKit traps when an `init()`-built screen is asked.
    override var maximumFramesPerSecond: Int {
        60
    }
}
