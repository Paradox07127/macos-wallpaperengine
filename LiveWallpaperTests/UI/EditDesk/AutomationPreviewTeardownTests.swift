import AppKit
@testable import LiveWallpaper
import LiveWallpaperCore
import Observation
import SwiftUI
import Testing

private final class PreviewTestNSScreen: NSScreen {
    let displayID: UInt32

    init(displayID: UInt32) {
        self.displayID = displayID
        super.init()
    }

    required init?(coder _: NSCoder) {
        nil
    }

    override var frame: NSRect {
        NSRect(x: 0, y: 0, width: 800, height: 600)
    }

    override var deviceDescription: [NSDeviceDescriptionKey: Any] {
        [NSDeviceDescriptionKey("NSScreenNumber"): displayID]
    }

    override var localizedName: String {
        "Preview test"
    }
}

@MainActor @Observable
private final class PageMount {
    var shown = true
}

/// Stands in for the display detail: supplies the namespace and unmounts the page the way switching displays does.
private struct MountedAutomationPage: View {
    let screen: Screen
    let library: SavedLibraryModel
    let manager: ScreenManager
    let mount: PageMount
    @Namespace private var segments

    var body: some View {
        if mount.shown {
            WallpaperAutomationSheet(
                screen: screen, library: library,
                presentation: DetailAutomationPresentation(entered: true, segments: segments, close: {})
            )
            .environment(manager)
        }
    }
}

@MainActor
@Suite("Automation page preview teardown", .serialized)
struct AutomationPreviewTeardownTests {
    @MainActor
    private struct Page {
        let manager: ScreenManager
        let screen: Screen
        let host: NSHostingView<MountedAutomationPage>
        let window: NSWindow
        let mount: PageMount
        let shown: ScreenConfiguration
        let trial: WallpaperQueueEntry

        var active: WallpaperContent? {
            manager.getConfiguration(for: screen)?.activeWallpaper
        }

        func settle(for limit: Duration, until done: () -> Bool = { false }) async throws {
            let deadline = ContinuousClock.now + limit
            while !done(), ContinuousClock.now < deadline {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(10))
            }
        }

        /// Clicks the first queue row's play button. SwiftUI backs a list row's buttons with AppKit controls that carry
        /// no label AppKit can read, so it is found by place: the row ends with Preview, then Remove.
        func previewTrial() async throws {
            var buttons: [NSControl] = []
            try await settle(for: .seconds(3)) {
                let row = Self.table(in: host)?.rowView(atRow: 0, makeIfNecessary: false)
                buttons = row.map { row in Self.controls(in: row).sorted { row.convert($0.bounds, from: $0).minX < row.convert($1.bounds, from: $1).minX } } ?? []
                return buttons.count >= 2
            }
            try #require(buttons.count >= 2, "the queue list never showed a row with its Preview and Remove buttons")
            buttons[buttons.count - 2].performClick(nil)
        }

        private static func table(in view: NSView) -> NSTableView? {
            view as? NSTableView ?? view.subviews.lazy.compactMap(table).first
        }

        private static func controls(in view: NSView) -> [NSControl] {
            view.subviews.flatMap { [$0 as? NSControl].compactMap(\.self) + controls(in: $0) }
        }

        /// Return is Save's key equivalent.
        func save() throws {
            let event = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                isARepeat: false, keyCode: 36
            ))
            try #require(window.performKeyEquivalent(with: event), "Return did not reach Save")
        }
    }

    private func withPage(displayID: UInt32, _ body: (Page) async throws -> Void) async throws {
        let screen = Screen(nsScreen: PreviewTestNSScreen(displayID: displayID))
        let manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false, startAutomation: false,
            powerMonitor: FakePowerMonitor(), fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(), displayRegistry: FakeDisplayRegistry(screens: [screen]),
            featureCatalog: FeatureCatalog(capabilities: .lite), originReconciler: PreservingOriginReconciler()
        ))
        manager.wallpapersGloballyEnabled = false
        defer { manager.clearWallpaperForScreen(screen) }
        let trial = WallpaperQueueEntry(title: "Q", content: .html(source: .inline("Q"), config: .default))
        var shown = ScreenConfiguration(screenID: screen.id, wallpaper: .video(bookmarkData: Data([7])))
        shown.savedHTMLSource = .inline("P")
        shown.wallpaperMode = .playlist
        shown.wallpaperQueue = [trial]
        manager.configurationStore.save(shown)

        let mount = PageMount()
        let host = NSHostingView(rootView: MountedAutomationPage(
            screen: screen, library: SavedLibraryModel(inputs: SavedLibraryModel.Inputs()), manager: manager, mount: mount
        ))
        host.sizingOptions = []
        let window = ParkedTestWindow(
            contentRect: CGRect(origin: .zero, size: StageGeometry.designWindow),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.parkOffScreen()
        defer {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        try await body(Page(manager: manager, screen: screen, host: host, window: window, mount: mount, shown: shown, trial: trial))
    }

    @Test("Leaving the page while a preview is on the display puts the display's own wallpaper back", .timeLimit(.minutes(1)))
    func unmountingRestoresTheWallpaperShownBeforeThePreview() async throws {
        try await withPage(displayID: 0xA171_0001) { page in
            try await page.previewTrial()
            try await page.settle(for: .seconds(3)) { page.active == page.trial.content }
            try #require(page.active == page.trial.content, "the preview never reached the display")

            page.mount.shown = false
            try await page.settle(for: .seconds(2)) { page.active == page.shown.activeWallpaper }

            let restored = try #require(page.manager.getConfiguration(for: page.screen))
            #expect(restored.activeWallpaper == page.shown.activeWallpaper, "the display was left on the previewed wallpaper")
            #expect(restored.savedHTMLSource == .inline("P"))
        }
    }

    @Test("A preview kept by Save stays on the display after the page goes away", .timeLimit(.minutes(1)))
    func unmountingAfterSaveKeepsThePreview() async throws {
        try await withPage(displayID: 0xA171_0002) { page in
            try await page.previewTrial()
            try await page.settle(for: .seconds(3)) { page.active == page.trial.content }
            try #require(page.active == page.trial.content, "the preview never reached the display")
            try page.save()
            let saved = page.active
            try #require(saved != page.shown.activeWallpaper, "Save put the earlier wallpaper back")

            page.mount.shown = false
            try await page.settle(for: .milliseconds(500))

            #expect(page.active == saved, "leaving the page after Save took the saved preview off the display")
        }
    }
}
