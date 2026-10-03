import AppKit
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

@MainActor
@Suite("Persistent per-display user pause")
struct PersistentUserPauseTests {
    private static let inlineHTML = HTMLSource.inline("<html></html>")

    private func makeManager(videoLoader: FakePlayableVideoLoader = FakePlayableVideoLoader()) -> ScreenManager {
        ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false,
            startAutomation: false,
            powerMonitor: FakePowerMonitor(),
            fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: videoLoader,
            displayRegistry: FakeDisplayRegistry(),
            featureCatalog: FeatureCatalog(capabilities: .pro)
        ))
    }

    /// Installs a fresh playing session and runs the same reset the commit paths run.
    @discardableResult
    private func commitFreshSession(
        on screen: Screen,
        in manager: ScreenManager,
        type: WallpaperType = .video
    ) -> PauseFakePlaybackController {
        let playback = PauseFakePlaybackController(wallpaperType: type)
        screen.installRuntimeSession(playback)
        manager.resetPlaybackStateMachine(for: screen)
        return playback
    }

    private enum Seed {
        /// No saved video, so `switchToVideoWallpaper` returns before building a session.
        case htmlWithoutSavedVideo
        case video
        case htmlWithSavedHTML
    }

    private static func configuration(_ seed: Seed, for screenID: CGDirectDisplayID) -> ScreenConfiguration {
        switch seed {
        case .video:
            return ScreenConfiguration(screenID: screenID, wallpaper: .video(bookmarkData: Data([0xC0, 0xDE])))
        case .htmlWithoutSavedVideo, .htmlWithSavedHTML:
            var config = ScreenConfiguration(
                screenID: screenID,
                wallpaper: .html(source: inlineHTML, config: .default),
                savedVideoBookmarkData: nil
            )
            if seed == .htmlWithSavedHTML {
                config.savedHTMLSource = inlineHTML
                config.savedHTMLConfig = .default
            }
            return config
        }
    }

    private func withConfiguredScreen(
        _ seed: Seed = .htmlWithoutSavedVideo,
        sessionType: WallpaperType = .video,
        _ body: (ScreenManager, Screen, PauseFakePlaybackController) throws -> Void
    ) rethrows {
        guard let nsScreen = NSScreen.screens.first else {
            Issue.record("No NSScreen available for test")
            return
        }
        let screen = Screen(nsScreen: nsScreen)
        let original = SettingsManager.shared.loadConfigurations()
        let originalSettings = SettingsManager.shared.loadGlobalSettings()
        defer {
            screen.resetRuntimeSession()
            SettingsManager.shared.replaceAllConfigurations(original)
            SettingsManager.shared.saveGlobalSettings(originalSettings)
        }
        var cleared = originalSettings
        cleared.pausedDisplayKeys = []
        SettingsManager.shared.saveGlobalSettings(cleared)
        SettingsManager.shared.replaceAllConfigurations([Self.configuration(seed, for: screen.id)])
        let manager = makeManager()
        manager.screens = [screen]
        let session = commitFreshSession(on: screen, in: manager, type: sessionType)
        try body(manager, screen, session)
    }

    private func persistedPause(_ manager: ScreenManager, _ screen: Screen) -> Bool {
        manager.isUserPaused(screen.id, fingerprint: screen.displayFingerprint)
    }

    @Test("A manual pause survives the session rebuild that property edits and rotation run")
    func pauseSurvivesSessionRebuild() {
        withConfiguredScreen { manager, screen, _ in
            manager.togglePlayback(for: screen)
            #expect(persistedPause(manager, screen) == true)

            let rebuilt = commitFreshSession(on: screen, in: manager)

            #expect(!rebuilt.userIntendsToPlay)
            #expect(!rebuilt.isPlaying)
            #expect(!manager.playbackStateMachine(for: screen.id).userIntendsToPlay)
        }
    }

    @Test("A manual pause survives a new ScreenManager reading the same store")
    func pauseSurvivesRelaunch() {
        withConfiguredScreen { manager, screen, _ in
            manager.togglePlayback(for: screen)

            let reconnected = makeManager()
            reconnected.screens = [screen]
            let session = commitFreshSession(on: screen, in: reconnected)
            #expect(!session.userIntendsToPlay)
            #expect(!reconnected.playbackStateMachine(for: screen.id).userIntendsToPlay)
        }
    }

    @Test("A reconnected display finds its pause by fingerprint, not by display ID")
    func pauseRestoresByFingerprint() throws {
        try withConfiguredScreen { manager, screen, _ in
            try #require(!screen.displayFingerprint.isUnknownDisplayFingerprint)
            manager.togglePlayback(for: screen)
            #expect(SettingsManager.shared.loadGlobalSettings().pausedDisplayKeys == [screen.displayFingerprint])

            let reconnected = makeManager()
            reconnected.screens = [screen]
            #expect(!reconnected.playbackStateMachine(for: screen.id).userIntendsToPlay)
            #expect(!commitFreshSession(on: screen, in: reconnected).userIntendsToPlay)
        }
    }

    @Test("A display without a usable fingerprint is keyed by its ID")
    func unknownFingerprintFallsBackToID() {
        #expect(ScreenManager.userPauseKey(screenID: 7, fingerprint: "unknown:0:0:0:Panel") == "id:7")
        #expect(ScreenManager.userPauseKey(screenID: 7, fingerprint: nil) == "id:7")
        #expect(ScreenManager.userPauseKey(screenID: 7, fingerprint: "uuid:ABC") == "uuid:ABC")
    }

    @Test("Legacy global settings decode with no paused displays")
    func pausedDisplayKeysCodableCompat() throws {
        var settings = GlobalSettings()
        settings.pausedDisplayKeys = ["uuid:ABC", "id:7"]
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(GlobalSettings.self, from: data).pausedDisplayKeys == ["uuid:ABC", "id:7"])

        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "pausedDisplayKeys")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        #expect(try JSONDecoder().decode(GlobalSettings.self, from: legacy).pausedDisplayKeys.isEmpty)
    }

    @Test("Pausing and playing never advance the screen's configuration revision")
    func pauseKeepsConfigurationRevision() {
        withConfiguredScreen { manager, screen, _ in
            let before = manager.configurationStore.revision(for: screen.id)

            manager.togglePlayback(for: screen)
            #expect(manager.configurationStore.revision(for: screen.id) == before)

            manager.togglePlayback()
            #expect(manager.configurationStore.revision(for: screen.id) == before)
        }
    }

    @Test("Pressing play clears the persisted pause")
    func playClearsPersistedPause() {
        withConfiguredScreen { manager, screen, _ in
            manager.togglePlayback(for: screen)
            manager.togglePlayback(for: screen)

            #expect(persistedPause(manager, screen) == false)
            #expect(commitFreshSession(on: screen, in: manager).userIntendsToPlay)
        }
    }

    @Test("The global toggle persists and clears the pause")
    func globalTogglePersistsPause() {
        withConfiguredScreen { manager, screen, _ in
            manager.togglePlayback()
            #expect(persistedPause(manager, screen) == true)

            manager.togglePlayback()
            #expect(persistedPause(manager, screen) == false)
        }
    }

    @Test("An explicit wallpaper pick clears the persisted pause")
    func explicitSelectionClearsPause() {
        withConfiguredScreen { manager, screen, _ in
            manager.togglePlayback(for: screen)
            #expect(persistedPause(manager, screen) == true)

            manager.switchToVideoWallpaper(for: screen)

            #expect(persistedPause(manager, screen) == false)
            let picked = commitFreshSession(on: screen, in: manager)
            #expect(picked.userIntendsToPlay)
            #expect(picked.pauseCount == 0)
        }
    }

    @Test("Re-picking the active video keeps the session and starts it playing")
    func reusedVideoSessionPlaysOnPick() {
        withConfiguredScreen(.video) { manager, screen, session in
            manager.togglePlayback(for: screen)
            #expect(!session.isPlaying)

            manager.switchToVideoWallpaper(for: screen)

            #expect((screen.runtimeSession as AnyObject?) === session)
            #expect(session.userIntendsToPlay)
            #expect(session.isPlaying)
        }
    }

    @Test("Re-picking the active HTML page keeps the session and starts it playing")
    func reusedHTMLSessionPlaysOnPick() {
        withConfiguredScreen(.htmlWithSavedHTML, sessionType: .html) { manager, screen, session in
            manager.togglePlayback(for: screen)
            #expect(!session.isPlaying)

            manager.switchToHTMLWallpaper(for: screen)

            #expect((screen.runtimeSession as AnyObject?) === session)
            #expect(session.userIntendsToPlay)
            #expect(session.isPlaying)
        }
    }

    @Test("Re-picking the playing video file from the library keeps its player and starts it playing")
    func reusedVideoPlayerPlaysOnLibraryPick() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveWallpaper-pause-repick-\(UUID().uuidString).mp4")
        try Data([0x00, 0x01]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)

        try withConfiguredScreen(.video) { manager, screen, session in
            manager.configurationStore.save(ScreenConfiguration(screenID: screen.id, videoBookmarkData: bookmark))
            let player = WallpaperVideoPlayer(url: url, frame: screen.frame, loadImmediately: false)
            defer { player.cleanup() }
            session.videoPlayer = player
            manager.togglePlayback(for: screen)
            try #require(persistedPause(manager, screen) == true)

            manager.setVideo(url: url, bookmarkData: bookmark, for: screen)

            #expect((screen.runtimeSession as AnyObject?) === session)
            #expect(screen.videoPlayer === player)
            #expect(persistedPause(manager, screen) == false)
            #expect(screen.playbackController?.userIntendsToPlay == true)
        }
    }

    @Test("Re-picking the playing HTML page from the library keeps its session and starts it playing")
    func reusedHTMLSessionPlaysOnLibraryPick() throws {
        try withConfiguredScreen(.htmlWithSavedHTML, sessionType: .html) { manager, screen, session in
            manager.togglePlayback(for: screen)
            try #require(persistedPause(manager, screen) == true)

            manager.setHTMLWallpaper(source: Self.inlineHTML, config: .default, for: screen)

            #expect((screen.runtimeSession as AnyObject?) === session)
            #expect(persistedPause(manager, screen) == false)
            #expect(screen.playbackController?.userIntendsToPlay == true)
        }
    }

    @Test("A scheme saved from a paused display carries no pause state")
    func schemeOmitsPauseState() throws {
        try withConfiguredScreen { manager, screen, _ in
            manager.togglePlayback(for: screen)
            let live = try #require(manager.configurationStore.get(for: screen.id))

            let scheme = ScreenScheme(name: "Desk", configuration: live, overlay: .default)
            let json = try #require(String(data: JSONEncoder().encode(scheme), encoding: .utf8))

            #expect(!json.lowercased().contains("paused"))
        }
    }

    @Test("Without a manual pause a rebuilt session keeps playing")
    func unpausedRebuildKeepsPlaying() {
        withConfiguredScreen { manager, screen, _ in
            let rebuilt = commitFreshSession(on: screen, in: manager)

            #expect(rebuilt.userIntendsToPlay)
            #expect(rebuilt.pauseCount == 0)
            #expect(manager.playbackStateMachine(for: screen.id).userIntendsToPlay)
            #expect(persistedPause(manager, screen) == false)
        }
    }

    /// A video display manually paused before `body`, with a fresh session installed.
    private func withPausedVideoScreen(
        videoLoader: FakePlayableVideoLoader,
        _ body: (ScreenManager, Screen) async throws -> Void
    ) async throws {
        guard let nsScreen = NSScreen.screens.first else {
            Issue.record("No NSScreen available for test")
            return
        }
        let screen = Screen(nsScreen: nsScreen)
        let original = SettingsManager.shared.loadConfigurations()
        let originalSettings = SettingsManager.shared.loadGlobalSettings()
        defer {
            screen.resetRuntimeSession()
            SettingsManager.shared.replaceAllConfigurations(original)
            SettingsManager.shared.saveGlobalSettings(originalSettings)
        }
        var cleared = originalSettings
        cleared.pausedDisplayKeys = []
        SettingsManager.shared.saveGlobalSettings(cleared)
        SettingsManager.shared.replaceAllConfigurations([Self.configuration(.video, for: screen.id)])
        let manager = makeManager(videoLoader: videoLoader)
        manager.screens = [screen]
        commitFreshSession(on: screen, in: manager)
        manager.togglePlayback(for: screen)
        try #require(persistedPause(manager, screen) == true)
        try await body(manager, screen)
        manager.bumpTransition(for: screen.id)
    }

    private static func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while await !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(50))
    }

    private static func temporaryVideo() throws -> (url: URL, bookmark: Data) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveWallpaper-pause-pick-\(UUID().uuidString).mp4")
        try Data([0x00, 0x01]).write(to: url)
        return try (url, url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
    }

    @Test("A library pick whose new video fails to prepare leaves the old wallpaper manually paused", .timeLimit(.minutes(1)))
    func failedLibraryPickKeepsPause() async throws {
        let video = try Self.temporaryVideo()
        defer { try? FileManager.default.removeItem(at: video.url) }
        let loader = FakePlayableVideoLoader(validationError: .validationFailed)
        try await withPausedVideoScreen(videoLoader: loader) { manager, screen in
            manager.setVideo(url: video.url, bookmarkData: video.bookmark, for: screen)
            try await Self.waitUntil { await loader.completedValidationCount >= 1 }

            #expect(persistedPause(manager, screen) == true, "a failed pick cleared the pause, so the old wallpaper resumes on its next rebuild")
            #expect(!commitFreshSession(on: screen, in: manager).userIntendsToPlay)
        }
    }

    @Test("A library pick that commits clears the manual pause", .timeLimit(.minutes(1)))
    func committedLibraryPickClearsPause() async throws {
        let video = try Self.temporaryVideo()
        defer { try? FileManager.default.removeItem(at: video.url) }
        try await withPausedVideoScreen(videoLoader: FakePlayableVideoLoader()) { manager, screen in
            // Rendering off commits the pick without building a player the fake file could not feed.
            manager.wallpapersGloballyEnabled = false
            manager.setVideo(url: video.url, bookmarkData: video.bookmark, for: screen)
            try await Self.waitUntil { manager.configurationStore.get(for: screen.id)?.videoBookmarkData == video.bookmark }

            #expect(manager.configurationStore.get(for: screen.id)?.videoBookmarkData == video.bookmark)
            #expect(persistedPause(manager, screen) == false)
        }
    }
}

