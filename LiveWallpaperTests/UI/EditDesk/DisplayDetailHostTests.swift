import AppKit
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

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

    @Test("Reset Display Settings keeps a Workshop web page's origin, so it stays network-isolated")
    func resetKeepsWorkshopWebOrigin() {
        let harness = Harness()
        defer { harness.close() }
        var workshop = HTMLConfig.default
        workshop.originKind = .workshopImport
        workshop.customCSS = "body { color: red }"
        var configuration = ScreenConfiguration(
            screenID: harness.screen.id, wallpaper: .html(source: .inline("Test"), config: workshop)
        )
        configuration.displayFingerprint = harness.screen.displayFingerprint
        harness.manager.configurationStore.save(configuration)
        // With the master gate off the reset commits synchronously and builds no web view.
        harness.manager.wallpapersGloballyEnabled = false

        harness.manager.resetDisplaySettings(for: harness.screen)

        let reset = harness.manager.getConfiguration(for: harness.screen)
        guard case let .html(_, active)? = reset?.activeWallpaper else {
            Issue.record("The reset dropped the web wallpaper")
            return
        }
        #expect(active.originKind == .workshopImport)
        #expect(active.requiresNetworkIsolation)
        #expect(reset?.savedHTMLConfig?.originKind == .workshopImport)
        // Control: the page's own settings are still reset.
        #expect(active.customCSS == nil)
    }

    @Test("Reset Display Settings is one undo step, and undoing it puts back the whole configuration it replaced", .timeLimit(.minutes(1)))
    func resetDisplaySettingsUndoes() async throws {
        let harness = Harness()
        defer { harness.close() }
        // With the master gate off every commit lands synchronously and builds no web view.
        harness.manager.wallpapersGloballyEnabled = false
        var configuration = try #require(harness.manager.getConfiguration(for: harness.screen))
        configuration.shufflePlaylist = true
        configuration.playbackSpeed = 1.5
        harness.manager.configurationStore.save(configuration)
        let before = try #require(harness.manager.getConfiguration(for: harness.screen))
        let bookmarks = BookmarkStore(persistence: DeferredBookmarkPersistence())
        let undo = EditDeskUndoStack(
            manager: harness.manager,
            router: ApplyRouter(manager: harness.manager, bookmarks: bookmarks, sceneCapable: false),
            bookmarks: bookmarks
        )
        let toasts = EditDeskToastCenter()

        DisplayDetailHost.resetDisplaySettings(for: harness.screen, manager: harness.manager, undo: undo, toasts: toasts)
        #expect(harness.manager.getConfiguration(for: harness.screen)?.shufflePlaylist == false)
        let deadline = ContinuousClock.now + .seconds(2)
        while undo.undoSteps.isEmpty, ContinuousClock.now < deadline {
            await Task.yield()
        }
        #expect(undo.undoSteps.map(\.action) == [.resetDisplaySettings])
        #expect(toasts.toasts.last?.undoStepID == undo.undoSteps.last?.id)

        let outcome = try #require(await undo.undo())
        #expect(outcome.restored == [harness.screen.name])
        #expect(harness.manager.getConfiguration(for: harness.screen) == before)
    }

    @Test("A failure route opens that failed attempt's page, not an older one's")
    func failureRouteOpensTheAttempt() {
        let harness = Harness()
        defer { harness.close() }
        let id = harness.failedAttempt(inspecting: false)

        // Results go through locals: a failed `#expect` on the call crashes while describing its arguments.
        let openedStale = DisplayDetailHost.openFailure(UUID(), on: harness.screen, manager: harness.manager)
        #expect(!openedStale)
        #expect(harness.manager.inspectedWallpaperAttempt(for: harness.screen) == nil)
        let opened = DisplayDetailHost.openFailure(id, on: harness.screen, manager: harness.manager)
        #expect(opened)
        #expect(harness.manager.inspectedWallpaperAttempt(for: harness.screen)?.id == id)
    }

    @Test("Leaving the detail hands the inspector back to the running wallpaper")
    func leavingClosesTheFailure() {
        let harness = Harness()
        defer { harness.close() }
        let id = harness.failedAttempt(inspecting: true)

        DisplayDetailHost.closeFailure(on: harness.screen, manager: harness.manager)
        #expect(harness.manager.inspectedWallpaperAttempt(for: harness.screen) == nil)
        // The failure itself stays for the notice and the home chip.
        #expect(harness.manager.wallpaperLoads.attempt(for: harness.screen)?.id == id)

        // Control: an attempt that is still preparing keeps its page.
        let preparing = harness.manager.wallpaperLoads.begin(for: harness.screen, title: "Scene")
        DisplayDetailHost.closeFailure(on: harness.screen, manager: harness.manager)
        #expect(harness.manager.inspectedWallpaperAttempt(for: harness.screen)?.id == preparing)
    }

    @Test("Play/Pause follows the user's intent, so a wallpaper held by policy can still be paused")
    func toggleFollowsIntent() {
        let heldByPolicy = IntentPlayback(isPlaying: false, intendsToPlay: true)
        DisplayDetailHost.togglePlayback(heldByPolicy)
        #expect(heldByPolicy.pauseCount == 1)
        #expect(!heldByPolicy.userIntendsToPlay)
        // Control: a user pause plays again.
        let paused = IntentPlayback(isPlaying: false, intendsToPlay: false)
        DisplayDetailHost.togglePlayback(paused)
        #expect(paused.playCount == 1)
    }

    @Test("The web address prompt starts from the running URL; other sources start empty")
    func webAddressPrefill() throws {
        let url = try #require(URL(string: "https://example.com/wall"))
        #expect(DisplayDetailHost.editableWebAddress(.html(source: .url(url), config: .default)) == "https://example.com/wall")
        let folder = HTMLSource.folder(bookmarkData: Data("folder".utf8), indexFileName: "index.html")
        #expect(DisplayDetailHost.editableWebAddress(.html(source: folder, config: .default)).isEmpty)
        #expect(DisplayDetailHost.editableWebAddress(.video(bookmarkData: Data("video".utf8))).isEmpty)
        #expect(DisplayDetailHost.editableWebAddress(nil).isEmpty)
    }

    @Test("Switch Back offers the saved video or web page this display is not showing")
    func switchBackFollowsSavedContent() {
        var web = ScreenConfiguration(screenID: 1, wallpaper: .html(source: .inline("Test"), config: .default))
        #expect(DisplayDetailHost.switchBackTypes(web).isEmpty)
        web.savedVideoBookmarkData = Data("video".utf8)
        #expect(DisplayDetailHost.switchBackTypes(web) == [.video])

        var video = ScreenConfiguration(screenID: 1, wallpaper: .video(bookmarkData: Data("video".utf8)))
        #expect(DisplayDetailHost.switchBackTypes(video).isEmpty)
        video.savedHTMLSource = .inline("Test")
        #expect(DisplayDetailHost.switchBackTypes(video) == [.html])
        #expect(DisplayDetailHost.switchBackTypes(nil).isEmpty)
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

        /// A load attempt that already failed; `inspecting` is whether the detail shows its page.
        func failedAttempt(inspecting: Bool) -> UUID {
            let id = manager.wallpaperLoads.begin(for: screen, title: "Scene", inspecting: inspecting)
            manager.wallpaperLoads.update(id, for: screen) { $0.phase = .failed }
            return id
        }

        func close() {
            manager.tearDownForTermination()
            manager.configurationStore.remove(for: screen.id)
        }
    }
}

/// Intent and visible playback move apart here the way a policy pause moves them.
@MainActor
private final class IntentPlayback: WallpaperPlaybackControllable {
    var isPlaying: Bool
    var userIntendsToPlay: Bool
    var playCount = 0
    var pauseCount = 0

    init(isPlaying: Bool, intendsToPlay: Bool) {
        self.isPlaying = isPlaying
        userIntendsToPlay = intendsToPlay
    }

    var wallpaperType: WallpaperType {
        .video
    }

    var summary: WallpaperSessionSummary {
        .notConfigured
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
    func cleanup() {}

    func prepareForDisplay(timeout _: Duration) async -> WallpaperPreparationResult {
        .ready
    }

    func play() {
        playCount += 1
        userIntendsToPlay = true
    }

    func pause() {
        pauseCount += 1
        userIntendsToPlay = false
        isPlaying = false
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
