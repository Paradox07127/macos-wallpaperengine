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

    @Test("A potential-EDR change rebuilds a scene session; a resolution change or a non-scene session keeps it",
          arguments: [("edr", WallpaperType.scene), ("resolution", .scene), ("edr", .html)])
    func edrCapabilityChangeRebuildsScene(change: String, type: WallpaperType) {
        let before = SignatureTestScreen()
        let after = SignatureTestScreen()
        if change == "edr" {
            after.potentialEDR = 2
        } else {
            after.width = 2560
        }
        let screen = Screen(nsScreen: before)
        let refreshed = Screen(nsScreen: after)
        let registry = FakeDisplayRegistry(screens: [screen])
        let manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false, startAutomation: false,
            powerMonitor: FakePowerMonitor(), fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(), displayRegistry: registry,
            featureCatalog: FeatureCatalog(capabilities: .pro)
        ))
        defer { manager.tearDownForTermination() }
        manager.wallpapersGloballyEnabled = true
        manager.refreshScreens()
        let session = SignatureTestSession(wallpaperType: type)
        screen.installRuntimeSession(session)
        let previous = ScreenConfigurationSignature(screen: before)
        let current = ScreenConfigurationSignature(screen: after)
        manager.lastScreenSignatures = [previous.displayID: previous]
        registry.screens = [refreshed]

        manager.handleScreenParameterChange(current: [current.displayID: current])

        #expect(previous != current)
        let rebuilds = change == "edr" && type == .scene
        #expect(manager.screens.first === refreshed)
        #expect(session.cleanupCount == (rebuilds ? 1 : 0))
        #expect((refreshed.runtimeSession == nil) == rebuilds)
    }
}

private final class SignatureTestScreen: NSScreen {
    static let displayID: CGDirectDisplayID = 0x6D1D_0E01
    var width: CGFloat = 1920
    var potentialEDR: CGFloat = 1

    override var frame: NSRect {
        NSRect(x: 0, y: 0, width: width, height: 1080)
    }

    override var visibleFrame: NSRect {
        frame
    }

    override var backingScaleFactor: CGFloat {
        2
    }

    override var localizedName: String {
        "Signature Fixture"
    }

    override var maximumFramesPerSecond: Int {
        60
    }

    override var maximumPotentialExtendedDynamicRangeColorComponentValue: CGFloat {
        potentialEDR
    }

    override var deviceDescription: [NSDeviceDescriptionKey: Any] {
        [NSDeviceDescriptionKey("NSScreenNumber"): Self.displayID]
    }
}

@MainActor
private final class SignatureTestSession: WallpaperRuntimeSession {
    let wallpaperType: WallpaperType
    private(set) var cleanupCount = 0

    init(wallpaperType: WallpaperType) {
        self.wallpaperType = wallpaperType
    }

    var summary: WallpaperSessionSummary {
        WallpaperSessionSummary(wallpaperType: wallpaperType, activity: .active, supportsPlaybackControl: false, subtitle: nil)
    }

    var videoPlayer: WallpaperVideoPlayer? {
        nil
    }

    var wallpaperWindow: NSWindow? {
        nil
    }

    func show() {}
    func applyPerformanceProfile(_: WallpaperPerformanceProfile) {}
    func updateFrame(to _: CGRect) {}
    func prepareForDisplay(timeout _: Duration) async -> WallpaperPreparationResult {
        .ready
    }

    func cleanup() {
        cleanupCount += 1
    }
}
