import AppKit
@testable import LiveWallpaper
import LiveWallpaperCore
import SwiftUI
import Testing

/// The Overlay tab's top strip in a window parked off screen. The strip's controls report their frames through
/// `OverlayTopBarFrameKey`, the canvas its preview through `DetailPreviewFrameKey`; an offscreen host has no AX tree.
@Suite("Overlay top strip in a window", .serialized)
@MainActor
struct OverlayTopBarWindowTests {
    struct Layout: CustomTestStringConvertible, Sendable {
        let width: CGFloat
        let height: CGFloat
        let settingsShown: Bool

        var size: CGSize {
            CGSize(width: width, height: height)
        }

        var testDescription: String {
            "\(Int(width))×\(Int(height)), settings \(settingsShown ? "shown" : "hidden")"
        }
    }

    nonisolated static let layouts = [(1040.0, 644.0), (1280.0, 764.0)].flatMap { width, height in
        [true, false].map { Layout(width: width, height: height, settingsShown: $0) }
    }

    @Test("The preview sits under the strip and keeps its frame while both panels open; the strip's controls never overlap", arguments: layouts)
    func stripLayout(_ layout: Layout) throws {
        let fixture = TopBarFixture(size: layout.size, settingsShown: layout.settingsShown)
        defer { fixture.close() }
        let column = try #require(fixture.column, "the canvas column never mounted")
        let before = try #require(fixture.state.preview, "the canvas never reported its preview frame")
        let collapsed = fixture.state.frames
        Self.expectStrip(collapsed, in: column, layout.testDescription)
        Self.report(collapsed, layout.testDescription)
        #expect(before.minY >= OverlayWorkspaceLayout.topBarHeight - 0.5,
                "\(layout.testDescription): the preview starts at \(before.minY), inside the \(OverlayWorkspaceLayout.topBarHeight)pt strip")

        try fixture.openBothPanels()
        let expanded = fixture.state.frames
        let after = try #require(fixture.state.preview)
        #expect(Self.same(before, after), "\(layout.testDescription): opening the panels moved the preview from \(before) to \(after)")
        for item in [OverlayTopBarItem.layers, .effect, .previewContents, .recapture] {
            let was = collapsed[item] ?? .null
            let now = expanded[item] ?? .null
            #expect(abs(was.minX - now.minX) <= 0.5 && abs(was.width - now.width) <= 0.5 && abs(was.minY - now.minY) <= 0.5,
                    "\(layout.testDescription): opening the panels moved \(item) from \(was) to \(now)")
        }
        Self.expectStrip(expanded, in: column, "\(layout.testDescription), panels open")
    }

    @Test("In Spanish at 1040 with the settings column shown, the strip's controls still fit side by side")
    func spanishStrip() throws {
        let size = CGSize(width: 1040, height: 644)
        let english = try AppLanguageOverride.with(.english) { () throws -> CGRect in
            let fixture = TopBarFixture(size: size, settingsShown: true)
            defer { fixture.close() }
            return try #require(fixture.state.frames[.previewContents])
        }
        try AppLanguageOverride.with(.spanish) {
            let fixture = TopBarFixture(size: size, settingsShown: true)
            defer { fixture.close() }
            let column = try #require(fixture.column, "the canvas column never mounted")
            let spanish = try #require(fixture.state.frames[.previewContents])
            #expect(spanish.width > english.width + 4, "control: the Spanish menu (\(spanish.width)pt) is no wider than the English one (\(english.width)pt)")
            Self.expectStrip(fixture.state.frames, in: column, "es 1040")
            Self.report(fixture.state.frames, "es 1040")
        }
    }

    private static func expectStrip(_ frames: [OverlayTopBarItem: CGRect], in column: CGRect, _ label: String) {
        let items: [OverlayTopBarItem] = [.layers, .effect, .previewContents, .recapture]
        for item in items {
            guard let frame = frames[item] else {
                Issue.record("\(label): \(item) reported no frame")
                continue
            }
            #expect(frame.minX >= column.minX - 0.5 && frame.maxX <= column.maxX + 0.5,
                    "\(label): \(item) spans \(frame.minX)–\(frame.maxX), outside the canvas column \(column.minX)–\(column.maxX)")
            #expect(frame.minY >= -0.5 && frame.minY + OverlayWorkspaceLayout.panelTitleHeight <= OverlayWorkspaceLayout.topBarHeight + 0.5,
                    "\(label): \(item) starts at \(frame.minY), so its title row leaves the strip")
        }
        for (index, item) in items.enumerated() {
            for other in items[(index + 1)...] {
                guard let lhs = frames[item], let rhs = frames[other] else { continue }
                let overlap = lhs.intersection(rhs)
                #expect(overlap.isNull || overlap.width <= 0.5 || overlap.height <= 0.5,
                        "\(label): \(item) \(lhs) overlaps \(other) \(rhs)")
            }
        }
    }

    private static func report(_ frames: [OverlayTopBarItem: CGRect], _ label: String) {
        for item in [OverlayTopBarItem.layers, .effect, .previewContents, .recapture] {
            guard let frame = frames[item] else { continue }
            print(String(format: "TOPBAR %@ %@ x %.1f–%.1f y %.1f–%.1f", label, "\(item)", frame.minX, frame.maxX, frame.minY, frame.maxY))
        }
    }

    private static func same(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= 0.5 && abs(lhs.minY - rhs.minY) <= 0.5
            && abs(lhs.width - rhs.width) <= 0.5 && abs(lhs.height - rhs.height) <= 0.5
    }
}

