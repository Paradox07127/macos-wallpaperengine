import AppKit
import Foundation
import LiveWallpaperCore
import Testing
@testable import LiveWallpaper

@Suite("Lite SKU smoke tests") @MainActor
struct LiteSKUSmokeTests {

    @Test("ProductCapabilities.lite drops only the heavy GPU pipelines")
    func liteCatalogSurfaceArea() {
        let capabilities = ProductCapabilities.lite
        #expect(capabilities.sku == .lite)
        #expect(capabilities.selectableWallpaperTypes == [.video, .html])
        #expect(capabilities.canRender(.video))
        #expect(capabilities.canRender(.html))
        #expect(!capabilities.canRender(.scene))
        #expect(capabilities.selectableWallpaperModes.contains(.playlist))
        #expect(capabilities.selectableWallpaperModes.contains(.schedule))
        #expect(capabilities.enabledFeatures.contains(.appleAerials))
        #expect(capabilities.enabledFeatures.contains(.scheduleAutomation))
        #expect(capabilities.enabledFeatures.contains(.playlists))
        #expect(capabilities.enabledFeatures.contains(.systemMonitor))
        #expect(capabilities.enabledFeatures.contains(.globalShortcuts))
        #expect(capabilities.enabledFeatures.contains(.lockScreenSnapshots))
        #expect(capabilities.enabledFeatures.contains(.inspectorPreview))
        #expect(capabilities.enabledFeatures.contains(.videoEffects))
        #expect(capabilities.enabledFeatures.contains(.weatherReactive))
        #expect(capabilities.enabledFeatures.contains(.monitorOverlay))
        #expect(!capabilities.enabledFeatures.contains(.wpeImport))
    }

    @Test("ScreenManager constructs cleanly under the Lite catalogue")
    func liteScreenManagerInitDoesNotCrash() {
        guard let screen = Self.makeScreen() else {
            Issue.record("No NSScreen available for Lite smoke test")
            return
        }
        let manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false,
            startAutomation: false,
            powerMonitor: FakePowerMonitor(),
            fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(),
            displayRegistry: FakeDisplayRegistry(screens: [screen]),
            featureCatalog: FeatureCatalog(capabilities: .lite),
            originReconciler: PreservingOriginReconciler()
        ))

        #expect(manager.featureCatalog.capabilities.sku == .lite)
        #expect(manager.screens.map(\.id) == [screen.id])
    }

    private static func makeScreen() -> Screen? {
        NSScreen.screens.first.map(Screen.init(nsScreen:))
    }
}
