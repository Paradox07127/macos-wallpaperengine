import AppKit
@testable import LiveWallpaper
import LiveWallpaperCore
import SwiftUI
import Testing

/// A hidden board widget: off the desktop and out of sampling, a dashed placeholder in the editor.
/// Renders and clicks run in windows parked off screen; the editor canvas draws the 1728×1117 board at half size.
@Suite("Overlay hidden widgets", .serialized)
@MainActor
struct OverlayHiddenWidgetTests {
    private static let shown = MonitorWidgetPlacement(kind: .cpu, size: .small, x: 0.1, y: 0.2)
    private static let hidden: MonitorWidgetPlacement = {
        var placement = MonitorWidgetPlacement(kind: .processes, size: .medium, x: 0.5, y: 0.2)
        placement.isHidden = true
        return placement
    }()

    // MARK: Desktop

    @Test("The desktop board draws the shown widget and leaves the hidden one's spot empty")
    func desktopSkipsHidden() async throws {
        var twin = Self.hidden
        twin.isHidden = false
        let size = CGSize(width: 800, height: 600)
        func render(_ widgets: [MonitorWidgetPlacement]) async throws -> (pixels: Pixels, model: InteractionModel) {
            let model = InteractionModel(configuration: MonitorBoardConfiguration(widgets: widgets))
            let pixels = try await Snapshot.capture(size: size) { RootView(model: model, data: DataModel()) }
            return (pixels, model)
        }
        let without = try await render([Self.shown])
        let drawn = try await render([Self.shown, twin])
        let board = try await render([Self.shown, Self.hidden])
        #expect(board.model.boardSize == size, "control: the board never laid out")
        let shown = try #require(Self.tile(Self.shown.id, in: board.model))
        let hidden = try #require(Self.tile(Self.hidden.id, in: board.model))
        #expect(!board.pixels.rgb(shown.centre).near(Snapshot.magenta), "control: the shown widget was not drawn")
        #expect(!drawn.pixels.rgb(hidden.centre).near(without.pixels.rgb(hidden.centre)), "control: the same widget shown paints its centre")
        #expect(board.pixels.rgb(hidden.centre).near(without.pixels.rgb(hidden.centre)), "the desktop drew the hidden widget")
        let edge = stride(from: hidden.minX + 4, to: hidden.maxX - 4, by: 0.5).map { CGPoint(x: $0, y: hidden.minY + 0.5) }
        #expect(edge.allSatisfy { board.pixels.rgb($0).near(without.pixels.rgb($0)) }, "the desktop outlines the hidden widget")
    }

    // MARK: Editor

    @Test("The editor draws a hidden widget as a dashed frame of its size, empty inside")
    func editorDrawsDashedFrame() async throws {
        var twin = Self.hidden
        twin.isHidden = false
        let empty = try await CanvasFixture.capture(widgets: [])
        let drawn = try await CanvasFixture.capture(widgets: [twin])
        let placeholder = try await CanvasFixture.capture(widgets: [Self.hidden])
        let tile = try #require(placeholder.tile)
        #expect(!drawn.pixels.rgb(tile.centre).near(empty.pixels.rgb(tile.centre)), "control: the same widget shown paints its centre")
        #expect(placeholder.pixels.rgb(tile.centre).near(empty.pixels.rgb(tile.centre)), "the hidden widget's placeholder is filled in")
        // Along the middle of the top edge, on the 1pt border: dashes differ from the empty canvas, gaps do not.
        let xs = Array(stride(from: tile.minX + tile.width * 0.2, to: tile.maxX - tile.width * 0.2, by: 0.5))
        let inked = xs.filter { x in
            let point = CGPoint(x: x, y: tile.minY + 0.5)
            return !placeholder.pixels.rgb(point).near(empty.pixels.rgb(point))
        }
        #expect(!inked.isEmpty, "no border around the hidden widget")
        #expect(inked.count < xs.count, "the hidden widget's border is solid, not dashed")
    }

