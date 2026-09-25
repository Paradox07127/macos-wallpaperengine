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
    }

    /// Parked off every display in a window shaped like the Edit Desk's: transparent title bar,
    /// unified toolbar, clear and non-opaque.
    private func render(_ page: some View, settle: TimeInterval = 1) async throws -> Coverage {
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
        let deadline = Date().addingTimeInterval(settle)
        while Date() < deadline {
            hosting.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(10))
        }
        hosting.layoutSubtreeIfNeeded()
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
}
#endif