/// Only writes images to look at; its own suite keeps it off the fast shard's list, as the fidelity probes are.
@Suite("Overlay top strip probe images")
@MainActor
struct OverlayTopBarProbeTests {
    @Test("Probe images at 1040×644 with the settings column: both panels closed, then both open")
    func probeImages() throws {
        let fixture = TopBarFixture(size: CGSize(width: 1040, height: 644), settingsShown: true)
        defer { fixture.close() }
        fixture.settle()
        fixture.writeImage("overlay-top-bar-1040-collapsed")
        try fixture.openBothPanels()
        fixture.settle()
        fixture.writeImage("overlay-top-bar-1040-expanded")
    }
}

@MainActor
@Observable
private final class TopBarState {
    var layersVisible = false
    @ObservationIgnored var frames: [OverlayTopBarItem: CGRect] = [:]
    @ObservationIgnored var preview: CGRect?
}

/// The workspace as `DisplayDetailHost` mounts it, with the detail's preview space around it.
private struct TopBarHost: View {
    let session: OverlayEditorSession
    let screen: Screen
    let manager: ScreenManager
    let size: CGSize
    let settingsShown: Bool
    @Bindable var state: TopBarState

    var body: some View {
        AppLanguageScope(defaults: .standard) {
            OverlayWorkspace(
                session: session, cover: nil, screen: screen, size: size,
                layersVisible: $state.layersVisible, inspectorVisible: .constant(settingsShown),
                inspectorWidth: .constant(372), liveInspectorWidth: .constant(nil),
                recapture: {}, swipe: { _ in }, switchEdge: .trailing
            )
            .environment(manager)
            .frame(width: size.width, height: size.height)
            .coordinateSpace(name: DetailPreviewSpace.name)
            .onPreferenceChange(DetailPreviewFrameKey.self) { state.preview = $0.values.first }
            .onPreferenceChange(OverlayTopBarFrameKey.self) { state.frames = $0 }
        }
    }
}

@MainActor
private final class TopBarFixture {
    let screen = Screen(nsScreen: TopBarTestScreen())
    let manager: ScreenManager
    let store = TopBarStore()
    let session = OverlayEditorSession(defaults: UserDefaults(suiteName: "OverlayTopBarWindowTests") ?? .standard)
    let state = TopBarState()
    let window: NSWindow
    let host: NSView
    private let size: CGSize