    @Test("Clicking a hidden widget's placeholder selects it and asks for the inspector")
    func placeholderClickSelects() async throws {
        let fixture = CanvasFixture(widgets: [Self.hidden])
        defer { fixture.close() }
        let tile = try #require(fixture.tile(Self.hidden.id))
        await fixture.click(window: tile.centre)
        #expect(await fixture.settle { fixture.session.selection == .widget(Self.hidden.id) }, "the click did not select the hidden widget")
        #expect(fixture.session.inspectorRequest == 1, "the click did not ask for the inspector")
    }

    @Test("A widget row's switch in the Layers panel hides the widget, the board saves it, and it shows it again")
    func layerSwitchTogglesHidden() async throws {
        let fixture = LayersFixture(widgets: [Self.shown])
        defer { fixture.close() }
        // Rows run Widgets, the widget, Clock, Music; the effect layer has its own panel.
        let before = await fixture.switches()
        #expect(before.count == 4, "the panel shows \(before.count) switches, not one per row")
        try #require(before.count == 4)
        before[1].performClick(nil)
        #expect(await fixture.settle { fixture.session.interaction.placements.first?.isHidden == true }, "the switch did not hide the widget")
        fixture.session.flushPendingEdits()
        #expect(fixture.store.snapshot.overlay.board.widgets.first?.isHidden == true, "the hidden widget was not saved")
        let after = await fixture.switches()
        try #require(after.count == 4)
        after[1].performClick(nil)
        #expect(await fixture.settle { fixture.session.interaction.placements.first?.isHidden == false }, "the switch did not show the widget again")
    }

    // MARK: Sampling

