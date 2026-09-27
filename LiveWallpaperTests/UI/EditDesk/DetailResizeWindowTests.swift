import AppKit
@testable import LiveWallpaper
import LiveWallpaperCore
import SwiftUI
import Testing

/// The detail page and its overlay session read these off the display; AppKit traps when a bare `NSScreen()` is asked them.
private final class ResizeScreen: NSScreen {
    override var frame: NSRect {
        NSRect(x: 0, y: 0, width: 800, height: 600)
    }

    override var visibleFrame: NSRect {
        frame
    }

    override var deviceDescription: [NSDeviceDescriptionKey: Any] {
        [NSDeviceDescriptionKey("NSScreenNumber"): UInt32(0xED0C_0003)]
    }

    override var localizedName: String {
        "Resize Display"
    }

    override var maximumFramesPerSecond: Int {
        60
    }
}

/// The real `HomePage` in the Edit Desk window's chrome, on a window the test resizes as a user would.
@MainActor
private struct ResizeHost {
    let window: NSWindow
    let host: NSView
    let manager: ScreenManager
    let router: EditDeskRouter
    let screen: Screen

    init(size: CGSize) {
        screen = Screen(nsScreen: ResizeScreen())
        manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false, startAutomation: false,
            powerMonitor: FakePowerMonitor(), fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(), displayRegistry: FakeDisplayRegistry(screens: [screen]),
            featureCatalog: .unconfigured
        ))
        let row = WallpaperBookmark(label: "Resize", content: .video(bookmarkData: Data([9, 7, 7])))
        var inputs = SavedLibraryModel.Inputs()
        inputs.bookmarks = { [row] }
        router = EditDeskRouter(initialNavigation: nil, initialAddWallpaperRequest: nil, isWorkshopAvailable: { false })
        let library = SavedLibraryModel(inputs: inputs)
        let hosting = NSHostingView(rootView: HomePage(router: router, toasts: EditDeskToastCenter(), library: library).environment(manager))
        hosting.sizingOptions = []
        window = ParkedTestWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        let toolbar = NSToolbar(identifier: "ResizeToolbar")
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        // Nested, not the content view: as that, the hosting view would grow the window after a page taller than it, without bound.
        let content = NSView(frame: CGRect(origin: .zero, size: size))
        hosting.frame = content.bounds
        hosting.autoresizingMask = [.width, .height]
        content.addSubview(hosting)
        window.contentView = content
        window.setContentSize(size)
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

    /// The detail top bar's two drag strips, the only AppKit views in it.
    var dragStrips: [NSView] {
        Self.views(host).filter { $0 is WindowDragRegion.DragView && $0.window != nil }
    }

    /// Behind the overlay canvas column, which ends where the add drawer begins.
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

    func resize(to size: CGSize) async {
        window.setContentSize(size)
        host.layoutSubtreeIfNeeded()
        await settle(seconds: 1) { stage?.model.stageSize == size }
        await settle(seconds: 0.3)
    }
}

@MainActor
@Suite("Detail page follows the window as it resizes", .serialized)
struct DetailResizeWindowTests {
    private static let large = StageGeometry.designWindow
    private static let small = StageGeometry.minimumWindow

    private static func inside(_ rect: CGRect, _ size: CGSize) -> Bool {
        rect.minX >= -0.5 && rect.minY >= -0.5 && rect.maxX <= size.width + 0.5 && rect.maxY <= size.height + 0.5
    }

    private static func describe(_ rect: CGRect) -> String {
        String(format: "(%.1f, %.1f, %.1f×%.1f)", rect.minX, rect.minY, rect.width, rect.height)
    }

    private static func expectFits(_ host: ResizeHost, _ size: CGSize, _ step: String) {
        #expect(host.host.bounds.size == size, "\(step): the window's content is \(host.host.bounds.size)")
        #expect(host.stage?.model.stageSize == size, "\(step): the stage reports \(String(describing: host.stage?.model.stageSize))")
        for strip in host.dragStrips {
            // Each strip is a zero-height line through the bar's middle; the bar's buttons take its full height.
            let line = host.frame(of: strip)
            let bar = CGRect(x: line.minX, y: line.midY - DetailGeometry.topBarHeight / 2, width: line.width, height: DetailGeometry.topBarHeight)
            #expect(inside(bar, size), "\(step): the top bar sits at \(describe(bar)) in a \(size) window")
        }
        guard let column = host.canvasColumn else {
            Issue.record("\(step): the overlay canvas column is gone")
            return
        }
        let columnRect = host.frame(of: column)
        let drawer = CGRect(x: 0, y: columnRect.maxY, width: size.width, height: AddOverlayDrawer.expandedHeight)
        #expect(inside(drawer, size), "\(step): the add drawer, its title row first, sits at \(describe(drawer)) in a \(size) window")
        #expect(abs(drawer.maxY - size.height) <= 0.5, "\(step): the page ends \(size.height - drawer.maxY)pt above the window's bottom")
    }

    @Test("Shrinking the window with the overlay tab open shrinks the page; growing it back grows it", .timeLimit(.minutes(1)))
    func overlayTabFollowsResize() async throws {
        let host = ResizeHost(size: Self.large)
        defer { host.close() }
        host.router.showDetail(host.screen.id, section: .overlay)
        await host.settle(seconds: 3) { host.canvasColumn != nil && host.dragStrips.count == 2 }
        try #require(host.canvasColumn != nil, "the overlay workspace never mounted")
        try #require(host.dragStrips.count == 2, "the detail top bar never mounted")
        await host.settle(seconds: 0.5)
        Self.expectFits(host, Self.large, "before")

        await host.resize(to: Self.small)
        Self.expectFits(host, Self.small, "shrunk")

        await host.resize(to: Self.large)
        Self.expectFits(host, Self.large, "grown back")
    }
}
