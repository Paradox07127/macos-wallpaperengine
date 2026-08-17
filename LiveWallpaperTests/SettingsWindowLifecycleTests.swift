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

                // Contract half 1: the close button must be allowed to close
                // (the previous behavior returned false and only orderOut'd).
                #expect(delegate.windowShouldClose(window))

                // Contract half 2: an actual close must drop every strong
                // reference the delegate holds.
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
