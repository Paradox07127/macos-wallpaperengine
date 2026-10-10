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
