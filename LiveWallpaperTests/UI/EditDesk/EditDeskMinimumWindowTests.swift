import AppKit
@testable import LiveWallpaper
import LiveWallpaperCore
import SwiftUI
import Testing

/// The detail page and its overlay session read these off the display; AppKit traps when a bare `NSScreen()` is asked them.
private final class MinimumScreen: NSScreen {
    override var frame: NSRect {
        NSRect(x: 0, y: 0, width: 800, height: 600)
    }

    override var visibleFrame: NSRect {
        frame
    }

    override var deviceDescription: [NSDeviceDescriptionKey: Any] {
        [NSDeviceDescriptionKey("NSScreenNumber"): UInt32(0xED0C_0004)]
    }

    override var localizedName: String {
        "Minimum Display"
    }

    override var maximumFramesPerSecond: Int {
        60
    }
}

/// The real `HomePage` under `EditDeskRoot`'s minimum frame, hosted the way `SettingsWindowHost` hosts the root:
/// the hosting view is the content view itself, with its default sizing options.
@MainActor
private struct MinimumHost {
    let window: NSWindow
    let host: NSView
    let manager: ScreenManager
    let router: EditDeskRouter
    let screen: Screen

    init() {
        screen = Screen(nsScreen: MinimumScreen())
        manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false, startAutomation: false,
            powerMonitor: FakePowerMonitor(), fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(), displayRegistry: FakeDisplayRegistry(screens: [screen]),
            featureCatalog: .unconfigured
        ))
        let row = WallpaperBookmark(label: "Minimum", content: .video(bookmarkData: Data([9, 7, 8])))
        var inputs = SavedLibraryModel.Inputs()
        inputs.bookmarks = { [row] }
        router = EditDeskRouter(initialNavigation: nil, initialAddWallpaperRequest: nil, isWorkshopAvailable: { false })
        let library = SavedLibraryModel(inputs: inputs)
        let hosting = NSHostingView(rootView: HomePage(router: router, toasts: EditDeskToastCenter(), library: library)
            .environment(manager)
            .frame(minWidth: StageGeometry.minimumWindow.width, minHeight: StageGeometry.minimumWindow.height))
        window = ParkedTestWindow(
            contentRect: CGRect(origin: .zero, size: SettingsWindowMetrics.editDeskDefaultContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.contentMinSize = SettingsWindowMetrics.editDeskMinimumContentSize
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        let toolbar = NSToolbar(identifier: "MinimumToolbar")
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.parkOffScreen()
        host = hosting
    }

    func close() {
        window.orderOut(nil)
        window.contentView = nil
        window.close()
        manager.tearDownForTermination()
    }

    private static func views(_ root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap { views($0) }
    }

    var stage: EditDeskStageView? {
        Self.views(host).lazy.compactMap { $0 as? EditDeskStageView }.first
    }

    /// The home top bar's drag region, or the detail top bar's two drag strips.
    var dragStrips: [NSView] {
        Self.views(host).filter { $0 is WindowDragRegion.DragView && $0.window != nil }
    }

    var canvasColumn: NSView? {
        Self.views(host).first { $0 is DetailSwipeNavigator.SwipeView && $0.window != nil }
    }

    /// `view`'s bounds in the host's top-left coordinates.
    func frame(of view: NSView) -> CGRect {
        let frame = view.convert(view.bounds, to: host)
        return host.isFlipped ? frame : CGRect(
            x: frame.minX, y: host.bounds.height - frame.maxY, width: frame.width, height: frame.height
        )
    }

    func settle(seconds: Double, until condition: () -> Bool = { false }) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, !condition() {
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Asks for the design minimum, then settles at whatever minimum the window itself enforces.
    func shrinkToMinimum() async {
        window.setContentSize(StageGeometry.minimumWindow)
        window.layoutIfNeeded()
        await settle(seconds: 0.3)
        window.setContentSize(window.contentMinSize)
        window.layoutIfNeeded()
        await settle(seconds: 1) { stage?.model.stageSize == host.bounds.size }
        await settle(seconds: 0.3)
    }
}

@MainActor
@Suite("Edit Desk at its minimum window size", .serialized)
struct EditDeskMinimumWindowTests {
    private static func inside(_ rect: CGRect, _ size: CGSize) -> Bool {
        rect.minX >= -0.5 && rect.minY >= -0.5 && rect.maxX <= size.width + 0.5 && rect.maxY <= size.height + 0.5
    }

    private static func describe(_ rect: CGRect) -> String {
        String(format: "(%.1f, %.1f, %.1f×%.1f)", rect.minX, rect.minY, rect.width, rect.height)
    }

    private static func expectMinimum(_ host: MinimumHost, _ step: String) {
        let size = host.host.bounds.size
        #expect(size == host.window.contentMinSize, "\(step): the window stopped at \(size), its minimum is \(host.window.contentMinSize)")
        #expect(size.width >= StageGeometry.minimumWindow.width && size.height >= StageGeometry.minimumWindow.height,
                "\(step): the window shrank to \(size), under the design minimum")
        #expect(host.window.minSize.height >= StageGeometry.minimumWindow.height, "\(step): the window's frame minimum is \(host.window.minSize)")
        if let stage = host.stage {
            let page = host.frame(of: stage)
            #expect(inside(page, size), "\(step): the page sits at \(describe(page)) in a \(size) window")
        } else {
            Issue.record("\(step): the stage is gone")
        }
        #expect(!host.dragStrips.isEmpty, "\(step): no top bar is on the page")
        for strip in host.dragStrips {
            // A detail strip is a zero-height line through its bar's middle; the home bar's region is the bar.
            let line = host.frame(of: strip)
            let bar = CGRect(x: line.minX, y: line.midY - DetailGeometry.topBarHeight / 2, width: line.width, height: DetailGeometry.topBarHeight)
            #expect(inside(bar, size), "\(step): the top bar sits at \(describe(bar)) in a \(size) window")
        }
    }

    @Test("At the smallest window the overview allows, its top bar and page stay inside the window", .timeLimit(.minutes(1)))
    func overviewAtMinimum() async throws {
        let host = MinimumHost()
        defer { host.close() }
        await host.settle(seconds: 3) { host.stage != nil && host.dragStrips.count == 1 }
        try #require(host.dragStrips.count == 1, "the home top bar never mounted")
        await host.shrinkToMinimum()
        Self.expectMinimum(host, "overview")
    }

    @Test("At the smallest window the overlay tab allows, its top bar and add drawer stay inside the window", .timeLimit(.minutes(1)))
    func overlayTabAtMinimum() async throws {
        let host = MinimumHost()
        defer { host.close() }
        host.router.showDetail(host.screen.id, section: .overlay)
        await host.settle(seconds: 3) { host.canvasColumn != nil && host.dragStrips.count == 2 }
        try #require(host.canvasColumn != nil, "the overlay workspace never mounted")
        try #require(host.dragStrips.count == 2, "the detail top bar never mounted")
        await host.shrinkToMinimum()
        Self.expectMinimum(host, "overlay")
        let size = host.host.bounds.size
        let column = try #require(host.canvasColumn, "the overlay canvas column is gone")
        let columnRect = host.frame(of: column)
        let drawer = CGRect(x: 0, y: columnRect.maxY, width: size.width, height: AddOverlayDrawer.expandedHeight)
        #expect(Self.inside(drawer, size), "overlay: the add drawer sits at \(Self.describe(drawer)) in a \(size) window")
    }
}