    init(size: CGSize, settingsShown: Bool) {
        self.size = size
        manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false, startAutomation: false,
            powerMonitor: FakePowerMonitor(), fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(), displayRegistry: FakeDisplayRegistry(screens: [screen]),
            featureCatalog: FeatureCatalog(capabilities: .lite), originReconciler: PreservingOriginReconciler()
        ))
        session.transition(to: store.identity, store: store, editing: true)
        window = ParkedTestWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        let hosting = NSHostingView(rootView: TopBarHost(
            session: session, screen: screen, manager: manager, size: size, settingsShown: settingsShown, state: state
        ))
        hosting.frame = CGRect(origin: .zero, size: size)
        window.contentView = hosting
        window.parkOffScreen()
        window.makeKey()
        hosting.layoutSubtreeIfNeeded()
        host = hosting
    }

    func close() {
        session.detach()
        window.orderOut(nil)
        window.contentView = nil
        window.close()
        manager.tearDownForTermination()
    }

    /// Runs the main run loop past the panels' 0.22 s open animation, so a probe image shows them at rest.
    func settle(_ seconds: TimeInterval = 0.6) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    /// The canvas below the strip: the swipe navigator's view spans it, and its x-range is the canvas column's.
    var column: CGRect? {
        func views(_ root: NSView) -> [NSView] {
            [root] + root.subviews.flatMap(views)
        }
        guard let view = views(host).first(where: { $0 is DetailSwipeNavigator.SwipeView }) else { return nil }
        let frame = view.convert(view.bounds, to: host)
        return host.isFlipped ? frame : CGRect(x: frame.minX, y: host.bounds.height - frame.maxY, width: frame.width, height: frame.height)
    }

    /// Clicks each panel's title row, then checks both really opened: the layers binding flipped and the effect panel grew.
    func openBothPanels() throws {
        let layers = try #require(state.frames[.layers], "the layers panel reported no frame")
        let effect = try #require(state.frames[.effect], "the effect panel reported no frame")
        click(CGPoint(x: layers.minX + 30, y: layers.minY + OverlayWorkspaceLayout.panelTitleHeight / 2))
        click(CGPoint(x: effect.minX + 30, y: effect.minY + OverlayWorkspaceLayout.panelTitleHeight / 2))
        #expect(state.layersVisible, "clicking the layers title did not open the panel")
        let opened = try #require(state.frames[.effect])
        #expect(opened.height > effect.height + 40, "clicking the effect title did not open the panel: \(effect.height) → \(opened.height)")
    }

    /// `point` has a top-left origin in the workspace, which fills the window.
    private func click(_ point: CGPoint) {
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
        }
        // The strip reports its new frames from inside this pass; the open animation only moves pixels.
        host.layoutSubtreeIfNeeded()
    }

    func writeImage(_ name: String) {
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            Issue.record("no bitmap for \(name)")
            return
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("overlay-top-bar-probe", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(name).png")
        guard let png = bitmap.representation(using: .png, properties: [:]), (try? png.write(to: url)) != nil else {
            Issue.record("could not write \(url.path)")
            return
        }
        print("TOPBAR-PNG \(url.path)")
    }
}

@MainActor
private final class TopBarStore: OverlayEditorStore {
    let identity = OverlayEditorIdentity(displayID: 0x70BA_0001, fingerprint: "overlay-top-bar")
    var snapshot: OverlayEditorSnapshot

    init() {
        let configuration = ScreenConfiguration(
            screenID: identity.displayID, wallpaper: .html(source: .inline("Test"), config: .default), particleEffect: .snow
        )
        snapshot = OverlayEditorSnapshot(
            overlay: MonitorOverlayConfiguration(
                enabled: true, music: MusicOverlayConfiguration(enabled: true), clock: ClockOverlayConfiguration(enabled: true),
                board: MonitorBoardConfiguration(widgets: [
                    MonitorWidgetPlacement(kind: .cpu, size: .small, x: 0.02, y: 0.7),
                    MonitorWidgetPlacement(kind: .memory, size: .small, x: 0.3, y: 0.7),
                ])
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

private final class TopBarTestScreen: NSScreen {
    override var frame: NSRect {
        NSRect(x: 0, y: 0, width: 1728, height: 1117)
    }

    override var visibleFrame: NSRect {
        frame
    }

    override var deviceDescription: [NSDeviceDescriptionKey: Any] {
        [NSDeviceDescriptionKey("NSScreenNumber"): UInt32(0x70BA_0001)]
    }

    override var localizedName: String {
        "Top strip test"
    }

    /// `getScreenRefreshRate` falls back to this; AppKit traps when an `init()`-built screen is asked.
    override var maximumFramesPerSecond: Int {
        60
    }
}