    @Test("The overlay samples only for the widgets that are shown")
    func demandSkipsHiddenKinds() async {
        let runtime = Runtime()
        let controller = OverlayController(runtime: runtime)
        controller.apply(
            overlay: MonitorOverlayConfiguration(enabled: true, board: MonitorBoardConfiguration(widgets: [Self.shown, Self.hidden])),
            screenID: 731, screenFrame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        await controller.waitUntilRuntimeSettled()
        let options = await runtime.debugActiveOptions
        #expect(options?.activeWidgetKinds == [.cpu], "a hidden widget's kind is still sampled")
        #expect(options?.topProcesses == false, "the hidden Processes widget still gathers the process list")
        controller.teardownAll()
        await controller.waitUntilRuntimeSettled()
        await runtime.shutdown()
    }

    // MARK: Source contracts

    @Test("The Layers panel's Widgets, Clock and Music rows open their settings from a gear before the switch")
    func gearButtonContract() throws {
        let navigator = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Overlay/LayerNavigator.swift")
        let gearStart = try #require(navigator.range(of: "GlassIconButton(\"gearshape\", size: .small)"))
        let gear = navigator[gearStart.lowerBound...].prefix(400)
        #expect(gear.contains("session.select(row.selection)"))
        #expect(gear.contains("session.requestInspector()"))
        #expect(gear.contains(".help(Text(\"Settings\"))"))
        #expect(gear.contains(".accessibilityLabel(Text(\"Settings\"))"))
        #expect(navigator.contains("case .board, .clock, .music: true"))
        let trailing = try #require(navigator.range(of: "\n            action\n", range: gearStart.upperBound ..< navigator.endIndex))
        #expect(gearStart.upperBound < trailing.lowerBound)
    }

    @Test("The canvas rounds its wallpaper and backdrop like a display card, not the layer its objects sit on")
    func canvasCornerContract() throws {
        let shell = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Stage/DisplayShellLayer.swift")
        #expect(shell.contains("content.cornerRadius = DesignTokens.EditDesk.Corner.content"), "control: the display card's content corner moved")
        let canvas = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Overlay/OverlayCanvas.swift")
        let body = try #require(canvas.range(of: "var body: some View {"))
        let container = try #require(canvas.range(of: "MonitorBoardRootContainer(", range: body.upperBound ..< canvas.endIndex))
        let bodyEnd = try #require(canvas.range(of: "private func updateScale()", range: container.upperBound ..< canvas.endIndex))
        let backdrop = canvas[body.upperBound ..< container.lowerBound]
        #expect(backdrop.contains("DesignTokens.Colors.surfaceRaised"))
        #expect(backdrop.contains("Image(decorative: cover"))
        #expect(backdrop.contains(".clipShape(RoundedRectangle(cornerRadius: DesignTokens.EditDesk.Corner.content, style: .continuous))"))
        #expect(!canvas[container.lowerBound ..< bodyEnd.lowerBound].contains("clipShape"), "the rounded clip also cuts the objects and their chrome")
    }

    /// The widget's tile in board points.
    private static func tile(_ id: UUID, in model: InteractionModel) -> CGRect? {
        guard let widget = model.placements.first(where: { $0.id == id }) else { return nil }
        let footprint = model.footprint(for: widget)
        let origin = model.geometry.clampOrigin(model.pixelOrigin(for: widget), footprint: footprint)
        return model.geometry.renderRect(forRawRect: CGRect(origin: origin, size: footprint))
    }

    // MARK: - Fixtures

    @MainActor
    private final class CanvasFixture {
        private static let logicalSize = CGSize(width: 1728, height: 1117)
        private static let scale: CGFloat = 0.5
        let session = OverlayEditorSession(defaults: UserDefaults(suiteName: "OverlayHiddenWidgetTests") ?? .standard)
        let store: HiddenWidgetStore
        private let window: NSWindow
        private let host: NSView
        private let size = CGSize(width: logicalSize.width * scale, height: logicalSize.height * scale)

        init(widgets: [MonitorWidgetPlacement]) {
            store = HiddenWidgetStore(board: MonitorBoardConfiguration(widgets: widgets), logicalSize: Self.logicalSize)
            session.transition(to: store.identity, store: store, editing: true)
            window = ParkedTestWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = FirstMouseHost(rootView: OverlayCanvas(session: session, cover: nil, size: size))
            host.frame = CGRect(origin: .zero, size: size)
            self.host = host
            window.contentView = host
            window.parkOffScreen()
            // A click in a window that is not key only activates it.
            window.makeKey()
            host.layoutSubtreeIfNeeded()
        }

        /// The canvas with `widgets`, and the first one's tile.
        static func capture(widgets: [MonitorWidgetPlacement]) async throws -> (pixels: Pixels, tile: CGRect?) {
            let fixture = CanvasFixture(widgets: widgets)
            defer { fixture.close() }
            let pixels = try await Snapshot.cache(fixture.host, pointWidth: fixture.size.width)
            return (pixels, widgets.first.flatMap { fixture.tile($0.id) })
        }

        func close() {
            session.detach()
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }

        /// In window points, top-left origin.
        func tile(_ id: UUID) -> CGRect? {
            OverlayHiddenWidgetTests.tile(id, in: session.interaction).map {
                CGRect(x: $0.minX * Self.scale, y: $0.minY * Self.scale, width: $0.width * Self.scale, height: $0.height * Self.scale)
            }
        }

        /// Polls for up to two seconds; a condition that stays false just waits it out.
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

        /// `point` has a top-left origin; window coordinates start bottom-left.
        func click(window point: CGPoint) async {
            try? await Task.sleep(for: .milliseconds(300))
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
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
    }

    @MainActor
    private final class LayersFixture {
        let session = OverlayEditorSession(defaults: UserDefaults(suiteName: "OverlayHiddenWidgetTests") ?? .standard)
        let store: HiddenWidgetStore
        private let manager: ScreenManager
        private let window: NSWindow
        private let host: NSView

        init(widgets: [MonitorWidgetPlacement]) {
            store = HiddenWidgetStore(board: MonitorBoardConfiguration(widgets: widgets), logicalSize: CGSize(width: 1728, height: 1117))
            session.transition(to: store.identity, store: store, editing: true)
            manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
                restoreSavedWallpapers: false, startAutomation: false,
                powerMonitor: FakePowerMonitor(), fullScreenDetector: FakeFullScreenDetector(),
                playableVideoLoader: FakePlayableVideoLoader(), displayRegistry: FakeDisplayRegistry(screens: []),
                featureCatalog: FeatureCatalog(capabilities: .pro), originReconciler: PreservingOriginReconciler()
            ))
            let rows = OverlayLayerList.rows(placements: session.interaction.placements, boardEnabled: true,
                                             clockEnabled: false, musicEnabled: false)
            let size = CGSize(width: 220, height: CGFloat(rows.count) * OverlayWorkspaceLayout.rowHeight)
            let host = NSHostingView(rootView: LayerNavigator(session: session, rows: rows, height: size.height)
                .frame(width: size.width, height: size.height)
                .environment(manager))
            host.frame = CGRect(origin: .zero, size: size)
            self.host = host
            window = ParkedTestWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.parkOffScreen()
            host.layoutSubtreeIfNeeded()
        }

        func close() {
            session.detach()
            window.orderOut(nil)
            window.contentView = nil
            window.close()
            manager.tearDownForTermination()
        }

        /// Every switch in the panel, top row first.
        func switches() async -> [NSSwitch] {
            for _ in 0 ..< 20 {
                host.layoutSubtreeIfNeeded()
                try? await Task.sleep(for: .milliseconds(10))
            }
            var found: [NSSwitch] = []
            func collect(_ view: NSView) {
                if let control = view as? NSSwitch {
                    found.append(control)
                }
                view.subviews.forEach(collect)
            }
            collect(host)
            return found.sorted { $0.convert($0.bounds, to: nil).midY > $1.convert($1.bounds, to: nil).midY }
        }

        func settle(_ condition: () -> Bool) async -> Bool {
            let deadline = ContinuousClock.now + .seconds(2)
            while !condition(), ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
            return condition()
        }
    }
}

