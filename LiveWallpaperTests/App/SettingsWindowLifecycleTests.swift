#if !LITE_BUILD
    import AppKit
    import LiveWallpaperCore
    @testable import LiveWallpaper
    import Testing

    /// B4: closing the settings window must destroy the whole SwiftUI hierarchy
    /// and hosting window instead of hiding it, so a background app does not
    /// keep the settings content tree resident.
    @Suite("Settings window destroy-on-close", .serialized)
    @MainActor
    struct SettingsWindowLifecycleTests {
        private func makeDelegate() -> AppDelegate {
            let delegate = AppDelegate()
            delegate.screenManager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
                restoreSavedWallpapers: false,
                startAutomation: false,
                powerMonitor: FakePowerMonitor(),
                fullScreenDetector: FakeFullScreenDetector(),
                playableVideoLoader: FakePlayableVideoLoader(),
                displayRegistry: FakeDisplayRegistry(),
                featureCatalog: .unconfigured
            ))
            return delegate
        }

        /// AppKit autoreleases window bookkeeping and SwiftUI tears its tree
        /// down on the next runloop turns, so releases are polled rather than
        /// asserted synchronously after `close()`.
        private func drainRunLoop(until released: () -> Bool) {
            for _ in 0 ..< 100 {
                if released() { return }
                autoreleasepool {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                }
            }
        }

        @Test("closing releases the controller, window, and hosting view")
        func closeDestroysWindowHierarchy() throws {
            let delegate = makeDelegate()

            weak var weakController: NSWindowController?
            weak var weakWindow: NSWindow?
            weak var weakContentView: NSView?

            try autoreleasepool {
                delegate.showSettings()
                let controller = try #require(delegate.settingsWindowControllerForTesting)
                let window = try #require(controller.window)
                weakController = controller
                weakWindow = window
                weakContentView = window.contentView
                #expect(weakContentView != nil)

                #expect(delegate.windowShouldClose(window))

                window.close()
            }

            drainRunLoop {
                weakController == nil && weakWindow == nil && weakContentView == nil
            }

            #expect(delegate.settingsWindowControllerForTesting == nil)
            #expect(weakController == nil)
            #expect(weakWindow == nil)
            #expect(weakContentView == nil)
        }

        @Test("reopening after close cold-builds a fresh window")
        func reopenAfterCloseBuildsFreshWindow() throws {
            let delegate = makeDelegate()

            var firstWindowID: ObjectIdentifier?
            try autoreleasepool {
                delegate.showSettings()
                let window = try #require(delegate.settingsWindowControllerForTesting?.window)
                firstWindowID = ObjectIdentifier(window)
                window.close()
            }
            drainRunLoop { delegate.settingsWindowControllerForTesting == nil }
            #expect(delegate.settingsWindowControllerForTesting == nil)

            delegate.showSettings()
            let reopened = try #require(delegate.settingsWindowControllerForTesting?.window)
            #expect(ObjectIdentifier(reopened) != firstWindowID)
            #expect(reopened.contentView != nil)
            reopened.close()
            drainRunLoop { delegate.settingsWindowControllerForTesting == nil }
        }
    }
#endif

#if !LITE_BUILD
extension SettingsWindowLifecycleTests {
    @Test("reopening the running app opens the main window", arguments: [false, true])
    func reopenOpensTheMainWindow(hasVisibleWindows: Bool) throws {
        let delegate = makeDelegate()

        let handled = (delegate as any NSApplicationDelegate)
            .applicationShouldHandleReopen?(NSApp, hasVisibleWindows: hasVisibleWindows)

        #expect(handled == false)
        let window = try #require(delegate.settingsWindowControllerForTesting?.window)
        #expect(window.isVisible)
        window.close()
        drainRunLoop { delegate.settingsWindowControllerForTesting == nil }
    }

    @Test("a reopen before startup completes opens the main window once ScreenManager is in place")
    func reopenBeforeStartupOpensTheMainWindow() throws {
        let delegate = AppDelegate()

        let handled = (delegate as any NSApplicationDelegate)
            .applicationShouldHandleReopen?(NSApp, hasVisibleWindows: false)

        #expect(handled == false)
        #expect(delegate.settingsWindowControllerForTesting == nil)
        delegate.screenManager = makeScreenManager()
        delegate.consumePendingReopen(showSettingsOnLaunch: false, showOnboarding: false)
        let window = try #require(delegate.settingsWindowControllerForTesting?.window)
        #expect(window.isVisible)
        window.close()
        drainRunLoop { delegate.settingsWindowControllerForTesting == nil }
    }

    @Test("a reopen before startup completes leaves the window to one the launch already scheduled")
    func reopenBeforeStartupDefersToTheLaunchWindow() {
        let delegate = AppDelegate()

        _ = (delegate as any NSApplicationDelegate)
            .applicationShouldHandleReopen?(NSApp, hasVisibleWindows: false)
        delegate.screenManager = makeScreenManager()
        delegate.consumePendingReopen(showSettingsOnLaunch: false, showOnboarding: true)

        #expect(delegate.settingsWindowControllerForTesting == nil)
    }

    private func makeScreenManager() -> ScreenManager {
        ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false,
            startAutomation: false,
            powerMonitor: FakePowerMonitor(),
            fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(),
            displayRegistry: FakeDisplayRegistry(),
            featureCatalog: .unconfigured
        ))
    }
}
#endif
