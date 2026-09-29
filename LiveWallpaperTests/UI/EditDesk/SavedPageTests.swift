import AppKit
@testable import LiveWallpaper
import LiveWallpaperCore
import SwiftUI
import Testing

@MainActor
@Suite("Schemes page", .serialized)
struct SavedPageTests {
    private static let retiredTabKey = "loomscreen.savedLibrary.selectedTab.v1"

    private func makeRouter() -> EditDeskRouter {
        EditDeskRouter(initialNavigation: nil, initialAddWallpaperRequest: nil, isWorkshopAvailable: { true })
    }

    private func makeManager() -> ScreenManager {
        ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false, startAutomation: false,
            powerMonitor: FakePowerMonitor(), fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(), displayRegistry: FakeDisplayRegistry(),
            featureCatalog: .unconfigured
        ))
    }

    @Test("Manage Schemes opens the Schemes page")
    func manageSchemesOpensThePage() throws {
        let router = makeRouter()
        router.select(.schemes)
        #expect(router.page == .schemes)
        let host = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Detail/DisplayDetailHost.swift")
        #expect(host.contains("router.select(.schemes)"), "Manage Schemes does not open the Schemes page")
    }

    @Test("The page is the scheme list alone, and the top navigation names it Schemes")
    func pageListsSchemesAlone() throws {
        let page = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Shell/SchemesPage.swift")
        #expect(page.contains("SchemeLibraryView("), "the page does not list the schemes")
        for leftover in ["GlassSegmentedPicker(", "WorkshopModalHost(", "@AppStorage("] {
            #expect(!page.contains(leftover), Comment(rawValue: "the page still carries the bookmarks tab's \(leftover)"))
        }
        #expect(NavPill.title(for: .schemes) == LocalizedStringKey("Schemes"))
    }

    /// Mounts the page in a parked window long enough for its first layout and storage reads to run.
    private func mount(_ page: some View, manager: ScreenManager, while body: () async -> Void) async {
        let host = NSHostingView(rootView: AppLanguageScope(defaults: .standard) {
            page.environment(manager).frame(width: 1280, height: 820)
        })
        let window = ParkedTestWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1280, height: 820), styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.parkOffScreen()
        await settle()
        await body()
        window.orderOut(nil)
        window.contentView = nil
    }

    private func settle() async {
        let deadline = Date().addingTimeInterval(0.4)
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("A visit writes no tab choice")
    func visitWritesNoTab() async {
        let defaults = UserDefaults.appScoped()
        defaults.removeObject(forKey: Self.retiredTabKey)
        defer { defaults.removeObject(forKey: Self.retiredTabKey) }
        let manager = makeManager()
        defer { manager.tearDownForTermination() }
        let router = makeRouter()
        router.select(.schemes)

        await mount(SchemesPage(router: router, toasts: EditDeskToastCenter()), manager: manager) {
            #expect(defaults.object(forKey: Self.retiredTabKey) == nil, "the page still remembers a tab")
        }
    }

    #if !LITE_BUILD
    @Test("Probe: the Schemes page at 1280×820")
    func probeImage() async {
        let manager = makeManager()
        defer { manager.tearDownForTermination() }
        let router = makeRouter()
        router.select(.schemes)
        _ = await ProbeRenderer.render("schemes-page", size: CGSize(width: 1280, height: 820), settle: 1) {
            SchemesPage(router: router, toasts: EditDeskToastCenter())
                .environment(manager)
                .background { EditDeskBackdrop(frosted: false) }
        }
    }
    #endif
}
