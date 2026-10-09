import AppKit
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

@MainActor
@Suite("Resetting playback settings reaches a reused video player", .serialized)
struct ResetPlaybackColorSpaceTests {
    @Test("The reused player takes the reset color space")
    func reusedPlayerTakesResetColorSpace() throws {
        SettingsManager.shared.cleanAllSettings(applyLoginSetting: false)
        defer { SettingsManager.shared.cleanAllSettings(applyLoginSetting: false) }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveWallpaper-reset-color-\(UUID().uuidString).mp4")
        try Data([0x00, 0x01]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)

        let screen = Screen(nsScreen: ResetPlaybackTestNSScreen())
        let manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false, startAutomation: false,
            powerMonitor: FakePowerMonitor(), fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(), displayRegistry: FakeDisplayRegistry(screens: [screen]),
            featureCatalog: FeatureCatalog(capabilities: .pro)
        ))
        defer {
            manager.tearDownForTermination()
            screen.resetRuntimeSession()
            manager.configurationStore.remove(for: screen.id)
        }
        var configuration = ScreenConfiguration(screenID: screen.id, videoBookmarkData: bookmark)
        configuration.displayFingerprint = screen.displayFingerprint
        configuration.videoColorSpace = .forceSDR
        manager.saveConfiguration(configuration)

        let player = WallpaperVideoPlayer(url: url, frame: screen.frame, loadImmediately: false)
        player.setVideoColorSpace(.forceSDR)
        screen.installRuntimeSession(VideoWallpaperSession(player: player))

        manager.resetPlaybackSettings(for: screen)

        let reset = try #require(manager.getConfiguration(for: screen)).videoColorSpace
        try #require(reset != .forceSDR, "the display defaults must differ from the seeded color space")
        #expect(screen.videoPlayer === player, "the reset rebuilt the player instead of reusing it")
        #expect(player.currentColorSpacePreference == reset)
    }
}

private final class ResetPlaybackTestNSScreen: NSScreen {
    override var frame: NSRect {
        NSRect(x: 0, y: 0, width: 800, height: 600)
    }

    override var deviceDescription: [NSDeviceDescriptionKey: Any] {
        [NSDeviceDescriptionKey("NSScreenNumber"): UInt32(0x4E5E_7C01)]
    }

    override var localizedName: String {
        "Reset Playback Color Space Test"
    }
}
