import AppKit
@testable import LiveWallpaper
import LiveWallpaperCore
import SwiftUI
import Testing

/// The Edit Desk draws its bars in the window's title-bar strip. A scroll view below a bar reaches up
/// under that strip; if it wins the hit test there, the bar's buttons never get their clicks.
@Suite("Title-bar strip hit testing", .serialized)
@MainActor
struct TitleBarStripHitTests {
    @Test("A scrolling settings column leaves the detail top bar's buttons their clicks")
    func detailTopBarOverScrollingInspector() async throws {
        try await withWindow(navigation: nil) { window in
            window.contentView = NSHostingView(rootView: AppLanguageScope(defaults: .appScoped()) {
                Self.detail(windowSize: window.frame.size).ignoresSafeArea()
            })
            // The settings button, last in the bar: 16pt padding, a 22pt glyph.
            let chain = await Self.hitChain(in: window, x: window.frame.width - 27, yFromTop: 28)
            #expect(!chain.contains { $0 is NSScrollView }, Comment(rawValue: "hit \(chain.map { type(of: $0) })"))
        }
    }

    @Test("The settings page's page tabs stay above the settings column's scroll view")
    func settingsTabsOverScrollingColumn() async throws {
        try await withWindow(navigation: .general) { window in
            let chain = await Self.hitChain(in: window, x: window.frame.width / 2, yFromTop: 28)
            #expect(!chain.contains { $0 is NSScrollView }, Comment(rawValue: "hit \(chain.map { type(of: $0) })"))
        }
    }

    // MARK: Harness

    /// The app's own Edit Desk window, parked off every display: SwiftUI runs `onAppear` only on screen.
    private func withWindow(navigation: Navigation?, _ body: (NSWindow) async throws -> Void) async throws {
        let manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false,
            startAutomation: false,
            powerMonitor: FakePowerMonitor(),
            fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(),
            displayRegistry: FakeDisplayRegistry(),
            featureCatalog: .unconfigured
        ))
        #if !LITE_BUILD
        let doctor = SteamCMDDoctorService()
        let host = SettingsWindowHost(
            manager: manager,
            wallpaperExportService: WallpaperExportService(),
            workshopDoctorService: doctor,
            workshopServices: WorkshopServices(),
            workshopSetupController: WorkshopSetupController(doctor: doctor)
        )
        #else
        let host = SettingsWindowHost(manager: manager, wallpaperExportService: WallpaperExportService())
        #endif
        let delegate = WindowDelegate()
        let controller = host.makeWindowController(
            editDeskEnabled: true, initialNavigation: navigation, initialAddWallpaperRequest: nil, savesFrame: false, delegate: delegate
        )
        let window = try #require(controller.window)
        defer {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
            manager.tearDownForTermination()
        }
        window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        window.orderBack(nil)
        try await body(window)
    }

    /// Settles the page's fade-in first: the detail's chrome takes no hits until it has appeared.
    private static func hitChain(in window: NSWindow, x: CGFloat, yFromTop: CGFloat) async -> [NSView] {
        let deadline = Date().addingTimeInterval(1.2)
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        window.contentView?.layoutSubtreeIfNeeded()
        var chain: [NSView] = []
        var view = window.contentView?.superview?.hitTest(NSPoint(x: x, y: window.frame.height - yFromTop))
        while let current = view {
            chain.append(current)
            view = current.superview
        }
        return chain
    }

    private static func detail(windowSize: CGSize) -> some View {
        DisplayDetail(
            displayName: "Display",
            tags: [DetailDisplayTag(id: 1, name: "Display", thumbnail: nil, isCurrent: true)],
            hero: DetailHeroStatus(title: "Wallpaper", kindLine: "", intendsToPlay: true, performanceLine: nil),
            heroImage: nil,
            backdropImage: nil,
            windowSize: windowSize,
            section: .constant(.wallpaper),
            heroVisible: true,
            actions: DetailActions(
                back: {}, selectDisplay: { _ in }, saveAsScheme: {}, applyToAll: {}, clearWallpaper: {},
                playback: { _ in }, recapture: {}, copyOverlays: {}, snapEnabled: .constant(false)
            ),
            hud: { EmptyView() },
            inspector: { _ in
                ScrollView { Color.gray.frame(height: 2000) }
            },
            overlayLogicalSize: CGSize(width: 1920, height: 1080),
            overlayCanvas: { _ in Color.clear },
            wallpaperStatus: { EmptyView() },
            inspectorVisible: .constant(true), layersVisible: .constant(true),
            inspectorWidth: .constant(372), liveInspectorWidth: .constant(nil)
        )
    }

    private final class WindowDelegate: NSObject, NSWindowDelegate {}
}
