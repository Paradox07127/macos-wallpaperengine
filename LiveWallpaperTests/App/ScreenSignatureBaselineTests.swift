import AppKit
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

@MainActor
@Suite("Screen layout signatures have a launch baseline")
struct ScreenSignatureBaselineTests {
    @Test("A new manager already knows the current layout, so the first refresh-rate change is detected")
    func launchRecordsCurrentLayout() throws {
        let layout = ScreenConfigurationSignature.currentLayout()
        try #require(!layout.isEmpty, "the test host has no active display to sign")
        let manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false, startAutomation: false,
            powerMonitor: FakePowerMonitor(), fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(), displayRegistry: FakeDisplayRegistry(),
            featureCatalog: FeatureCatalog(capabilities: .pro)
        ))
        defer { manager.tearDownForTermination() }
        #expect(manager.lastScreenSignatures == layout)
    }
}
