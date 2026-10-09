import AppKit
@testable import LiveWallpaper
import LiveWallpaperCore
import SwiftUI
import Testing

@MainActor
@Suite("Home page teardown", .serialized)
struct HomePageTeardownTests {
    private static func views(_ root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap { views($0) }
    }

    private static func settle(seconds: Double, until condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("Closing the window that hosts the home page releases its stage model and library")
    func closingTheWindowReleasesTheStageAndLibrary() async throws {
        let manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false, startAutomation: false,
            powerMonitor: FakePowerMonitor(), fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(), displayRegistry: FakeDisplayRegistry(screens: []),
            featureCatalog: .unconfigured
        ))
        defer { manager.tearDownForTermination() }
        weak var stage: EditDeskStageModel?
        weak var library: SavedLibraryModel?
        do {
            let model = SavedLibraryModel(inputs: SavedLibraryModel.Inputs())
            library = model
            let router = EditDeskRouter(initialNavigation: nil, initialAddWallpaperRequest: nil, isWorkshopAvailable: { false })
            let hosting = NSHostingView(rootView: HomePage(router: router, toasts: EditDeskToastCenter(), library: model).environment(manager))
            hosting.sizingOptions = []
            let window = ParkedTestWindow(
                contentRect: CGRect(origin: .zero, size: StageGeometry.designWindow),
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            hosting.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
            window.contentView = hosting
            window.parkOffScreen()
            await Self.settle(seconds: 2) {
                hosting.layoutSubtreeIfNeeded()
                return Self.views(hosting).contains { $0 is EditDeskStageView }
            }
            let stageView = try #require(Self.views(hosting).lazy.compactMap { $0 as? EditDeskStageView }.first)
            stage = stageView.model
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        await Self.settle(seconds: 6) { stage == nil && library == nil }
        #expect(stage == nil, "the stage model outlived the window that hosted the home page")
        #expect(library == nil, "the library outlived the window that hosted the home page")
    }
}