@MainActor
private final class HiddenWidgetStore: OverlayEditorStore {
    let identity = OverlayEditorIdentity(displayID: 0x41DD_0001, fingerprint: "hidden-widget")
    var snapshot: OverlayEditorSnapshot

    init(board: MonitorBoardConfiguration, logicalSize: CGSize) {
        snapshot = OverlayEditorSnapshot(overlay: MonitorOverlayConfiguration(enabled: true, board: board), configuration: nil,
                                         logicalSize: logicalSize, safeArea: .none)
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

// MARK: - Pixels

@MainActor
private enum Snapshot {
    static let magenta = RGB(r: 255, g: 0, b: 255)

    /// `content` over magenta, so whatever it leaves unpainted shows.
    static func capture(size: CGSize, @ViewBuilder _ content: () -> some View) async throws -> Pixels {
        let host = NSHostingView(rootView: content()
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1))))
        host.frame = CGRect(origin: .zero, size: size)
        let window = ParkedTestWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.parkOffScreen()
        defer {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        return try await cache(host, pointWidth: size.width)
    }

    static func cache(_ host: NSView, pointWidth: CGFloat) async throws -> Pixels {
        let deadline = Date().addingTimeInterval(0.7)
        while Date() < deadline {
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(10))
        }
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return try Pixels(#require(bitmap.cgImage), pointWidth: pointWidth)
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

    func rgb(_ point: CGPoint) -> RGB {
        let x = Int(point.x * scale)
        let y = Int(point.y * scale)
        guard x >= 0, y >= 0, x < width, y < height else { return RGB(r: -1, g: -1, b: -1) }
        let offset = (y * width + x) * 4
        return RGB(r: Int(bytes[offset]), g: Int(bytes[offset + 1]), b: Int(bytes[offset + 2]))
    }
}

private extension CGRect {
    var centre: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}
