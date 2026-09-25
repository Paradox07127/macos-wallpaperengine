#if !LITE_BUILD
import AppKit
@testable import LiveWallpaper
import LiveWallpaperCore
import SwiftUI
import Testing

/// Each page is drawn the way `EditDeskRoot` hosts it, over a magenta stand-in for the window's
/// canvas: magenta left in the picture is where the frosted canvas shows through.
@Suite("Edit Desk pages over the window canvas", .serialized)
@MainActor
struct EditDeskCanvasCoverageTests {
    private static let size = StageGeometry.designWindow

    /// The share of magenta pixels in `region` (points), sampled every other pixel.
    private struct Coverage {
        let image: ProbeImage

        func share(_ region: CGRect) -> Double {
            var hit = 0, all = 0
            let step = 2
            for y in stride(from: Int(region.minY * image.scale), to: Int(region.maxY * image.scale), by: step) {
                for x in stride(from: Int(region.minX * image.scale), to: Int(region.maxX * image.scale), by: step) {
                    let colour = image.rgb(px: x, y)
                    all += 1
                    if colour.r > 235, colour.g < 25, colour.b > 235 {
                        hit += 1
                    }
                }
            }
            return all == 0 ? 0 : Double(hit) / Double(all)
        }

        /// 24pt cells in `region` whose centre shows the overview's 2pt dot: lighter than the canvas, with bare
        /// canvas 3pt off it on all four sides, which a glyph's edge crossing the centre never has.
        func dotCells(_ region: CGRect) -> Int {
            func pixel(_ x: CGFloat, _ y: CGFloat) -> ProbeColor {
                image.rgb(px: Int(x * image.scale), Int(y * image.scale))
            }
            func bare(_ colour: ProbeColor) -> Bool {
                colour.r > 235 && colour.g < 4 && colour.b > 235
            }
            var cells = 0
            for y in stride(from: CGFloat(12), to: region.maxY, by: 24) where y >= region.minY {
                for x in stride(from: CGFloat(12), to: region.maxX, by: 24) where x >= region.minX {
                    let centre = pixel(x, y)
                    let around = [pixel(x - 3, y), pixel(x + 3, y), pixel(x, y - 3), pixel(x, y + 3)]
                    if around.allSatisfy(bare), centre.r > 235, centre.b > 235, centre.g >= 4 {
                        cells += 1
                    }
                }
            }
            return cells
        }

        /// Pixels in `region` (points) matching `predicate`, every pixel.
        func count(_ region: CGRect, _ predicate: (ProbeColor) -> Bool) -> Int {
            var hits = 0
            for y in Int(region.minY * image.scale) ..< Int(region.maxY * image.scale) {
                for x in Int(region.minX * image.scale) ..< Int(region.maxX * image.scale) where predicate(image.rgb(px: x, y)) {
                    hits += 1
                }
            }
            return hits
        }
    }

