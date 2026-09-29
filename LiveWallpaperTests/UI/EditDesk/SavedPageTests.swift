import AppKit
@testable import LiveWallpaper
import LiveWallpaperCore
import SwiftUI
import Testing

@MainActor
@Suite("Schemes page", .serialized)
struct SavedPageTests {
    private static let retiredTabKey = "loomscreen.savedLibrary.selectedTab.v1"

    fileprivate static func makeRouter() -> EditDeskRouter {
        EditDeskRouter(initialNavigation: nil, initialAddWallpaperRequest: nil, isWorkshopAvailable: { true })
    }

    fileprivate static func makeManager() -> ScreenManager {
        ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false, startAutomation: false,
            powerMonitor: FakePowerMonitor(), fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(), displayRegistry: FakeDisplayRegistry(),
            featureCatalog: .unconfigured
        ))
    }

    @Test("Manage Schemes opens the Schemes page")
    func manageSchemesOpensThePage() throws {
        let router = Self.makeRouter()
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

    /// Set by a `.task` on the page's container, which SwiftUI starts in the same pass as the page's own appearance hooks.
    @MainActor private final class Appearance {
        var done = false
    }

    /// Mounts the page in a parked window and runs `body` once the page's appearance hooks have run.
    private func mount(_ page: some View, manager: ScreenManager, while body: () async -> Void) async {
        let appearance = Appearance()
        let host = NSHostingView(rootView: AppLanguageScope(defaults: .standard) {
            page.environment(manager).frame(width: 1280, height: 820).task { appearance.done = true }
        })
        let window = ParkedTestWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1280, height: 820), styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.parkOffScreen()
        let deadline = ContinuousClock.now + .seconds(2)
        while !appearance.done, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(appearance.done, "the page never appeared, so the visit proves nothing")
        await body()
        window.orderOut(nil)
        window.contentView = nil
    }

    @Test("A visit writes no tab choice")
    func visitWritesNoTab() async {
        let defaults = UserDefaults.appScoped()
        defaults.removeObject(forKey: Self.retiredTabKey)
        defer { defaults.removeObject(forKey: Self.retiredTabKey) }
        let manager = Self.makeManager()
        defer { manager.tearDownForTermination() }
        let router = Self.makeRouter()
        router.select(.schemes)

        await mount(SchemesPage(router: router, toasts: EditDeskToastCenter()), manager: manager) {
            #expect(defaults.object(forKey: Self.retiredTabKey) == nil, "the page still remembers a tab")
        }
    }
}

#if !LITE_BUILD
/// Writes a picture and checks nothing, so like the Edit Desk fidelity probes it stays off the fast shard's suite list.
@MainActor
@Suite("Schemes page probe", .serialized)
struct SchemesPageProbeTests {
    @Test("Probe: the Schemes page at 1280×820")
    func probeImage() async {
        let manager = SavedPageTests.makeManager()
        defer { manager.tearDownForTermination() }
        let router = SavedPageTests.makeRouter()
        router.select(.schemes)
        _ = await ProbeRenderer.render("schemes-page", size: CGSize(width: 1280, height: 820), settle: 1) {
            SchemesPage(router: router, toasts: EditDeskToastCenter())
                .environment(manager)
                .background { EditDeskBackdrop(frosted: false) }
        }
    }
}
#endif
