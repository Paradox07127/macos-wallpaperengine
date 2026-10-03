import AppKit
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

@MainActor
@Suite("Persistent per-display user pause")
struct PersistentUserPauseTests {
    private static let inlineHTML = HTMLSource.inline("<html></html>")

    private func makeManager() -> ScreenManager {
        ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false,
            startAutomation: false,
            powerMonitor: FakePowerMonitor(),
            fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(),
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

    @Test("An explicit wallpaper pick clears the persisted pause once it commits")
    func explicitSelectionClearsPause() {
        withConfiguredScreen(.video, sessionType: .html) { manager, screen, _ in
            manager.togglePlayback(for: screen)
            #expect(persistedPause(manager, screen) == true)
            // Rendering off commits the pick synchronously, without preparing a session.
            manager.wallpapersGloballyEnabled = false

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

    private static func temporaryVideo() throws -> (url: URL, bookmark: Data) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveWallpaper-pause-pick-\(UUID().uuidString).mp4")
        try Data([0x00, 0x01]).write(to: url)
        return try (url, url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
    }

    /// Synchronous on purpose: the pause key and saved rows are process-wide, and an await would let parallel suites rewrite them.
    @Test("A library pick for a new video leaves the manual pause in place until the pick commits")
    func newVideoPickKeepsPauseUntilCommit() throws {
        let video = try Self.temporaryVideo()
        defer { try? FileManager.default.removeItem(at: video.url) }
        try withConfiguredScreen(.video) { manager, screen, _ in
            defer { manager.bumpTransition(for: screen.id) }
            manager.togglePlayback(for: screen)
            try #require(persistedPause(manager, screen) == true)

            manager.setVideo(url: video.url, bookmarkData: video.bookmark, for: screen)

            #expect(persistedPause(manager, screen) == true, "the pause is cleared before the new video is prepared, so a failed pick resumes the old wallpaper")
        }
    }

    enum NewPick: CaseIterable {
        case scene, htmlTypeSwitch, videoTypeSwitch, htmlPage, htmlPagePreservingConfig
    }

    /// Seeds a running wallpaper that the pick must replace rather than reuse.
    private static func seed(for pick: NewPick) -> (Seed, WallpaperType) {
        switch pick {
        case .scene, .htmlPage, .htmlPagePreservingConfig: (.video, .video)
        case .htmlTypeSwitch: (.htmlWithSavedHTML, .video)
        case .videoTypeSwitch: (.video, .html)
        }
    }

    private func perform(_ pick: NewPick, on screen: Screen, in manager: ScreenManager) {
        switch pick {
        case .scene:
            let scene = SceneDescriptor(workshopID: "pause-pick", cacheRelativePath: "pause-pick", entryFile: "scene.json", capabilityTier: .imageOnly)
            manager.setSceneWallpaper(descriptor: scene, origin: nil, for: screen)
        case .htmlTypeSwitch:
            manager.switchToHTMLWallpaper(for: screen)
        case .videoTypeSwitch:
            manager.switchToVideoWallpaper(for: screen)
        case .htmlPage:
            manager.setHTMLWallpaper(source: Self.inlineHTML, for: screen)
        case .htmlPagePreservingConfig:
            manager.setHTMLWallpaperPreservingConfig(source: Self.inlineHTML, for: screen)
        }
    }

    /// Synchronous on purpose: the pause key and saved rows are process-wide, and an await would let parallel suites rewrite them.
    @Test("A pick for a new wallpaper leaves the manual pause in place until the pick commits", arguments: NewPick.allCases)
    func newPickKeepsPauseUntilCommit(_ pick: NewPick) throws {
        let (seed, sessionType) = Self.seed(for: pick)
        try withConfiguredScreen(seed, sessionType: sessionType) { manager, screen, _ in
            defer { manager.bumpTransition(for: screen.id) }
            manager.togglePlayback(for: screen)
            try #require(persistedPause(manager, screen) == true)

            perform(pick, on: screen, in: manager)

            #expect(persistedPause(manager, screen) == true, "the pause is cleared before the new wallpaper is prepared, so a failed pick resumes the old wallpaper")
        }
    }

    @Test("A pick for a new wallpaper clears the manual pause when it commits", arguments: NewPick.allCases)
    func committedPickClearsPause(_ pick: NewPick) throws {
        let (seed, sessionType) = Self.seed(for: pick)
        try withConfiguredScreen(seed, sessionType: sessionType) { manager, screen, _ in
            manager.togglePlayback(for: screen)
            try #require(persistedPause(manager, screen) == true)
            manager.wallpapersGloballyEnabled = false

            perform(pick, on: screen, in: manager)

            #expect(persistedPause(manager, screen) == false)
            #expect(commitFreshSession(on: screen, in: manager).userIntendsToPlay)
        }
    }

    @Test("An HTML page pick runs its commit hook only when the new page commits", arguments: [false, true])
    func htmlPickCommitHookFollowsCommit(commits: Bool) throws {
        let screen = try #require(NSScreen.screens.first.map(Screen.init(nsScreen:)))
        let store = WallpaperConfigurationStore(persistence: PauseConfigurationMemory())
        var hookRuns = 0
        let coordinator = HTMLWallpaperCoordinator(
            configurationStore: store, screensProvider: { [screen] }, saveConfiguration: { store.save($0) },
            restoreWallpaperSession: { _, _, _, beforeCommit in
                if commits {
                    _ = beforeCommit()
                }
            },
            notifyWallpaperSessionChanged: {}, originReconciler: PreservingOriginReconciler()
        )

        coordinator.setWallpaper(source: Self.inlineHTML, for: screen, onCommit: { hookRuns += 1 })
        coordinator.setWallpaperPreservingConfig(source: .inline("<html>next</html>"), for: screen, onCommit: { hookRuns += 1 })

        #expect(hookRuns == (commits ? 2 : 0))
    }

    /// Picks a video through a coordinator over a private store; returns how often its commit hook ran.
    private func commitHookRuns(validationFails: Bool) async throws -> Int {
        let screen = try #require(NSScreen.screens.first.map(Screen.init(nsScreen:)))
        let store = WallpaperConfigurationStore(persistence: PauseConfigurationMemory())
        var previous = ScreenConfiguration(screenID: screen.id, videoBookmarkData: Data([0x11]))
        previous.displayFingerprint = screen.displayFingerprint
        store.save(previous)
        let video = try Self.temporaryVideo()
        defer { try? FileManager.default.removeItem(at: video.url) }
        var commits = 0
        var failures = 0
        let coordinator = PlaybackCoordinator(
            configurationStore: store,
            configurationCommands: DisplayConfigurationTestSupport.commands(for: store),
            playableVideoLoader: FakePlayableVideoLoader(validationError: validationFails ? .validationFailed : nil),
            validateSavedVideoConfiguration: { _ in true },
            applyPolicy: { _ in }, applyVideoEffects: { _, _ in },
            refreshRateLookup: { _ in 60 }, screensProvider: { [screen] },
            markSessionStateChanged: {}, releaseRuntimeSession: { $0.resetRuntimeSession() },
            notifyWallpaperSessionChanged: {},
            reportPreparationFailure: { _, _, _ in failures += 1 },
            originReconciler: PreservingOriginReconciler(),
            // Rendering off commits the pick without building a player the fake file could not feed.
            isGloballyEnabled: { false }
        )
        defer { coordinator.transition.bumpTransition(for: screen.id) }

        coordinator.setVideo(url: video.url, bookmarkData: video.bookmark, for: screen, onCommit: { commits += 1 })

        // CI's parallel shard can stall the main actor for tens of seconds; the suite's one-minute limit still bounds a hang.
        let deadline = ContinuousClock.now + .seconds(50)
        while commits + failures == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(commits + failures == 1)
        #expect((store.get(for: screen.id)?.videoBookmarkData == video.bookmark) == !validationFails)
        return commits
    }

    @Test("A video pick whose candidate fails never runs the commit hook that clears the pause", .timeLimit(.minutes(1)))
    func failedVideoPickSkipsCommitHook() async throws {
        #expect(try await commitHookRuns(validationFails: true) == 0)
    }

    @Test("A video pick that commits runs the commit hook once", .timeLimit(.minutes(1)))
    func committedVideoPickRunsCommitHook() async throws {
        #expect(try await commitHookRuns(validationFails: false) == 1)
    }
}

@MainActor
private final class PauseConfigurationMemory: ScreenConfigurationPersisting {
    private var configurations: [CGDirectDisplayID: ScreenConfiguration] = [:]

    func getConfiguration(for screenID: CGDirectDisplayID) -> ScreenConfiguration? {
        configurations[screenID]
    }

    func saveConfiguration(_ configuration: ScreenConfiguration) {
        configurations[configuration.screenID] = configuration
    }

    func cleanSettingsForScreen(_ screenID: CGDirectDisplayID) {
        configurations[screenID] = nil
    }

    func loadConfigurations() -> [ScreenConfiguration] {
        Array(configurations.values)
    }

    func replaceAllConfigurations(_ configurations: [ScreenConfiguration]) {
        self.configurations = Dictionary(uniqueKeysWithValues: configurations.map { ($0.screenID, $0) })
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