    /// Parked off every display in a window shaped like the Edit Desk's: transparent title bar,
    /// unified toolbar, clear and non-opaque. `act` runs once the page has mounted; `inspect` sees the
    /// hosting view just before the capture.
    private func render(
        _ page: some View, settle: TimeInterval = 1, act: () -> Void = {}, inspect: (NSView) -> Void = { _ in }
    ) async throws -> Coverage {
        let root = ZStack {
            Color(nsColor: NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)).ignoresSafeArea()
            page.environment(\.windowPaintsCanvas, true)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        let hosting = NSHostingView(rootView: AppLanguageScope(defaults: .standard) { root })
        hosting.sizingOptions = []
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: Self.size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        let toolbar = NSToolbar(identifier: "CanvasCoverageToolbar")
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.setContentSize(Self.size)
        window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        window.orderBack(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        let mounted = Date().addingTimeInterval(0.5)
        while Date() < mounted {
            hosting.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(10))
        }
        act()
        let deadline = Date().addingTimeInterval(settle)
        while Date() < deadline {
            hosting.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(10))
        }
        hosting.layoutSubtreeIfNeeded()
        inspect(hosting)
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        return try Coverage(image: ProbeImage(cgImage: #require(bitmap.cgImage), viewWidth: Self.size.width))
    }

    private func makeManager() -> ScreenManager {
        ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false, startAutomation: false,
            powerMonitor: FakePowerMonitor(), fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(), displayRegistry: FakeDisplayRegistry(),
            featureCatalog: .unconfigured
        ))
    }

    /// Below the top bar and the library's filter row.
    private static var body: CGRect {
        CGRect(x: 0, y: StageGeometry.gridTop, width: size.width, height: size.height - StageGeometry.gridTop)
    }

    @Test("Control: the overview leaves the canvas showing")
    func overviewShowsTheCanvas() async throws {
        let manager = makeManager()
        defer { manager.tearDownForTermination() }
        let router = EditDeskRouter(initialNavigation: nil, initialAddWallpaperRequest: nil, isWorkshopAvailable: { false })
        let coverage = try await render(
            HomePage(router: router, toasts: EditDeskToastCenter(), library: SavedLibraryModel(inputs: .init())).environment(manager)
        )
        let share = coverage.share(Self.body)
        print("CANVAS-COVERAGE overview body=\(share)")
        #expect(share >= 0.9, "the harness does not see the canvas even where no page paints: \(share)")
    }

    @Test("The schemes page leaves the canvas showing")
    func schemesPageShowsTheCanvas() async throws {
        let manager = makeManager()
        defer { manager.tearDownForTermination() }
        let router = EditDeskRouter(initialNavigation: nil, initialAddWallpaperRequest: nil, isWorkshopAvailable: { false })
        router.select(.schemes)
        let coverage = try await render(SchemesPage(router: router, toasts: EditDeskToastCenter()).environment(manager))
        let share = coverage.share(Self.body)
        print("CANVAS-COVERAGE schemes body=\(share)")
        #expect(share >= 0.3, "the schemes page paints its own background over the canvas: \(share)")
    }

    /// `EditDeskRoot`'s settings branch: the sidebar shows the canvas, the content column stays solid.
    @Test("Settings: the sidebar shows the canvas and the content column stays solid")
    func settingsSidebarShowsTheCanvas() async throws {
        let manager = makeManager()
        defer { manager.tearDownForTermination() }
        let sidebarWidth = SettingsWindowMetrics.sidebarColumnWidth
        let coverage = try await render(
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    TopBar(page: .constant(.settings), workshopAvailable: false, windowWidth: geometry.size.width, status: nil)
                        .zIndex(1)
                    HStack(spacing: 0) {
                        SettingsSidebar(
                            selection: .constant(.general), searchText: .constant(""),
                            pendingSearchAnchor: .constant(nil), onBack: {}, showsBackButton: false
                        )
                        .frame(width: sidebarWidth)
                        Divider()
                        SettingsDetailContent(selection: .constant(.shortcuts), pendingSearchAnchor: .constant(nil))
                    }
                }
            }
            .ignoresSafeArea()
            .environment(manager)
        )
        let top = DesignTokens.EditDesk.Spacing.topBar
        let sidebar = coverage.share(CGRect(x: 0, y: top, width: sidebarWidth - 1, height: Self.size.height - top))
        let content = coverage.share(CGRect(
            x: sidebarWidth + 2, y: top, width: Self.size.width - sidebarWidth - 2, height: Self.size.height - top
        ))
        print("CANVAS-COVERAGE settings sidebar=\(sidebar) content=\(content)")
        #expect(sidebar >= 0.3, "the settings sidebar paints its own background over the canvas: \(sidebar)")
        #expect(content <= 0.02, "the settings content column lets the canvas through: \(content)")
    }

    @Test("The landed library leaves the canvas showing between and below its tiles")
    func libraryShowsTheCanvas() async throws {
        let manager = makeManager()
        defer { manager.tearDownForTermination() }
        var inputs = SavedLibraryModel.Inputs()
        let rows = (0 ..< 12).map { WallpaperBookmark(label: "Tile \($0)", content: .video(bookmarkData: Data([UInt8($0), 1, 2]))) }
        inputs.bookmarks = { rows }
        let router = EditDeskRouter(initialNavigation: .bookmarks, initialAddWallpaperRequest: nil, isWorkshopAvailable: { false })
        let coverage = try await render(
            HomePage(router: router, toasts: EditDeskToastCenter(), library: SavedLibraryModel(inputs: inputs)).environment(manager),
            settle: 2
        )
        let share = coverage.share(Self.body)
        print("CANVAS-COVERAGE library body=\(share)")
        #expect(share >= 0.3, "the library grid paints its own background over the canvas: \(share)")
    }

    /// The S6 fixture: a blue hero, an inspector that draws nothing of its own. Over the whole window, as
    /// `HomePage` lays its detail host out.
    private func landedDetail(section: DetailSection, overlay: some View = Color.clear) -> some View {
        DisplayDetail(
            displayName: "Canvas Display",
            tags: [DetailDisplayTag(id: 1, name: "Canvas Display", thumbnail: nil, isCurrent: true)],
            hero: DetailHeroStatus(title: "Canvas", kindLine: "Video", intendsToPlay: true),
            heroImage: ProbeRenderer.solid(ProbeRenderer.thumbnailBlue),
            windowSize: Self.size,
            section: .constant(section),
            heroVisible: true,
            actions: ProbeFixtures.detailActions,
            hud: { EmptyView() },
            inspector: { _ in Color.clear },
            overlayCanvas: { _ in overlay },
            wallpaperStatus: { EmptyView() },
            inspectorVisible: .constant(true),
            inspectorWidth: .constant(372), liveInspectorWidth: .constant(nil)
        )
        .ignoresSafeArea()
    }

    @Test("A landed detail shows the canvas under its top bar and around its hero; its inspector column stays solid")
    func landedDetailShowsTheCanvas() async throws {
        let coverage = try await render(landedDetail(section: .wallpaper))
        let top = DetailGeometry.topBarHeight
        let inspectorX = Self.size.width - 372
        let strip = coverage.share(CGRect(x: 0, y: 0, width: Self.size.width, height: top))
        let preview = coverage.share(CGRect(x: 0, y: top, width: inspectorX - 2, height: Self.size.height - top))
        let inspector = coverage.share(CGRect(x: inspectorX + 2, y: top, width: 370, height: Self.size.height - top))
        print("CANVAS-COVERAGE detail strip=\(strip) preview=\(preview) inspector=\(inspector)")
        #expect(strip >= 0.3, "the detail's top bar paints its own background over the canvas: \(strip)")
        #expect(preview >= 0.3, "the detail paints its own background around the hero: \(preview)")
        #expect(inspector <= 0.02, "the detail's inspector column lets the canvas through: \(inspector)")
    }

    @Test("Content scrolled up in the detail's workspace stays below its top bar")
    func detailWorkspaceStaysBelowTheTopBar() async throws {
        let tall = ScrollView {
            VStack(spacing: 0) {
                ForEach(0 ..< 40, id: \.self) { _ in
                    Color.yellow.frame(height: 40)
                }
            }
        }
        .defaultScrollAnchor(.bottom)
        let coverage = try await render(landedDetail(section: .overlay, overlay: tall))
        let strip = CGRect(x: 0, y: 0, width: Self.size.width, height: DetailGeometry.topBarHeight)
        let spilled = coverage.count(strip) { $0.isYellow }
        let below = coverage.count(CGRect(x: 0, y: DetailGeometry.topBarHeight, width: Self.size.width, height: 40)) { $0.isYellow }
        print("CANVAS-COVERAGE clip strip=\(spilled) below=\(below)")
        #expect(below > 0, "control: the scrolled content never reached the top of the workspace")
        #expect(spilled == 0, "the workspace's scrolled content shows through the top bar: \(spilled) px")
    }

    @Test("Under a landed detail the overview draws nothing: no dots, no stage, and the top bar shows the canvas")
    func realDetailHidesTheOverview() async throws {
        let screen = Screen(nsScreen: CoverageScreen())
        let manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false, startAutomation: false,
            powerMonitor: FakePowerMonitor(), fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(), displayRegistry: FakeDisplayRegistry(screens: [screen]),
            featureCatalog: .unconfigured
        ))
        defer { manager.tearDownForTermination() }
        let router = EditDeskRouter(initialNavigation: nil, initialAddWallpaperRequest: nil, isWorkshopAvailable: { false })
        var shellsHidden: Bool?
        let coverage = try await render(
            HomePage(router: router, toasts: EditDeskToastCenter(), library: SavedLibraryModel(inputs: .init())).environment(manager),
            settle: 1.5,
            act: { router.showDetail(screen.id) },
            inspect: { host in
                @MainActor func views(_ root: NSView) -> [NSView] {
                    [root] + root.subviews.flatMap(views)
                }
                let stage = views(host).lazy.compactMap { $0 as? EditDeskStageView }.first
                shellsHidden = stage?.displayLayers[screen.id]?.layer.superlayer?.isHidden
            }
        )
        let strip = CGRect(x: 0, y: 0, width: Self.size.width, height: DetailGeometry.topBarHeight)
        let share = coverage.share(strip)
        let dots = coverage.dotCells(strip)
        print("CANVAS-COVERAGE real-detail strip=\(share) dots=\(dots) shellsHidden=\(String(describing: shellsHidden))")
        #expect(router.detailDisplayID == screen.id, "control: the detail never opened")
        #expect(share >= 0.3, "the landed detail's top bar paints over the canvas: \(share)")
        #expect(dots == 0, "the overview's dots still show under the landed detail, in \(dots) cells")
        #expect(shellsHidden == true, "the stage still draws its displays under the landed detail")
    }
}

private final class CoverageScreen: NSScreen {
    override var frame: NSRect {
        NSRect(x: 0, y: 0, width: 800, height: 600)
    }

    override var deviceDescription: [NSDeviceDescriptionKey: Any] {
        [NSDeviceDescriptionKey("NSScreenNumber"): UInt32(0xED0C_0003)]
    }

    override var visibleFrame: NSRect {
        frame
    }

    override var localizedName: String {
        "Canvas Display"
    }

    override var maximumFramesPerSecond: Int {
        60
    }
}
#endif
