import AppKit
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

/// The detail hero's HUD writes through the same draft the inspector does; these pin the two ends
/// of that path — which writer a fill-mode change picks, and what the draft reads back afterwards.
@MainActor
@Suite("Display detail host", .serialized)
struct DisplayDetailHostTests {
    @Test("A scene's HUD offers Center, which video has no mode for")
    func sceneFitModesIncludeCenter() {
        #expect(DisplayDetailHost.fitModes(for: .scene) == VideoFitMode.sceneModes)
        #expect(DisplayDetailHost.fitModes(for: .video) == VideoFitMode.videoModes)
        // A scene left on Center must find its own mode in the segment, or it cannot get back to it.
        #expect(DisplayDetailHost.fitModes(for: .scene).contains(.center))
        #expect(!DisplayDetailHost.fitModes(for: .video).contains(.center))
    }

    @Test("Only a scene routes its fill mode through the scene writer")
    func sceneFitModeUsesItsOwnWriter() {
        #expect(DisplayDetailHost.usesSceneFitWriter(.scene))
        #expect(!DisplayDetailHost.usesSceneFitWriter(.video))
        #expect(!DisplayDetailHost.usesSceneFitWriter(.html))
    }

    @Test("The HUD's fill mode, mute and frame rate land in the store the draft is rebuilt from")
    func hudWritesRoundTripThroughTheDraft() {
        let harness = Harness()
        defer { harness.close() }
        DisplayDetailHost.writeFitMode(
            .aspectFit, type: .video, screen: harness.screen, screenManager: harness.manager
        )
        harness.manager.updateMuted(false, for: harness.screen)
        harness.manager.updateFrameRateLimit(.fps24, for: harness.screen)

        let draft = DraftState.from(config: harness.manager.getConfiguration(for: harness.screen), fallbackHasPreviewSource: false)
        #expect(draft.selectedFitMode == .aspectFit)
        #expect(!draft.videoMuted)
        #expect(draft.selectedFrameRateLimit == .fps24)
    }

    @Test("A scene's fill mode is persisted by the scene writer too")
    func sceneFitModeIsPersisted() {
        let harness = Harness()
        defer { harness.close() }
        DisplayDetailHost.writeFitMode(
            .center, type: .scene, screen: harness.screen, screenManager: harness.manager
        )
        #expect(harness.manager.getConfiguration(for: harness.screen)?.fitMode == .center)
    }

    @MainActor
    private final class Harness {
        let screen = Screen(nsScreen: DetailHostTestScreen())
        let manager: ScreenManager

        init() {
            manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
                restoreSavedWallpapers: false, startAutomation: false,
                powerMonitor: FakePowerMonitor(), fullScreenDetector: FakeFullScreenDetector(),
                playableVideoLoader: FakePlayableVideoLoader(), displayRegistry: FakeDisplayRegistry(screens: [screen]),
                featureCatalog: FeatureCatalog(capabilities: .lite), originReconciler: PreservingOriginReconciler()
            ))
            var configuration = ScreenConfiguration(
                screenID: screen.id, wallpaper: .html(source: .inline("Test"), config: .default)
            )
            configuration.displayFingerprint = screen.displayFingerprint
            configuration.muted = true
            manager.configurationStore.save(configuration)
        }

        func close() {
            manager.tearDownForTermination()
            manager.configurationStore.remove(for: screen.id)
        }
    }
}

private final class DetailHostTestScreen: NSScreen {
    override var frame: NSRect {
        NSRect(x: 0, y: 0, width: 800, height: 600)
    }

    override var deviceDescription: [NSDeviceDescriptionKey: Any] {
        [NSDeviceDescriptionKey("NSScreenNumber"): UInt32(0xED3B_0001)]
    }

    override var localizedName: String {
        "Detail host test"
    }

    /// `getScreenRefreshRate` falls back to this; AppKit traps when a `init()`-built screen is asked.
    override var maximumFramesPerSecond: Int {
        60
    }
}