private final class PauseFakePlaybackController: WallpaperPlaybackControllable, WallpaperIntentMachineAdopting {
    var playbackMachine = WallpaperPlaybackStateMachine()
    var userIntendsToPlay: Bool {
        playbackMachine.userIntendsToPlay
    }

    let wallpaperType: WallpaperType
    var isPlaying = true
    var pauseCount = 0

    init(wallpaperType: WallpaperType) {
        self.wallpaperType = wallpaperType
    }

    var summary: WallpaperSessionSummary {
        WallpaperSessionSummary(
            wallpaperType: wallpaperType,
            activity: isPlaying ? .active : .paused,
            supportsPlaybackControl: true,
            subtitle: "PauseFake"
        )
    }

    var videoPlayer: WallpaperVideoPlayer?

    var wallpaperWindow: NSWindow? {
        nil
    }

    func show() {}
    func applyPerformanceProfile(_: WallpaperPerformanceProfile) {}
    func updateFrame(to _: CGRect) {}
    func cleanup() {}

    func prepareForDisplay(timeout: Duration) async -> WallpaperPreparationResult {
        await WallpaperPreparationWaiter.wait(timeout: timeout) { nil }
    }

    func play() {
        playbackMachine.userPlay()
        isPlaying = true
    }

    func pause() {
        pauseCount += 1
        playbackMachine.userPause()
        isPlaying = false
    }
}
