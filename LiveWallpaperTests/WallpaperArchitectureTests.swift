import AppKit
import Foundation
import LiveWallpaperCore
import Metal
import Testing
import WebKit
@testable import LiveWallpaper

@Suite("WallpaperSessionDefinition")
struct WallpaperSessionDefinitionTests {

    @Test("Remote HTML configuration resolves into a typed session definition")
    func remoteHTMLConfigurationResolves() {
        let url = URL(string: "https://example.com/wallpaper")!
        let configuration = ScreenConfiguration(
            screenID: 11,
            wallpaper: .html(source: .url(url), config: .default)
        )

        let definition = WallpaperSessionDefinition(configuration: configuration)

        #expect(definition == .html(.url(url), .default))
    }

    @Test("Inline HTML configuration resolves into a typed session definition")
    func inlineHTMLConfigurationResolves() {
        let html = "<html><body>Inline</body></html>"
        let configuration = ScreenConfiguration(
            screenID: 13,
            wallpaper: .html(source: .inline(html), config: .default)
        )

        let definition = WallpaperSessionDefinition(configuration: configuration)

        #expect(definition == .html(.inline(html), .default))
    }

    @Test("Empty inline HTML configuration produces no session")
    func emptyInlineHTMLProducesNoSession() {
        let configuration = ScreenConfiguration(
            screenID: 14,
            wallpaper: .html(source: .inline(""), config: .default)
        )

        #expect(WallpaperSessionDefinition(configuration: configuration) == nil)
    }

    @Test("Session definition display names come from typed content")
    func sessionDefinitionDisplayNameUsesTypedContent() {
        let definitions: [WallpaperSessionDefinition] = [
            .html(.url(URL(string: "https://example.com/live")!), .default),
            .html(.inline("<html></html>"), .default),
            .video(bookmarkData: Data([0x01, 0x02]), packageEntryName: nil),
        ]

        let displayNames = definitions.map { definition in
            definition.displayName(using: { _ in "Demo.mov" })
        }

        #expect(displayNames[0] == "example.com")
        #expect(displayNames[1] == "Inline web content")
        #expect(displayNames[2] == "Demo.mov")
    }
}

@Suite("WallpaperStatusAggregator")
struct WallpaperStatusAggregatorTests {

    @Test("HTML wallpaper counts as configured and active")
    func htmlWallpaperCountsAsActive() {
        let summaries = [
            WallpaperSessionSummary(
                wallpaperType: .html,
                activity: .active,
                supportsPlaybackControl: false,
                subtitle: "https://example.com"
            )
        ]

        let overview = WallpaperStatusAggregator.overview(for: summaries)

        #expect(overview == .active)
    }

    @Test("Paused video with no active sessions reports paused")
    func pausedVideoReportsPaused() {
        let summaries = [
            WallpaperSessionSummary(
                wallpaperType: .video,
                activity: .paused,
                supportsPlaybackControl: true,
                subtitle: "Demo.mp4"
            )
        ]

        let overview = WallpaperStatusAggregator.overview(for: summaries)

        #expect(overview == .paused)
    }

    /// A wallpaper rebuilding after a deep hibernate is coming back, not being
    /// held down; falling through to `.paused` drew the pause glyph and made
    /// VoiceOver announce a paused wallpaper mid-restore.
    @Test("A restoring session reports active, not paused")
    func restoringSessionReportsActive() {
        let summaries = [
            WallpaperSessionSummary(
                wallpaperType: .video,
                activity: .restoring,
                supportsPlaybackControl: true,
                subtitle: "Demo.mp4"
            )
        ]

        #expect(WallpaperStatusAggregator.overview(for: summaries) == .active)
    }

    @Test("No configured sessions reports not configured")
    func noConfiguredSessionsReportsNotConfigured() {
        let summaries = [WallpaperSessionSummary.notConfigured]

        let overview = WallpaperStatusAggregator.overview(for: summaries)

        #expect(overview == .notConfigured)
    }
}

@Suite("WallpaperSessionSummaryCache")
struct WallpaperSessionSummaryCacheTests {
    @Test("Cached summary wins over fallback")
    func cachedSummaryWinsOverFallback() {
        let active = WallpaperSessionSummary(
            wallpaperType: .video,
            activity: .active,
            supportsPlaybackControl: true,
            subtitle: nil
        )
        var cache = WallpaperSessionSummaryCache()

        cache.replace(with: [(42, active)])

        #expect(cache.summary(for: 42, fallback: .notConfigured) == active)
    }

    @Test("Replacing cache removes stale screen IDs")
    func replacingCacheRemovesStaleScreenIDs() {
        let paused = WallpaperSessionSummary(
            wallpaperType: .video,
            activity: .paused,
            supportsPlaybackControl: true,
            subtitle: nil
        )
        var cache = WallpaperSessionSummaryCache()

        cache.replace(with: [(1, paused)])
        cache.replace(with: [])

        #expect(cache.summary(for: 1, fallback: .notConfigured) == .notConfigured)
    }
}

@Suite("AppRuntimeOptions")
struct AppRuntimeOptionsTests {
    @Test("UI testing argument disables live wallpaper startup")
    func uiTestingArgumentDisablesLiveWallpaperStartup() {
        let options = AppRuntimeOptions(
            arguments: ["LiveWallpaper", "--ui-testing"],
            environment: [:],
            isXCTestLoaded: false
        )

        #expect(options.shouldRestoreSavedWallpapers == false)
        #expect(options.shouldStartAutomation == false)
        #expect(options.shouldShowOnboarding == false)
    }

    @Test("UI launch tests can request settings on launch without restoring wallpapers")
    func uiLaunchTestingCanOpenSettingsOnLaunch() {
        let options = AppRuntimeOptions(
            arguments: ["LiveWallpaper", "--ui-testing", "--open-settings-for-ui-testing"],
            environment: [:],
            isXCTestLoaded: false
        )
        let plan = AppStartupPlan(runtimeOptions: options, onboardingCompleted: true)

        #expect(plan.screenManagerOptions.restoreSavedWallpapers == false)
        #expect(plan.screenManagerOptions.startAutomation == false)
        #expect(plan.showOnboarding == false)
        #expect(plan.showSettingsOnLaunch == true)
    }

    @Test("UI launch tests can request settings on launch through environment")
    func uiLaunchTestingCanOpenSettingsOnLaunchThroughEnvironment() {
        let options = AppRuntimeOptions(
            arguments: ["LiveWallpaper", "--ui-testing"],
            environment: ["LIVEWALLPAPER_OPEN_SETTINGS": "1"],
            isXCTestLoaded: false
        )
        let plan = AppStartupPlan(runtimeOptions: options, onboardingCompleted: true)

        #expect(plan.showSettingsOnLaunch == true)
    }

    @Test("XCTest host environment disables live wallpaper startup")
    func xctestEnvironmentDisablesLiveWallpaperStartup() {
        let options = AppRuntimeOptions(
            arguments: ["LiveWallpaper"],
            environment: ["XCTestConfigurationFilePath": "/tmp/test.xctestconfiguration"],
            isXCTestLoaded: false
        )

        #expect(options.shouldRestoreSavedWallpapers == false)
        #expect(options.shouldStartAutomation == false)
        #expect(options.shouldShowOnboarding == false)
    }

    @Test("Test scheme environment disables live wallpaper startup")
    func testSchemeEnvironmentDisablesLiveWallpaperStartup() {
        let options = AppRuntimeOptions(
            arguments: ["LiveWallpaper"],
            environment: ["LIVEWALLPAPER_TESTING": "1"],
            isXCTestLoaded: false
        )

        #expect(options.shouldRestoreSavedWallpapers == false)
        #expect(options.shouldStartAutomation == false)
        #expect(options.shouldShowOnboarding == false)
    }

    @Test("Loaded XCTest framework disables live wallpaper startup")
    func loadedXCTestFrameworkDisablesLiveWallpaperStartup() {
        let options = AppRuntimeOptions(
            arguments: ["LiveWallpaper"],
            environment: [:],
            isXCTestLoaded: true
        )

        #expect(options.shouldRestoreSavedWallpapers == false)
        #expect(options.shouldStartAutomation == false)
        #expect(options.shouldShowOnboarding == false)
    }

    @Test("Launch startup plan relies on ScreenManager initial refresh")
    func launchStartupPlanAvoidsDuplicateScreenReloads() {
        let runtime = AppRuntimeOptions(
            arguments: ["LiveWallpaper"],
            environment: [:],
            isXCTestLoaded: false
        )

        let plan = AppStartupPlan(runtimeOptions: runtime, onboardingCompleted: true)

        #expect(plan.screenManagerOptions.restoreSavedWallpapers)
        #expect(plan.screenManagerOptions.startAutomation)
        #if LITE_BUILD
        #expect(plan.screenManagerOptions.featureCatalog.capabilities.sku == .lite)
        #expect(!plan.screenManagerOptions.featureCatalog.isEnabled(.workshopOnline))
        #else
        #expect(plan.screenManagerOptions.featureCatalog.capabilities.sku == .pro)
        #expect(plan.screenManagerOptions.featureCatalog.isEnabled(.workshopOnline))
        #endif
        #expect(plan.showOnboarding == false)
    }
}

@Suite("Application lifecycle gate")
@MainActor
struct ApplicationLifecycleControllerTests {
    @Test("Termination cancels delayed work and permanently rejects new entries")
    func terminationCancelsDelayedWork() async throws {
        let lifecycle = ApplicationLifecycleController()
        var executionCount = 0

        #expect(lifecycle.schedule(after: .seconds(60)) {
            executionCount += 1
        })
        #expect(lifecycle.pendingTaskCount == 1)

        #expect(lifecycle.beginTermination() == .begin)
        #expect(lifecycle.pendingTaskCount == 0)
        #expect(!lifecycle.allowsWork)
        #expect(!lifecycle.schedule { executionCount += 1 })

        try await Task.sleep(for: .milliseconds(20))
        #expect(executionCount == 0)
        #expect(lifecycle.beginTermination() == .wait)
        #expect(lifecycle.markReplied())
        #expect(lifecycle.beginTermination() == .terminateNow)
        #expect(!lifecycle.markReplied())
    }

    @Test("Queued work rechecks the lifecycle before entering")
    func queuedWorkRechecksLifecycle() async {
        let lifecycle = ApplicationLifecycleController()
        var executionCount = 0

        #expect(lifecycle.schedule(after: .milliseconds(50)) {
            executionCount += 1
        })
        #expect(lifecycle.beginTermination() == .begin)

        for _ in 0..<4 {
            await Task.yield()
        }
        #expect(executionCount == 0)
    }
}

@Suite("Menu bar playback controls")
@MainActor
struct MenuBarPlaybackControlTests {
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

    private func makeScreen(installing playback: FakePlaybackController) -> Screen? {
        guard let nsScreen = NSScreen.screens.first else { return nil }
        let screen = Screen(nsScreen: nsScreen)
        screen.installRuntimeSession(playback)
        return screen
    }

    @Test("Toggle pauses a playing wallpaper exactly once")
    func togglePausesPlayingWallpaperOnce() {
        let playback = FakePlaybackController(isPlaying: true)
        guard let screen = makeScreen(installing: playback) else {
            Issue.record("No NSScreen available for test")
            return
        }

        makeManager().togglePlayback(for: screen)

        #expect(!playback.isPlaying)
        #expect(playback.pauseCount == 1)
        #expect(playback.playCount == 0)
    }

    @Test("Toggle plays a paused wallpaper exactly once")
    func togglePlaysPausedWallpaperOnce() {
        let playback = FakePlaybackController(isPlaying: false)
        guard let screen = makeScreen(installing: playback) else {
            Issue.record("No NSScreen available for test")
            return
        }

        makeManager().togglePlayback(for: screen)

        #expect(playback.isPlaying)
        #expect(playback.playCount == 1)
        #expect(playback.pauseCount == 0)
    }

    /// Regression: the menu bar draws the button from `summary.activity`
    /// (actual playback) while the toggle decided direction from
    /// `userIntendsToPlay`. During a safety suspend the button says Play, the
    /// tap ran `pause()`, and the wallpaper then stayed dead after the
    /// suspend lifted because intent had been flipped to false.
    @Test("Tapping play during a policy suspend keeps intent, and playback resumes when it lifts")
    func playTapDuringPolicySuspendSurvivesAndResumes() {
        let playback = FakePlaybackController(isPlaying: true)
        guard let screen = makeScreen(installing: playback) else {
            Issue.record("No NSScreen available for test")
            return
        }

        playback.applyPerformanceProfile(.suspended)
        #expect(!playback.isPlaying, "Policy suspend should stop visible playback")
        #expect(playback.userIntendsToPlay, "Policy suspend must not touch user intent")

        // The button reads Play here, so the tap must mean play.
        makeManager().togglePlayback(for: screen)
        #expect(playback.userIntendsToPlay, "A tap on a Play-labelled button must not clear intent")
        #expect(playback.pauseCount == 0)

        playback.applyPerformanceProfile(.quality)
        #expect(playback.isPlaying, "Playback must resume once the policy suspend lifts")
    }

    /// Regression: `togglePlayback()` picked its direction globally and then
    /// applied it to every screen, so one playing wallpaper made the tap pause
    /// a policy-suspended sibling — clearing its intent and stranding it after
    /// the suspend lifted. Same failure the per-screen toggle was fixed for.
    ///
    /// Driven through the decision helpers rather than two `Screen`s: `Screen.id`
    /// comes from the panel, so two of them on one `NSScreen` collide, and
    /// requiring a second physical display would make this vacuous on CI.
    @Test("Global toggle pauses only what is actually running")
    func globalTogglePreservesIntentOnSuspendedScreens() {
        let playing = FakePlaybackController(isPlaying: true)
        let suspended = FakePlaybackController(isPlaying: false, userIntendsToPlay: true)

        #expect(
            ScreenManager.globalToggleWantsPause([playing, suspended]),
            "One genuinely playing wallpaper makes the tap mean pause"
        )
        #expect(ScreenManager.shouldPauseOnToggle(playing))
        #expect(
            !ScreenManager.shouldPauseOnToggle(suspended),
            "A screen policy already holds down must keep its intent"
        )

        // And the direction flips once nothing is really running, so the same
        // tap on an all-suspended set means play — not another intent-clearing
        // pause.
        #expect(!ScreenManager.globalToggleWantsPause([suspended]))
    }

    @Test("Toggle follows the button label: a policy-suspended wallpaper plays, it does not pause")
    func toggleFollowsButtonLabelNotIntent() {
        let playback = FakePlaybackController(isPlaying: false, userIntendsToPlay: true)
        guard let screen = makeScreen(installing: playback) else {
            Issue.record("No NSScreen available for test")
            return
        }

        makeManager().togglePlayback(for: screen)

        #expect(playback.userIntendsToPlay)
        #expect(playback.pauseCount == 0)
        #expect(playback.playCount == 1)
    }
}

@Suite("PlaylistEntry identity")
struct PlaylistEntryIdentityTests {
    @Test("Two entries with the same bookmark but different indices get distinct IDs")
    func duplicateBookmarkAtDifferentIndicesDiverge() {
        let bookmark = Data([0x01, 0x02, 0x03, 0x04])
        let first = PlaylistEntry(
            id: "\(bookmark.base64EncodedString())::0",
            bookmark: bookmark, isPrimary: true, isPlaying: false, name: "A"
        )
        let second = PlaylistEntry(
            id: "\(bookmark.base64EncodedString())::1",
            bookmark: bookmark, isPrimary: false, isPlaying: false, name: "A copy"
        )
        #expect(first.id != second.id)
    }

    @Test("Entry ID is stable across primary/playing flips at the same index")
    func entryIDStableUnderFlagFlip() {
        let bookmark = Data([0x05, 0x06])
        let id = "\(bookmark.base64EncodedString())::2"
        let before = PlaylistEntry(id: id, bookmark: bookmark, isPrimary: false, isPlaying: false, name: "X")
        let after = PlaylistEntry(id: id, bookmark: bookmark, isPrimary: true, isPlaying: true, name: "X")
        #expect(before.id == after.id)
    }
}

@Suite("WeatherReactivePolicy")
struct WeatherReactivePolicyTests {
    @Test("Weather refresh cadence is one hour")
    @MainActor
    func weatherRefreshCadenceIsHourly() {
        #expect(WeatherReactiveService.refreshInterval == .seconds(3600))
    }

    @Test("Monitor runs only when an active screen has weather-reactive effects")
    func monitorRequiresActiveWeatherReactiveConfiguration() {
        let activeID: CGDirectDisplayID = 10
        let inactiveID: CGDirectDisplayID = 20

        var activeConfig = ScreenConfiguration(screenID: activeID, videoBookmarkData: Data([0x01]))
        activeConfig.effectConfig.weatherReactive = true

        var inactiveConfig = ScreenConfiguration(screenID: inactiveID, videoBookmarkData: Data([0x02]))
        inactiveConfig.effectConfig.weatherReactive = true

        var disabledConfig = ScreenConfiguration(screenID: activeID, videoBookmarkData: Data([0x03]))
        disabledConfig.effectConfig.weatherReactive = false

        #expect(WeatherReactivePolicy.shouldMonitor(configurations: [activeConfig], activeScreenIDs: [activeID]))
        #expect(!WeatherReactivePolicy.shouldMonitor(configurations: [inactiveConfig], activeScreenIDs: [activeID]))
        #expect(!WeatherReactivePolicy.shouldMonitor(configurations: [disabledConfig], activeScreenIDs: [activeID]))
    }
}

@Suite("Monitoring reference counter")
struct MonitoringReferenceCounterTests {
    @Test("Monitoring stops only after every starter has stopped")
    func stopsAfterAllConsumersRelease() {
        var counter = MonitoringReferenceCounter()

        #expect(counter.start() == true)
        #expect(counter.start() == false)
        #expect(counter.stop() == false)
        #expect(counter.stop() == true)
        #expect(counter.stop() == false)
    }
}

@Suite("Aerial thumbnail cache key")
struct AerialThumbnailCacheKeyTests {
    @Test("Key includes path so same file names in different folders stay separate")
    func keyIncludesPath() {
        let first = aerialAsset(url: URL(fileURLWithPath: "/tmp/a/scene.mov"), fileSize: 100)
        let second = aerialAsset(url: URL(fileURLWithPath: "/tmp/b/scene.mov"), fileSize: 100)

        #expect(AerialThumbnailCacheKey(asset: first) != AerialThumbnailCacheKey(asset: second))
    }

    @Test("Key includes file size so changed files invalidate cached thumbnails")
    func keyIncludesFileSize() {
        let original = aerialAsset(url: URL(fileURLWithPath: "/tmp/a/scene.mov"), fileSize: 100)
        let changed = aerialAsset(url: URL(fileURLWithPath: "/tmp/a/scene.mov"), fileSize: 200)

        #expect(AerialThumbnailCacheKey(asset: original) != AerialThumbnailCacheKey(asset: changed))
    }

    private func aerialAsset(url: URL, fileSize: Int64) -> AerialAsset {
        AerialAsset(
            id: url.deletingPathExtension().lastPathComponent,
            url: url,
            displayName: url.lastPathComponent,
            category: nil,
            fileSize: fileSize,
            bookmarkData: Data([0x01])
        )
    }
}

@Suite("HTML wallpaper local file access")
@MainActor
struct HTMLWallpaperLocalFileAccessTests {
    @Test("Single HTML files allow WebKit to read sibling assets")
    func singleFileReadAccessUsesParentDirectory() {
        let fileURL = URL(fileURLWithPath: "/tmp/site/index.html")

        #expect(HTMLWallpaperView.readAccessRoot(forFileURL: fileURL) == fileURL.deletingLastPathComponent())
    }
}

@Suite("HTML folder URL scheme")
@MainActor
struct HTMLFolderURLSchemeTests {
    @Test("Folder scheme rejects traversal outside the granted folder")
    func rejectsTraversalOutsideGrantedFolder() throws {
        let fixture = try makeFolderFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let handler = FolderURLSchemeHandler()
        handler.folderURL = fixture.folder

        let task = CapturingURLSchemeTask(
            url: URL(string: "livewallpaper://wallpaper/%2e%2e/secret.txt")!,
            mainDocumentURL: makeTopLevelURL(handler: handler)
        )

        handler.webView(WKWebView(), start: task)

        #expect(task.failure != nil)
        #expect(task.receivedData.isEmpty)
    }

    @Test("Folder scheme rejects symlinks that resolve outside the granted folder")
    func rejectsSymlinkEscapes() throws {
        let fixture = try makeFolderFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let symlink = fixture.folder.appendingPathComponent("linked-secret.txt")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: fixture.secret)
        let handler = FolderURLSchemeHandler()
        handler.folderURL = fixture.folder

        let task = CapturingURLSchemeTask(
            url: URL(string: "livewallpaper://wallpaper/linked-secret.txt")!,
            mainDocumentURL: makeTopLevelURL(handler: handler)
        )

        handler.webView(WKWebView(), start: task)

        #expect(task.failure != nil)
        #expect(task.receivedData.isEmpty)
    }

    @Test("Folder scheme sends large assets in bounded chunks")
    func sendsLargeAssetsInBoundedChunks() async throws {
        let fixture = try makeFolderFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let largeFile = fixture.folder.appendingPathComponent("large.bin")
        let payload = Data(repeating: 0xA5, count: 200 * 1024)
        try payload.write(to: largeFile)
        let handler = FolderURLSchemeHandler()
        handler.folderURL = fixture.folder

        let task = CapturingURLSchemeTask(
            url: URL(string: "livewallpaper://wallpaper/large.bin")!,
            mainDocumentURL: makeTopLevelURL(handler: handler)
        )

        handler.webView(WKWebView(), start: task)

        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while task.didFinishCallCount == 0, task.failure == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(task.failure == nil)
        #expect(task.didFinishCallCount == 1)
        #expect(task.receivedData.count > 1)
        #expect(task.receivedData.allSatisfy { $0.count <= 64 * 1024 })
        #expect(task.receivedData.reduce(0) { $0 + $1.count } == payload.count)
    }

    private func makeTopLevelURL(handler: FolderURLSchemeHandler) -> URL {
        let nonce = handler.currentSessionNonce ?? ""
        return URL(string: "livewallpaper://wallpaper/index.html?n=\(nonce)")!
    }

    private func makeFolderFixture() throws -> (root: URL, folder: URL, secret: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveWallpaperSchemeTests-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("site", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let secret = root.appendingPathComponent("secret.txt")
        try Data("secret".utf8).write(to: secret)
        return (root, folder, secret)
    }
}

@Suite("HTML navigation policy")
struct HTMLNavigationPolicyTests {
    @Test("Same-origin comparison includes scheme host and effective port")
    func sameOriginIncludesSchemeHostAndPort() {
        let current = URL(string: "https://example.com/path")!

        #expect(HTMLWallpaperView.isSameOrigin(navigationURL: URL(string: "https://example.com/next")!, current: current))
        #expect(!HTMLWallpaperView.isSameOrigin(navigationURL: URL(string: "http://example.com/next")!, current: current))
        #expect(!HTMLWallpaperView.isSameOrigin(navigationURL: URL(string: "https://example.com:8443/next")!, current: current))
        #expect(!HTMLWallpaperView.isSameOrigin(navigationURL: URL(string: "https://other.example.com/next")!, current: current))
    }

    @Test("Only HTTP and HTTPS links may be opened externally")
    func externalOpeningIsRestrictedToHTTPAndHTTPS() {
        #expect(HTMLWallpaperView.isAllowedRemoteURL(URL(string: "https://example.com")!))
        #expect(HTMLWallpaperView.isAllowedRemoteURL(URL(string: "http://example.com")!))
        #expect(!HTMLWallpaperView.isAllowedRemoteURL(URL(string: "file:///etc/passwd")!))
        #expect(!HTMLWallpaperView.isAllowedRemoteURL(URL(string: "javascript:alert(1)")!))
        #expect(!HTMLWallpaperView.isAllowedRemoteURL(URL(string: "livewallpaper://wallpaper/index.html")!))
    }
}

@Suite("HTML wallpaper mouse interaction")
@MainActor
struct HTMLWallpaperMouseInteractionTests {
    @Test("Interactive HTML wallpapers let the host window receive mouse events")
    func interactiveHTMLWallpapersLetHostWindowReceiveMouseEvents() {
        let session = AmbientWallpaperSessionBuilder().makeHTMLSession(
            source: .inline("<html><body></body></html>"),
            config: HTMLConfig(allowMouseInteraction: true),
            frame: CGRect(x: 0, y: 0, width: 16, height: 16)
        )
        defer { session.cleanup() }

        #expect(session.wallpaperWindow?.ignoresMouseEvents == false)
        #expect((session.wallpaperWindow?.level.rawValue ?? 0) == CGWindowLevelForKey(.desktopIconWindow) + 1)
        #expect(session.wallpaperWindow?.canBecomeKey == true)
    }

    @Test("Passive HTML wallpapers keep mouse events passing through")
    func passiveHTMLWallpapersKeepMouseEventsPassingThrough() {
        let session = AmbientWallpaperSessionBuilder().makeHTMLSession(
            source: .inline("<html><body></body></html>"),
            config: HTMLConfig(allowMouseInteraction: false),
            frame: CGRect(x: 0, y: 0, width: 16, height: 16)
        )
        defer { session.cleanup() }

        #expect(session.wallpaperWindow?.ignoresMouseEvents == true)
        #expect((session.wallpaperWindow?.level.rawValue ?? 0) == CGWindowLevelForKey(.desktopWindow) - 1)
    }
}

private final class CapturingURLSchemeTask: NSObject, WKURLSchemeTask, @unchecked Sendable {
    let request: URLRequest
    private(set) var responses: [URLResponse] = []
    private(set) var receivedData: [Data] = []
    private(set) var didFinishCallCount = 0
    private(set) var failure: Error?

    init(url: URL, mainDocumentURL: URL? = nil) {
        var request = URLRequest(url: url)
        request.mainDocumentURL = mainDocumentURL
        self.request = request
    }

    func didReceive(_ response: URLResponse) {
        responses.append(response)
    }

    func didReceive(_ data: Data) {
        receivedData.append(data)
    }

    func didFinish() {
        didFinishCallCount += 1
    }

    func didFailWithError(_ error: any Error) {
        failure = error
    }
}

@Suite("WallpaperAutomationCoordinator")
@MainActor
struct WallpaperAutomationCoordinatorTests {
    @Test("Monitoring stays dormant when no screen has automation demand")
    func noDemandDoesNotCreatePeriodicTask() {
        guard let nsScreen = NSScreen.screens.first else {
            Issue.record("No NSScreen available for test")
            return
        }

        let screen = Screen(nsScreen: nsScreen)
        let coordinator = WallpaperAutomationCoordinator()

        coordinator.start(
            screenProvider: { [screen] },
            configurationProvider: { _ in nil },
            scheduleHandler: { _ in },
            playlistHandler: { _ in }
        )

        #expect(!coordinator.hasActiveTaskForTesting)
    }

    @Test("Only actionable schedule and playlist configurations create automation demand")
    func automationDemandPredicate() {
        let primary = Data([0x01])
        var configuration = ScreenConfiguration(screenID: 1, videoBookmarkData: primary)

        #expect(!WallpaperAutomationCoordinator.hasDemand(configuration))

        configuration.playlistRotationMinutes = 5
        #expect(!WallpaperAutomationCoordinator.hasDemand(configuration))

        configuration.playlistBookmarks = [Data([0x02])]
        #expect(WallpaperAutomationCoordinator.hasDemand(configuration))

        configuration.playlistRotationMinutes = 0
        #expect(!WallpaperAutomationCoordinator.hasDemand(configuration))

        configuration.wallpaperMode = .schedule
        configuration.scheduleSlots = []
        #expect(!WallpaperAutomationCoordinator.hasDemand(configuration))

        configuration.scheduleSlots = [
            ScheduleSlot(startHour: 8, endHour: 9, label: "Morning")
        ]
        #expect(!WallpaperAutomationCoordinator.hasDemand(configuration))

        configuration.scheduleSlots?[0].videoBookmarkData = Data([0x03])
        #expect(WallpaperAutomationCoordinator.hasDemand(configuration))
    }

    @Test("Active reconciliation preserves the existing task and rotation deadline")
    func activeReconciliationDoesNotRestartTask() async {
        guard let nsScreen = NSScreen.screens.first else {
            Issue.record("No NSScreen available for test")
            return
        }

        let screen = Screen(nsScreen: nsScreen)
        let ticks = AsyncStream<Date>.makeStream()
        let coordinator = WallpaperAutomationCoordinator(tickStreamFactory: { ticks.stream })
        var rotations = 0
        var configuration = ScreenConfiguration(
            screenID: screen.id,
            videoBookmarkData: Data([0x01]),
            playlistBookmarks: [Data([0x02])],
            playlistRotationMinutes: 5
        )

        func reconcile() {
            coordinator.start(
                screenProvider: { [screen] },
                configurationProvider: { _ in configuration },
                scheduleHandler: { _ in },
                playlistHandler: { _ in rotations += 1 },
                runInitialScheduleCheck: false
            )
        }

        reconcile()
        #expect(coordinator.hasActiveTaskForTesting)
        #expect(coordinator.taskStartCountForTesting == 1)

        let baseline = Date(timeIntervalSince1970: 1_000)
        ticks.continuation.yield(baseline)
        for _ in 0..<10 { await Task.yield() }

        configuration.shufflePlaylist.toggle()
        reconcile()
        #expect(coordinator.hasActiveTaskForTesting)
        #expect(coordinator.taskStartCountForTesting == 1)

        ticks.continuation.yield(baseline.addingTimeInterval(4 * 60))
        for _ in 0..<10 { await Task.yield() }
        #expect(rotations == 0)

        ticks.continuation.yield(baseline.addingTimeInterval(5 * 60))
        for _ in 0..<20 where rotations == 0 { await Task.yield() }
        #expect(rotations == 1)

        configuration.playlistRotationMinutes = nil
        reconcile()
        #expect(!coordinator.hasActiveTaskForTesting)
    }

    @Test("Schedule handler runs once when monitoring starts")
    func scheduleHandlerRunsImmediately() async throws {
        guard let nsScreen = NSScreen.screens.first else {
            Issue.record("No NSScreen available for test")
            return
        }

        let screen = Screen(nsScreen: nsScreen)
        let coordinator = WallpaperAutomationCoordinator()
        var calls = 0

        coordinator.start(
            screenProvider: { [screen] },
            configurationProvider: { _ in nil },
            scheduleHandler: { _ in calls += 1 },
            playlistHandler: { _ in }
        )

        for _ in 0..<10 where calls == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }

        coordinator.stop()

        #expect(calls == 1)
    }
}

@Suite("Wallpaper automation absence")
@MainActor
struct WallpaperAutomationAbsenceTests {
    @Test("User absence cancels suspended validation before preparation or commit")
    func absenceCancelsSuspendedValidation() async throws {
        guard let nsScreen = NSScreen.screens.first else {
            Issue.record("No NSScreen available for automation absence test")
            return
        }

        let screen = Screen(nsScreen: nsScreen)
        let targetURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("automation-absence-\(UUID().uuidString).mp4")
        try Data([0x00, 0x01]).write(to: targetURL)
        defer { try? FileManager.default.removeItem(at: targetURL) }
        let targetBookmark = try targetURL.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )

        var configuration = ScreenConfiguration(
            screenID: screen.id,
            videoBookmarkData: Data([0x01])
        )
        configuration.wallpaperMode = .playlist
        configuration.playlistBookmarks = [targetBookmark]
        configuration.playlistRotationMinutes = 1
        let persistence = AutomationTestConfigurationPersistence([configuration])
        let store = WallpaperConfigurationStore(persistence: persistence)
        _ = store.loadAll()
        let loader = FakePlayableVideoLoader(suspendsValidation: true)

        var transitionGeneration = 0
        var preparationCount = 0
        var commitCount = 0
        let orchestrator = WallpaperAutomationOrchestrator(
            configurationStore: store,
            automationCoordinator: WallpaperAutomationCoordinator(),
            playableVideoLoader: loader,
            screensProvider: { [screen] },
            saveConfiguration: { _ in },
            recordBookmarkDisplayName: { _, _ in },
            setupPreparedVideoPlayback: { _, _, _, beforeCommit in
                preparationCount += 1
                if beforeCommit() {
                    commitCount += 1
                }
            },
            restoreProposedConfiguration: { _, _ in },
            bumpTransition: { _ in
                transitionGeneration += 1
                return transitionGeneration
            },
            isCurrentTransition: { generation, _ in
                generation == transitionGeneration
            }
        )

        orchestrator.advancePlaylist(for: screen)
        for _ in 0..<50 where await loader.pendingValidationCount == 0 {
            await Task.yield()
        }
        #expect(await loader.pendingValidationCount == 1)

        orchestrator.suspendForUserAbsence()
        await loader.resumeAllValidations()
        for _ in 0..<20 {
            await Task.yield()
        }

        #expect(await loader.completedValidationCount == 0)
        #expect(preparationCount == 0)
        #expect(commitCount == 0)
        #expect(transitionGeneration == 2)
    }
}

@MainActor
private final class AutomationTestConfigurationPersistence: ScreenConfigurationPersisting {
    private var configurations: [ScreenConfiguration]

    init(_ configurations: [ScreenConfiguration]) {
        self.configurations = configurations
    }

    func getConfiguration(for screenID: CGDirectDisplayID) -> ScreenConfiguration? {
        configurations.first { $0.screenID == screenID }
    }

    func saveConfiguration(_ configuration: ScreenConfiguration) {
        configurations.removeAll { $0.screenID == configuration.screenID }
        configurations.append(configuration)
    }

    func cleanSettingsForScreen(_ screenID: CGDirectDisplayID) {
        configurations.removeAll { $0.screenID == screenID }
    }

    func loadConfigurations() -> [ScreenConfiguration] {
        configurations
    }

    func replaceAllConfigurations(_ configurations: [ScreenConfiguration]) {
        self.configurations = configurations
    }
}

@Suite("WallpaperVideoPlayer startup policy")
@MainActor
struct WallpaperVideoPlayerStartupPolicyTests {
    @Test("Pause before AVPlayer readiness suppresses ready-time autoplay")
    func pauseBeforeReadinessSuppressesAutoplay() {
        let player = WallpaperVideoPlayer(
            url: URL(fileURLWithPath: "/tmp/missing.mov"),
            frame: CGRect(x: 0, y: 0, width: 16, height: 16),
            loadImmediately: false
        )

        #expect(player.shouldAutoplayWhenReady)

        player.pause()
        #expect(!player.shouldAutoplayWhenReady)

        player.play()
        #expect(player.shouldAutoplayWhenReady)
    }

    @Test("Frame-rate limit requested before AVPlayer item exists is retained")
    func frameRateLimitBeforeItemReadinessIsRetained() {
        let player = WallpaperVideoPlayer(
            url: URL(fileURLWithPath: "/tmp/missing.mov"),
            frame: CGRect(x: 0, y: 0, width: 16, height: 16),
            loadImmediately: false
        )

        player.setFrameRateLimit(30)

        #expect(player.requestedFrameRateLimit == 30)
    }

    @Test("Existing local files without security scope are treated as media, not permission failures")
    func localFileWithoutSecurityScopeDoesNotReportAccessDenied() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveWallpaper-local-access-\(UUID().uuidString).mp4")
        try Data([0x00, 0x01, 0x02]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let player = WallpaperVideoPlayer(
            url: url,
            frame: CGRect(x: 0, y: 0, width: 16, height: 16)
        )
        defer { player.cleanup() }

        if case .fileAccessDenied(url) = player.runtimeError {
            Issue.record("Existing app-owned video copies should continue to media validation, not fail as sandbox-denied: \(url.path)")
        }
    }

    @Test("Pause does not depend on AVPlayer already being in the playing state")
    func pauseIsNotGatedOnPlayingTimeControlStatus() throws {
        let source = try Self.readSourceFile("LiveWallpaper/VideoPlayback/WallpaperVideoPlayer.swift")

        #expect(!source.contains("timeControlStatus == .playing else { return }"))
    }

    @Test("Wallpaper playback does not keep the display awake")
    func wallpaperPlaybackDisablesDisplaySleepPrevention() throws {
        let source = try Self.readSourceFile("LiveWallpaper/VideoPlayback/WallpaperVideoPlayer.swift")

        #expect(source.contains("preventsDisplaySleepDuringVideoPlayback = false"))
    }

    @Test("Video preview surfaces controller errors in the preview UI")
    func videoPreviewSurfacesControllerErrors() throws {
        let source = try Self.readSourceFile("LiveWallpaper/Views/ScreenDetail/VideoPreviewSection.swift")

        #expect(source.contains("previewController.lastError"))
    }

    @Test("Scene preview does not synchronously render a live poster on MainActor")
    func scenePreviewUsesNextFramePosterCapture() throws {
        let source = try Self.readSourceFile("LiveWallpaper/Views/ScreenDetail/SceneDetailView.swift")

        #expect(source.contains("captureLivePosterFromNextFrame"))
        #expect(!source.contains("renderer.captureLivePoster()"))
    }

    @Test("Scene preview poster readback waits for present completion without synchronizing draw")
    func scenePreviewPosterReadbackUsesPresentCompletion() throws {
        let source = try Self.readSceneRendererSource()
        let executor = try Self.readExecutorSource()

        #expect(source.contains("capturePendingLivePostersAfterPresent"))
        #expect(source.contains("presentCompletion:"))
        #expect(executor.contains("presentCompletion: (@Sendable (MTLTexture, MTLCommandBuffer, @escaping @Sendable () -> Void) -> Void)? = nil"))
        #expect(executor.contains("presentCompletion(completionSource.texture, cb, releaseSource)"))
        #expect(source.contains("releaseSource:"))
        #expect(!source.contains("withSynchronizedLivePosterFrameIfNeeded"))
    }

    @Test("Puppet bound-scan cache stores successful nil checks")
    func puppetBoundScanCacheStoresSuccessfulNilChecks() throws {
        let executor = try Self.readExecutorSource()

        #expect(executor.contains("struct PuppetBoundScanCacheEntry"))
        #expect(executor.contains("puppetBoundScanDetailByObjectID[objectID] = PuppetBoundScanCacheEntry"))
        #expect(!executor.contains("private var puppetBoundScanDetailByObjectID: [String: String?]"))
    }

    @Test("Scene detail fallback preview is a bounded static poster and releases ImageIO state")
    func sceneDetailPreviewFallbackDoesNotRetainAnimatedPreviewState() throws {
        let detail = try Self.readSourceFile("LiveWallpaper/Views/ScreenDetail/SceneDetailView.swift")
        let preview = try Self.readSourceFile("LiveWallpaper/Views/ScreenDetail/ScenePreview.swift")

        #expect(preview.contains("case staticPoster"))
        #expect(detail.contains("playbackMode: .staticPoster"))
        #expect(preview.contains("static func dismantleNSView"))
        #expect(preview.contains("context.coordinator.cancelInflight()"))
        #expect(preview.contains("nsView.clearImage()"))
        #expect(preview.contains("WPEPreviewImageDecodeBudget"))
        #expect(preview.contains("kCGImageSourceShouldCache"))
    }

    @Test("Scene preview keeps abnormal poster ratios inside the screen frame")
    func scenePreviewFitsAbnormalPosterRatiosInsideScreenFrame() throws {
        let detail = try Self.readSourceFile("LiveWallpaper/Views/ScreenDetail/SceneDetailView.swift")

        #expect(detail.contains("GeometryReader"))
        #expect(detail.contains("screenPreviewSize"))
        #expect(detail.contains(".aspectRatio(contentMode: .fit)"))
        #expect(!detail.contains(".aspectRatio(contentMode: .fill)"))
    }

    @Test("Scene preview polling is lifecycle-owned and stops at terminal state")
    func scenePreviewDoesNotOwnPermanentTimer() throws {
        let detail = try Self.readSourceFile(
            "LiveWallpaper/Views/ScreenDetail/SceneDetailView.swift"
        )

        #expect(detail.contains(".task(id: previewTaskIdentity)"))
        #expect(detail.contains("await pollPreviewUntilSettled("))
        #expect(detail.contains("next.needsPreviewPolling"))
        #expect(detail.contains("Task.sleep(for: .milliseconds(400))"))
        #expect(detail.contains("previewLifecycle.invalidate()"))
        #expect(!detail.contains("Timer.publish"))
        #expect(!detail.contains(".onReceive("))
    }

    @Test("Scene diagnostic inventory is not owned by the SwiftUI view")
    func sceneDiagnosticsAreSeparatedFromPreviewLifecycle() throws {
        let detail = try Self.readSourceFile(
            "LiveWallpaper/Views/ScreenDetail/SceneDetailView.swift"
        )
        let report = try Self.readSourceFile(
            "LiveWallpaper/Runtime/Diagnostics/WPERenderDiagnosticReport.swift"
        )

        #expect(detail.contains("WPERenderDiagnosticReport.make("))
        #expect(!detail.contains("import Metal"))
        #expect(!detail.contains("renderFlagKeys"))
        #expect(!detail.contains("MTLCreateSystemDefaultDevice"))
        #expect(!detail.contains("UserDefaults.standard"))
        #expect(report.contains("enum WPERenderDiagnosticReport"))
        #expect(report.contains("enum WPERenderDiagnosticEnvironment"))
        #expect(report.contains("renderFlagKeys"))
        #expect(report.contains("MTLCreateSystemDefaultDevice"))
    }

    private static func readSourceFile(_ relativePath: String) throws -> String {
        try RepositoryRoot.source(relativePath)
    }

    private static func readExecutorSource() throws -> String {
        try RepositoryRoot.componentSource(under: "LiveWallpaper/Runtime", namePrefix: "WPEMetalRenderExecutor")
    }

    private static func readSceneRendererSource() throws -> String {
        try RepositoryRoot.componentSource(under: "LiveWallpaper/Runtime", namePrefix: "WPEMetalSceneRenderer")
    }
}

@Suite("Monitoring cadence policy")
struct MonitoringCadencePolicyTests {
    @Test("GPU sampling runs immediately then at configured cadence")
    func gpuSamplingCadence() {
        #expect(MonitoringCadencePolicy.shouldSampleGPU(updateCount: 1, cadence: 3))
        #expect(!MonitoringCadencePolicy.shouldSampleGPU(updateCount: 2, cadence: 3))
        #expect(MonitoringCadencePolicy.shouldSampleGPU(updateCount: 3, cadence: 3))
        #expect(!MonitoringCadencePolicy.shouldSampleGPU(updateCount: 4, cadence: 3))
        #expect(MonitoringCadencePolicy.shouldSampleGPU(updateCount: 6, cadence: 3))
    }

    @Test("Cadence below two samples every update")
    func lowCadenceSamplesEveryUpdate() {
        #expect(MonitoringCadencePolicy.shouldSampleGPU(updateCount: 4, cadence: 1))
        #expect(MonitoringCadencePolicy.shouldSampleGPU(updateCount: 4, cadence: 0))
    }
}

@Suite("Monitoring start policy")
struct MonitoringStartPolicyTests {
    @Test("Initial resource sample is deferred past sidebar expansion animation")
    func initialResourceSampleIsDeferredPastSidebarExpansionAnimation() {
        #expect(MonitoringStartPolicy.initialSampleDelay == .milliseconds(350))
    }
}

@Suite("Wallpaper runtime readiness")
@MainActor
struct WallpaperRuntimeReadinessTests {
    @Test("Preparation reports cancellation instead of fixed-delay success")
    func preparationCancellation() async {
        let session = FakePlaybackController(isPlaying: false)
        let task = Task { @MainActor in
            await session.prepareForDisplay(timeout: .milliseconds(200))
        }

        task.cancel()
        let prepared = await task.value

        #expect(prepared == .cancelled)
    }

    @Test("Preparation timeout is independent of a suspended probe")
    func preparationHasHardDeadline() async {
        let prepared = await WallpaperPreparationWaiter.wait(
            timeout: .milliseconds(30)
        ) {
            try? await Task.sleep(for: .seconds(10))
            return nil
        }

        #expect(prepared == .timedOut)
    }
}

@MainActor
private final class FakePlaybackController: WallpaperPlaybackControllable {
    var isPlaying: Bool
    private(set) var userIntendsToPlay: Bool
    var playCount = 0
    var pauseCount = 0

    /// Mirrors the real three-layer fold: visible playback is
    /// `userIntendsToPlay && policy == .quality`. Without it a fake `play()`
    /// reports success while policy still has the session pinned down, and no
    /// test can express "tapped play while suspended".
    private var policyAllowsPlayback: Bool

    init(isPlaying: Bool, userIntendsToPlay: Bool? = nil, policyAllowsPlayback: Bool? = nil) {
        self.isPlaying = isPlaying
        self.userIntendsToPlay = userIntendsToPlay ?? isPlaying
        // Default: policy is not suppressing. `isPlaying: false` alone means the
        // USER paused; only an explicit intends-to-play-but-not-playing pair
        // describes a policy suspend.
        self.policyAllowsPlayback = policyAllowsPlayback ?? (isPlaying || !(userIntendsToPlay ?? isPlaying))
    }

    var wallpaperType: WallpaperType { .video }
    /// Mirrors `VideoWallpaperSession`'s own three-way: wanting to play without
    /// playing is policy holding it down, never a user pause. Reporting
    /// `.notConfigured` here made `hasControllableWallpaperSessions` false, so
    /// the global toggle returned before doing anything and any test of it
    /// passed vacuously.
    var summary: WallpaperSessionSummary {
        WallpaperSessionSummary(
            wallpaperType: .video,
            activity: isPlaying ? .active : (userIntendsToPlay ? .policySuspended : .paused),
            supportsPlaybackControl: true,
            subtitle: "Fake"
        )
    }
    var videoPlayer: WallpaperVideoPlayer? { nil }
    var wallpaperWindow: NSWindow? { nil }

    func show() {}
    func applyPerformanceProfile(_ profile: WallpaperPerformanceProfile) {
        policyAllowsPlayback = profile == .quality
        isPlaying = userIntendsToPlay && policyAllowsPlayback
    }
    func updateFrame(to frame: CGRect) {}
    func cleanup() {}

    func prepareForDisplay(timeout: Duration) async -> WallpaperPreparationResult {
        await WallpaperPreparationWaiter.wait(timeout: timeout) { nil }
    }

    func play() {
        playCount += 1
        userIntendsToPlay = true
        isPlaying = policyAllowsPlayback
    }

    func pause() {
        pauseCount += 1
        userIntendsToPlay = false
        isPlaying = false
    }
}

@Suite("WallpaperConfigurationStore removing invalid resource configurations")
struct WallpaperConfigurationStoreInvalidConfigTests {

    @Test("Invalid local HTML configurations are removed while scene wallpapers survive")
    func invalidLocalHTMLConfigurationsAreRemoved() {
        let configs = [
            ScreenConfiguration(screenID: 1, videoBookmarkData: Data([0x01])),
            ScreenConfiguration(
                screenID: 2,
                wallpaper: .html(source: .file(bookmarkData: Data([0x02])), config: .default)
            ),
            ScreenConfiguration(screenID: 3, wallpaper: .scene(SceneDescriptor(
                workshopID: "3",
                cacheRelativePath: "wpe-cache/3",
                entryFile: "scene.json",
                capabilityTier: .degraded
            ))),
        ]

        let pruned = WallpaperConfigurationStore.removingInvalidResourceConfigurations(
            from: configs,
            invalidScreenIDs: [1, 2, 3]
        )

        #expect(pruned.count == 1)
        #expect(pruned.first?.screenID == 3)
        #expect(pruned.first?.wallpaperType == .scene)
    }
}

@Suite("WallpaperPolicyEngine")
struct WallpaperPolicyEngineTests {

    @Test("On battery without pause-on-battery: profile stays quality; no pause requested")
    func batteryStaticProfile() {
        let settings = GlobalSettings(globalPauseOnBattery: false)

        let profile = WallpaperPolicyEngine.performanceProfile(
            inputs: .test(powerSource: .battery(level: 80)),
            settings: settings
        )

        #expect(profile == .quality)
        #expect(!WallpaperPolicyEngine.shouldPauseForPower(
            globalSettings: settings,
            powerSource: .battery(level: 80)
        ))
    }

    @Test("Fullscreen hidden screen maps to suspended profile")
    func fullScreenSuspendedProfile() {
        let settings = GlobalSettings(pauseOnFullScreen: true)

        let profile = WallpaperPolicyEngine.performanceProfile(
            inputs: .test(isHiddenByFullScreen: true),
            settings: settings
        )

        #expect(profile == .suspended)
        #expect(WallpaperPolicyEngine.shouldApplyFullScreenPolicy(
            globalSettings: settings,
            isHiddenByFullScreen: true
        ))
    }

    @Test("User absence (lock / display-sleep / system-sleep) maps to suspended profile")
    func userAbsentSuspendedProfile() {
        let settings = GlobalSettings()

        let active = WallpaperPolicyEngine.performanceProfile(
            inputs: .test(isUserAbsent: false),
            settings: settings
        )
        let absent = WallpaperPolicyEngine.performanceProfile(
            inputs: .test(isUserAbsent: true),
            settings: settings
        )

        #expect(active == .quality)
        #expect(absent == .suspended)
    }

    @Test("Every suspend condition independently maps to suspended; all-benign stays quality")
    func unifiedSuspendConditionMatrix() {
        func profile(
            hidden: Bool = false,
            occluding: Bool = false,
            appRule: Bool = false,
            thermal: ProcessInfo.ThermalState = .nominal,
            powerSource: PowerMonitor.PowerSource = .external,
            userAbsent: Bool = false,
            memoryPressure: Bool = false
        ) -> WallpaperPerformanceProfile {
            WallpaperPolicyEngine.performanceProfile(
                inputs: .test(
                    powerSource: powerSource,
                    isHiddenByFullScreen: hidden,
                    isWindowOccluding: occluding,
                    isApplicationRuleActive: appRule,
                    thermalState: thermal,
                    isUserAbsent: userAbsent,
                    memoryPressureLevel: memoryPressure ? .critical : .normal
                ),
                settings: GlobalSettings(
                    globalPauseOnBattery: true,
                    pauseOnFullScreen: true,
                    pauseOnWindowOcclusion: true
                )
            )
        }

        #expect(profile() == .quality)
        #expect(profile(hidden: true) == .suspended)
        #expect(profile(occluding: true) == .suspended)
        #expect(profile(appRule: true) == .suspended)
        // `.serious` sheds load instead of stopping; only `.critical` suspends.
        #expect(profile(thermal: .serious) == .quality)
        #expect(profile(thermal: .critical) == .suspended)
        #expect(profile(powerSource: .battery(level: 50)) == .suspended)
        #expect(profile(userAbsent: true) == .suspended)
        #expect(profile(memoryPressure: true) == .suspended)
    }

    @Test("Global pause on battery pauses video playback")
    func globalPauseOnBatteryDecision() {
        let settings = GlobalSettings(globalPauseOnBattery: true)

        #expect(WallpaperPolicyEngine.shouldPauseForPower(
            globalSettings: settings,
            powerSource: .battery(level: 90)
        ))
    }

    @Test("Fullscreen fallback polling only runs when fullscreen policy can affect sessions")
    func fullScreenFallbackPollingDecision() {
        #expect(WallpaperPolicyEngine.shouldEnableFullScreenFallbackPolling(
            globalSettings: GlobalSettings(pauseOnFullScreen: true),
            hasConfiguredWallpaperSessions: true,
            hasConfiguredSceneSessions: false
        ))
        #expect(WallpaperPolicyEngine.shouldEnableFullScreenFallbackPolling(
            globalSettings: GlobalSettings(pauseOnFullScreen: false),
            hasConfiguredWallpaperSessions: true,
            hasConfiguredSceneSessions: false
        ))
        #expect(!WallpaperPolicyEngine.shouldEnableFullScreenFallbackPolling(
            globalSettings: GlobalSettings(pauseOnFullScreen: false, pauseOnWindowOcclusion: false),
            hasConfiguredWallpaperSessions: true,
            hasConfiguredSceneSessions: false
        ))
        #expect(!WallpaperPolicyEngine.shouldEnableFullScreenFallbackPolling(
            globalSettings: GlobalSettings(pauseOnFullScreen: true),
            hasConfiguredWallpaperSessions: false,
            hasConfiguredSceneSessions: false
        ))
        #expect(WallpaperPolicyEngine.shouldEnableFullScreenFallbackPolling(
            globalSettings: GlobalSettings(pauseOnFullScreen: false, adaptiveFrameRateEnabled: true),
            hasConfiguredWallpaperSessions: true,
            hasConfiguredSceneSessions: true
        ))
        #expect(!WallpaperPolicyEngine.shouldEnableFullScreenFallbackPolling(
            globalSettings: GlobalSettings(pauseOnFullScreen: false, pauseOnWindowOcclusion: false, adaptiveFrameRateEnabled: true),
            hasConfiguredWallpaperSessions: true,
            hasConfiguredSceneSessions: false
        ))
    }
}

@Suite("FullScreenDetector adaptive polling")
@MainActor
struct FullScreenDetectorAdaptivePollingTests {

    @Test("Detector starts notification-only and toggles fallback polling explicitly")
    func fallbackPollingTogglesExplicitly() {
        let detector = FullScreenDetector(pollInterval: 60)

        #expect(!detector.isFallbackPollingEnabled)

        detector.setFallbackPollingEnabled(true)
        #expect(detector.isFallbackPollingEnabled)

        detector.setFallbackPollingEnabled(true)
        #expect(detector.isFallbackPollingEnabled)

        detector.setFallbackPollingEnabled(false)
        #expect(!detector.isFallbackPollingEnabled)

        detector.stop()
    }
}

@Suite("PlaylistPolicy")
struct PlaylistPolicyTests {

    @Test("Sequential cursor advances 0 → 1 → 2 → 0")
    func sequentialCursorAdvances() {
        let count = 3

        let step1 = PlaylistPolicy.nextCursor(currentCursor: 0, playlistCount: count, shuffle: false)
        let step2 = PlaylistPolicy.nextCursor(currentCursor: 1, playlistCount: count, shuffle: false)
        let step3 = PlaylistPolicy.nextCursor(currentCursor: 2, playlistCount: count, shuffle: false)

        #expect(step1 == 1)
        #expect(step2 == 2)
        #expect(step3 == 0)
    }

    @Test("Playlist with fewer than two entries does not rotate")
    func tooFewEntriesDoesNotRotate() {
        #expect(PlaylistPolicy.nextCursor(currentCursor: 0, playlistCount: 1, shuffle: false) == nil)
        #expect(PlaylistPolicy.nextCursor(currentCursor: 0, playlistCount: 0, shuffle: true) == nil)
    }

    @Test("Shuffle excludes the currently playing cursor")
    func shuffleExcludesCurrentCursor() {
        let next = PlaylistPolicy.nextCursor(
            currentCursor: 2,
            playlistCount: 4,
            shuffle: true,
            randomIndex: { _ in 2 }
        )

        #expect(next != 2)
        #expect(next != nil)
    }

    @Test("Stale cursor (past end) normalizes before advancing")
    func staleCursorNormalizes() {
        let next = PlaylistPolicy.nextCursor(currentCursor: 7, playlistCount: 3, shuffle: false)
        #expect(next == 2)
    }

    @Test("Playlist rotation waits until configured interval elapses")
    func playlistRotationInterval() {
        let lastRotation = Date(timeIntervalSince1970: 100)

        #expect(!PlaylistPolicy.shouldRotate(
            now: Date(timeIntervalSince1970: 159),
            lastRotation: lastRotation,
            rotationMinutes: 1
        ))
        #expect(PlaylistPolicy.shouldRotate(
            now: Date(timeIntervalSince1970: 160),
            lastRotation: lastRotation,
            rotationMinutes: 1
        ))
    }

    @Test("Sequential previousCursor decrements 2 → 1 → 0 → 2")
    func sequentialPreviousCursorDecrements() {
        #expect(PlaylistPolicy.previousCursor(currentCursor: 2, playlistCount: 3, shuffle: false) == 1)
        #expect(PlaylistPolicy.previousCursor(currentCursor: 1, playlistCount: 3, shuffle: false) == 0)
        #expect(PlaylistPolicy.previousCursor(currentCursor: 0, playlistCount: 3, shuffle: false) == 2)
    }

    @Test("Previous with fewer than two entries does not rotate")
    func previousTooFewEntries() {
        #expect(PlaylistPolicy.previousCursor(currentCursor: 0, playlistCount: 1, shuffle: false) == nil)
        #expect(PlaylistPolicy.previousCursor(currentCursor: 0, playlistCount: 0, shuffle: false) == nil)
    }

    @Test("Shuffle previous excludes the current cursor")
    func shufflePreviousExcludesCurrent() {
        let result = PlaylistPolicy.previousCursor(
            currentCursor: 2,
            playlistCount: 4,
            shuffle: true,
            randomIndex: { _ in 2 }
        )
        #expect(result != nil && result != 2)
    }

    @Test("Stale previousCursor (past end) normalizes before stepping back")
    func stalePreviousCursorNormalizes() {
        #expect(PlaylistPolicy.previousCursor(currentCursor: 7, playlistCount: 3, shuffle: false) == 0)
    }

    // MARK: - resolveCursor (used by ScreenManager.replacePlaylist after reorder)

    @Test("resolveCursor: active bookmark found at its new index")
    func resolveCursorFound() {
        let primary = Data([0x01])
        let extra1 = Data([0x02])
        let extra2 = Data([0x03])
        let combined = [extra1, primary, extra2]
        #expect(PlaylistPolicy.resolveCursor(activeBookmark: primary, in: combined) == 1)
    }

    @Test("resolveCursor: active bookmark removed from list → falls back to 0")
    func resolveCursorRemovedFallsBackToPrimary() {
        let primary = Data([0x01])
        let extra = Data([0x02])
        let removed = Data([0x99])
        let combined = [primary, extra]
        #expect(PlaylistPolicy.resolveCursor(activeBookmark: removed, in: combined) == 0)
    }

    @Test("resolveCursor: nil active → 0")
    func resolveCursorNilActive() {
        let combined = [Data([0x01]), Data([0x02])]
        #expect(PlaylistPolicy.resolveCursor(activeBookmark: nil, in: combined) == 0)
    }

    @Test("resolveCursor: empty combined → 0")
    func resolveCursorEmptyCombined() {
        #expect(PlaylistPolicy.resolveCursor(activeBookmark: Data([0x01]), in: []) == 0)
    }
}

// MARK: - ScreenConfiguration rotation / schedule / replace-primary integration

@Suite("ScreenConfiguration playlist + schedule helpers")
struct ScreenConfigurationHelpersTests {

    @Test("replacePrimaryVideo preserves effects/playlist/schedule")
    func replacePrimaryVideoPreservesSettings() {
        var effects = VideoEffectConfig.default
        effects.saturation = 0.7
        let oldBookmark = Data([0x01])
        let newBookmark = Data([0x99])

        var config = ScreenConfiguration(
            screenID: 1,
            videoBookmarkData: oldBookmark,
            particleEffect: .snow,
            effectConfig: effects,
            scheduleSlots: ScheduleSlot.defaultSlots,
            playlistBookmarks: [Data([0x02]), Data([0x03])],
            shufflePlaylist: true,
            playlistRotationMinutes: 15,
            playlistCursorIndex: 2
        )

        config.replacePrimaryVideo(bookmarkData: newBookmark)

        #expect(config.savedVideoBookmarkData == newBookmark)
        #expect(config.activeWallpaper == .video(bookmarkData: newBookmark))
        #expect(config.playlistCursorIndex == 0)
        #expect(config.particleEffect == .snow)
        #expect(config.effectConfig.saturation == 0.7)
        #expect(config.scheduleSlots?.count == ScheduleSlot.defaultSlots.count)
        #expect(config.playlistBookmarks == [Data([0x02]), Data([0x03])])
        #expect(config.shufflePlaylist == true)
        #expect(config.playlistRotationMinutes == 15)
    }

    @Test("applyScheduledBookmark preserves savedVideoBookmarkData (primary)")
    func applyScheduledBookmarkPreservesPrimary() {
        let primary = Data([0x01])
        let scheduled = Data([0xAA])

        var config = ScreenConfiguration(
            screenID: 2,
            videoBookmarkData: primary,
            particleEffect: .rain,
            effectConfig: .default,
            playlistBookmarks: [Data([0xBB])],
            playlistCursorIndex: 1
        )

        config.applyScheduledBookmark(scheduled)

        #expect(config.activeWallpaper == .video(bookmarkData: scheduled))
        #expect(config.savedVideoBookmarkData == primary, "primary survives schedule")
        #expect(config.playlistCursorIndex == 1, "cursor survives schedule")
        #expect(config.particleEffect == .rain)
        #expect(config.playlistBookmarks == [Data([0xBB])])
    }

    @Test("withUpdatedActiveBookmark refreshes primary when cursor=0")
    func withUpdatedActiveBookmarkAtPrimary() {
        let config = ScreenConfiguration(
            screenID: 3,
            videoBookmarkData: Data([0x01]),
            playlistBookmarks: [Data([0x02])],
            playlistCursorIndex: 0
        )
        let refreshed = Data([0xFE])
        let updated = config.withUpdatedActiveBookmark(refreshed)
        #expect(updated.savedVideoBookmarkData == refreshed)
        #expect(updated.activeWallpaper == .video(bookmarkData: refreshed))
        #expect(updated.playlistBookmarks == [Data([0x02])])
    }

    @Test("withUpdatedActiveBookmark refreshes the playlist slot it matches and leaves primary alone")
    func withUpdatedActiveBookmarkAtPlaylistSlot() {
        let primary = Data([0x01])
        let playlistEntry = Data([0x03])
        var config = ScreenConfiguration(
            screenID: 4,
            videoBookmarkData: primary,
            playlistBookmarks: [Data([0x02]), playlistEntry],
            playlistCursorIndex: 2
        )
        config.activeWallpaper = .video(bookmarkData: playlistEntry)

        let refreshed = Data([0xFE])
        let updated = config.withUpdatedActiveBookmark(refreshed)

        #expect(updated.savedVideoBookmarkData == primary, "primary must not be clobbered")
        #expect(updated.activeWallpaper == .video(bookmarkData: refreshed))
        #expect(updated.playlistBookmarks == [Data([0x02]), refreshed])
    }

    @Test("withUpdatedActiveBookmark refreshes the schedule slot it matches and leaves primary alone")
    func withUpdatedActiveBookmarkAtScheduleSlot() {
        let primary = Data([0x01])
        let scheduledBookmark = Data([0xAA])
        var config = ScreenConfiguration(
            screenID: 5,
            videoBookmarkData: primary,
            scheduleSlots: [
                ScheduleSlot(startHour: 6, endHour: 12, videoBookmarkData: scheduledBookmark, label: "Morning")
            ]
        )
        config.activeWallpaper = .video(bookmarkData: scheduledBookmark)

        let refreshed = Data([0xFE])
        let updated = config.withUpdatedActiveBookmark(refreshed)

        #expect(updated.savedVideoBookmarkData == primary, "primary must not be clobbered by stale schedule refresh")
        #expect(updated.activeWallpaper == .video(bookmarkData: refreshed))
        #expect(updated.scheduleSlots?.first?.videoBookmarkData == refreshed)
    }

    @Test("playlistCursorIndex survives Codable round-trip")
    func playlistCursorIndexRoundTrip() throws {
        let original = ScreenConfiguration(
            screenID: 5,
            videoBookmarkData: Data([0x01]),
            playlistBookmarks: [Data([0x02])],
            playlistCursorIndex: 1
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ScreenConfiguration.self, from: data)
        #expect(decoded.playlistCursorIndex == 1)
    }

    @Test("activateSavedVideoWallpaper resets cursor to 0")
    func activateSavedVideoResetsCursor() {
        let primary = Data([0x01])
        var config = ScreenConfiguration(
            screenID: 6,
            videoBookmarkData: primary,
            playlistBookmarks: [Data([0x02])],
            playlistCursorIndex: 1
        )
        config.setHTMLWallpaper(source: .url(URL(string: "https://example.com")!))
        _ = config.activateSavedVideoWallpaper()
        #expect(config.playlistCursorIndex == 0)
        #expect(config.activeWallpaper == .video(bookmarkData: primary))
    }

    @Test("switching to ambient wallpaper while scheduled keeps primary bookmark")
    func ambientSwitchPreservesPrimaryDuringSchedule() {
        let primary = Data([0x01])
        let scheduled = Data([0xAA])
        var config = ScreenConfiguration(screenID: 7, videoBookmarkData: primary)

        config.applyScheduledBookmark(scheduled)
        config.setHTMLWallpaper(source: .inline("<p>ambient</p>"))

        #expect(config.savedVideoBookmarkData == primary)
        #expect(config.videoBookmarkData == primary)
    }

    @Test("activateSavedVideoWallpaper prefers saved primary over active scheduled video")
    func activateSavedVideoUsesPrimary() {
        let primary = Data([0x01])
        let scheduled = Data([0xAA])
        var config = ScreenConfiguration(screenID: 8, videoBookmarkData: primary)

        config.applyScheduledBookmark(scheduled)
        let restored = config.activateSavedVideoWallpaper()

        #expect(restored)
        #expect(config.activeWallpaper == .video(bookmarkData: primary))
        #expect(config.savedVideoBookmarkData == primary)
    }
}

@Suite("SchedulePolicy")
struct SchedulePolicyTests {

    @Test("Schedule policy returns active slot bookmark")
    func schedulePolicyReturnsBookmark() {
        let current = Data([0x01])
        let scheduled = Data([0x02])
        let slot = ScheduleSlot(startHour: 6, endHour: 12, videoBookmarkData: scheduled, label: "Morning")
        var configuration = ScreenConfiguration(
            screenID: 41,
            videoBookmarkData: current,
            scheduleSlots: [slot]
        )
        configuration.wallpaperMode = .schedule

        let result = SchedulePolicy.decision(for: configuration, hour: 8)

        #expect(result == .applySlot(slot: slot, bookmarkData: scheduled))
    }

    @Test("Schedule policy skips already active bookmark")
    func schedulePolicySkipsAlreadyActiveBookmark() {
        let bookmark = Data([0x01])
        var configuration = ScreenConfiguration(
            screenID: 42,
            videoBookmarkData: bookmark,
            scheduleSlots: [
                ScheduleSlot(startHour: 6, endHour: 12, videoBookmarkData: bookmark, label: "Morning")
            ]
        )
        configuration.wallpaperMode = .schedule

        let result = SchedulePolicy.decision(for: configuration, hour: 8)

        #expect(result == .none)
    }

    @Test("Schedule policy applies a primary slot when current wallpaper is not video")
    func schedulePolicyAppliesPrimarySlotOverHTML() {
        let primary = Data([0x01])
        let slot = ScheduleSlot(startHour: 6, endHour: 12, videoBookmarkData: primary, label: "Morning")
        var configuration = ScreenConfiguration(
            screenID: 43,
            wallpaper: .html(source: .url(URL(string: "https://example.com")!), config: .default),
            scheduleSlots: [slot],
            savedVideoBookmarkData: primary
        )
        configuration.wallpaperMode = .schedule

        let result = SchedulePolicy.decision(for: configuration, hour: 8)

        #expect(result == .applySlot(slot: slot, bookmarkData: primary))
    }

    // MARK: - decision mode-gate

    @Test("decision returns .none when wallpaperMode != .schedule even with active slot")
    func decisionGatedByMode() {
        let primary = Data([0x01])
        let scheduled = Data([0x02])
        var configuration = ScreenConfiguration(
            screenID: 50,
            videoBookmarkData: primary,
            scheduleSlots: [
                ScheduleSlot(startHour: 6, endHour: 12, videoBookmarkData: scheduled, label: "Morning")
            ]
        )

        configuration.wallpaperMode = .playlist
        #expect(SchedulePolicy.decision(for: configuration, hour: 8) == .none)
    }

    // MARK: - hourRanges

    @Test("hourRanges: normal slot produces a single range")
    func hourRangesNormal() {
        let slot = ScheduleSlot(startHour: 6, endHour: 12, label: "Morning")
        let ranges = SchedulePolicy.hourRanges(for: slot)
        #expect(ranges == [6..<12])
    }

    @Test("hourRanges: midnight wrap produces two ranges")
    func hourRangesMidnightWrap() {
        let slot = ScheduleSlot(startHour: 22, endHour: 6, label: "Night")
        let ranges = SchedulePolicy.hourRanges(for: slot)
        #expect(ranges == [22..<24, 0..<6])
    }

    @Test("hourRanges: zero-length slot returns empty")
    func hourRangesZeroLength() {
        let slot = ScheduleSlot(startHour: 8, endHour: 8, label: "Empty")
        #expect(SchedulePolicy.hourRanges(for: slot).isEmpty)
    }

    // MARK: - conflicts

    @Test("conflicts: overlapping normal slots are detected")
    func conflictsOverlap() {
        let slotA = ScheduleSlot(startHour: 6, endHour: 12, label: "Morning")
        let slotB = ScheduleSlot(startHour: 10, endHour: 14, label: "Late Morning")
        #expect(SchedulePolicy.conflicts(slot: slotA, against: [slotB]) == Set([slotB.id]))
    }

    @Test("conflicts: adjacent slots do not conflict")
    func conflictsAdjacent() {
        let slotA = ScheduleSlot(startHour: 6, endHour: 12, label: "A")
        let slotB = ScheduleSlot(startHour: 12, endHour: 18, label: "B")
        #expect(SchedulePolicy.conflicts(slot: slotA, against: [slotB]).isEmpty)
    }

    @Test("conflicts: midnight-wrap slot overlaps an early-morning slot")
    func conflictsMidnightWrap() {
        let night = ScheduleSlot(startHour: 22, endHour: 6, label: "Night")
        let morning = ScheduleSlot(startHour: 4, endHour: 9, label: "Morning")
        #expect(SchedulePolicy.conflicts(slot: night, against: [morning]) == Set([morning.id]))
    }

    @Test("conflicts: empty slot conflicts with nobody")
    func conflictsEmptySlot() {
        let empty = ScheduleSlot(startHour: 8, endHour: 8, label: "Empty")
        let other = ScheduleSlot(startHour: 0, endHour: 24, label: "Wrap-disguise")
        #expect(SchedulePolicy.conflicts(slot: empty, against: [other]).isEmpty)
    }

    // MARK: - findFreeRange

    @Test("findFreeRange: returns longest contiguous gap")
    func findFreeRangeFindsGap() {
        let slots = [
            ScheduleSlot(startHour: 6, endHour: 9, label: "A"),
            ScheduleSlot(startHour: 14, endHour: 18, label: "B"),
        ]
        let gap = SchedulePolicy.findFreeRange(in: slots, minHours: 2)
        #expect(gap != nil)
        #expect((gap?.end ?? 0) - (gap?.start ?? 0) >= 5)
    }

    @Test("findFreeRange: returns nil when no segment satisfies minHours")
    func findFreeRangeReturnsNil() {
        let slots = [ScheduleSlot(startHour: 0, endHour: 23, label: "AlmostFull")]
        #expect(SchedulePolicy.findFreeRange(in: slots, minHours: 2) == nil)
    }

    @Test("findFreeRange: returns whole day when slots empty")
    func findFreeRangeAllFree() {
        let gap = SchedulePolicy.findFreeRange(in: [], minHours: 24)
        #expect(gap?.start == 0)
        #expect(gap?.end == 24)
    }

    @Test("findFreeRange: detects cross-midnight wrap when it is the longest gap")
    func findFreeRangeWrapsMidnight() {
        let slots = [
            ScheduleSlot(startHour: 4, endHour: 7, label: "A"),
            ScheduleSlot(startHour: 8, endHour: 22, label: "B"),
        ]
        let gap = SchedulePolicy.findFreeRange(in: slots, minHours: 2)
        #expect(gap?.start == 22)
        #expect(gap?.end == 28)
        #expect((gap?.end ?? 0) % 24 == 4)
    }

    @Test("findFreeRange: prefers a longer linear gap over a shorter wrap gap")
    func findFreeRangeLinearOverWrap() {
        let slots = [
            ScheduleSlot(startHour: 1, endHour: 5, label: "A"),
            ScheduleSlot(startHour: 8, endHour: 23, label: "B"),
        ]
        let gap = SchedulePolicy.findFreeRange(in: slots, minHours: 2)
        #expect(gap?.start == 5)
        #expect(gap?.end == 8)
    }
}

@Suite("Screen runtime ownership")
@MainActor
struct ScreenRuntimeOwnershipTests {

    @Test("Screen reads summary and cleanup state from installed runtime session")
    func screenUsesInstalledRuntimeSession() {
        guard let nsScreen = NSScreen.screens.first else {
            Issue.record("No NSScreen available for test")
            return
        }

        let screen = Screen(nsScreen: nsScreen)
        let session = TestWallpaperRuntimeSession(
            summary: WallpaperSessionSummary(
                wallpaperType: .html,
                activity: .active,
                supportsPlaybackControl: false,
                subtitle: "Aurora"
            ),
            wallpaperType: .html
        )

        screen.installRuntimeSession(session)

        #expect(screen.wallpaperSessionSummary == session.summary)
        #expect(screen.runtimeSession?.wallpaperType == .html)
        #expect(screen.videoPlayer == nil)

        screen.resetRuntimeSession()

        #expect(session.cleanupCallCount == 1)
        #expect(screen.wallpaperSessionSummary == .notConfigured)
        #expect(screen.activeWallpaperWindow == nil)
    }

    @Test("Prepared session transaction keeps old runtime until readiness then swaps once")
    func preparedSessionTransactionKeepsOldUntilReady() async {
        guard let nsScreen = NSScreen.screens.first else {
            Issue.record("No NSScreen available for test")
            return
        }

        let screen = Screen(nsScreen: nsScreen)
        let old = TestWallpaperRuntimeSession(
            summary: .notConfigured,
            wallpaperType: .video
        )
        let candidate = TestWallpaperRuntimeSession(
            summary: .notConfigured,
            wallpaperType: .video,
            preparationResult: nil
        )
        screen.installRuntimeSession(old)

        let transaction = Task { @MainActor in
            await WallpaperSessionTransaction.prepareAndCommit(
                candidate,
                to: screen,
                replacing: old,
                timeout: .seconds(1),
                isStillCurrent: { true }
            )
        }

        for _ in 0..<20 where candidate.prepareCallCount == 0 {
            await Task.yield()
        }
        #expect((screen.runtimeSession as AnyObject?) === old)
        #expect(old.cleanupCallCount == 0)

        candidate.completePreparation(with: .ready)
        #expect(await transaction.value == .ready)
        #expect((screen.runtimeSession as AnyObject?) === candidate)
        #expect(old.cleanupCallCount == 1)
        #expect(candidate.cleanupCallCount == 0)
    }

    @Test("Failed or stale prepared session cannot replace the current runtime")
    func failedOrStalePreparedSessionDoesNotReplaceCurrentRuntime() async {
        guard let nsScreen = NSScreen.screens.first else {
            Issue.record("No NSScreen available for test")
            return
        }

        let screen = Screen(nsScreen: nsScreen)
        let old = TestWallpaperRuntimeSession(summary: .notConfigured, wallpaperType: .html)
        screen.installRuntimeSession(old)

        let failed = TestWallpaperRuntimeSession(
            summary: .notConfigured,
            wallpaperType: .video,
            preparationResult: .failed
        )
        #expect(
            await WallpaperSessionTransaction.prepareAndCommit(
                failed,
                to: screen,
                replacing: old,
                timeout: .seconds(1),
                isStillCurrent: { true }
            ) == .failed
        )
        #expect((screen.runtimeSession as AnyObject?) === old)
        #expect(failed.cleanupCallCount == 1)

        let stale = TestWallpaperRuntimeSession(
            summary: .notConfigured,
            wallpaperType: .video,
            preparationResult: .ready
        )
        #expect(
            await WallpaperSessionTransaction.prepareAndCommit(
                stale,
                to: screen,
                replacing: old,
                timeout: .seconds(1),
                isStillCurrent: { false }
            ) == .cancelled
        )
        #expect((screen.runtimeSession as AnyObject?) === old)
        #expect(stale.cleanupCallCount == 1)
        #expect(old.cleanupCallCount == 0)
    }

    @Test("Stale CAS never executes configuration commit")
    func staleCASDoesNotPersistProposal() async {
        guard let nsScreen = NSScreen.screens.first else {
            Issue.record("No NSScreen available for test")
            return
        }
        let screen = Screen(nsScreen: nsScreen)
        let expected = TestWallpaperRuntimeSession(summary: .notConfigured, wallpaperType: .video)
        let winner = TestWallpaperRuntimeSession(summary: .notConfigured, wallpaperType: .html)
        let candidate = TestWallpaperRuntimeSession(summary: .notConfigured, wallpaperType: .video)
        screen.installRuntimeSession(expected)
        screen.installRuntimeSession(winner)
        var commitCalls = 0

        let result = await WallpaperSessionTransaction.prepareAndCommit(
            candidate,
            to: screen,
            replacing: expected,
            timeout: .seconds(1),
            isStillCurrent: { true },
            beforeCommit: {
                commitCalls += 1
                return true
            }
        )

        #expect(result == .cancelled)
        #expect(commitCalls == 0)
        #expect((screen.runtimeSession as AnyObject?) === winner)
        #expect(candidate.cleanupCallCount == 1)
    }

    @Test("A newer configuration write fails a prepared proposal closed")
    func configurationRevisionRejectsPreparedProposal() async {
        guard let nsScreen = NSScreen.screens.first else {
            Issue.record("No NSScreen available for test")
            return
        }
        let screen = Screen(nsScreen: nsScreen)
        let old = TestWallpaperRuntimeSession(summary: .notConfigured, wallpaperType: .video)
        let candidate = TestWallpaperRuntimeSession(
            summary: .notConfigured,
            wallpaperType: .html,
            preparationResult: nil
        )
        screen.installRuntimeSession(old)

        var configuration = ScreenConfiguration(
            screenID: screen.id,
            videoBookmarkData: Data([0x01])
        )
        let store = WallpaperConfigurationStore(
            persistence: AutomationTestConfigurationPersistence([configuration])
        )
        let expectedRevision = store.revision(for: screen.id)
        let registry = PlaybackTransitionRegistry()
        let generation = registry.bumpTransition(for: screen.id)
        var commitCalls = 0

        let transaction = Task { @MainActor in
            await WallpaperSessionTransaction.prepareAndCommit(
                candidate,
                to: screen,
                replacing: old,
                timeout: .seconds(1),
                isStillCurrent: {
                    registry.isCurrentTransition(generation, for: screen.id)
                        && store.revision(for: screen.id) == expectedRevision
                },
                beforeCommit: {
                    commitCalls += 1
                    return true
                }
            )
        }
        for _ in 0..<20 where candidate.prepareCallCount == 0 {
            await Task.yield()
        }

        // This is intentionally fail-closed: an in-place settings write is
        // newer intent than the captured candidate configuration.
        configuration.playbackSpeed = 1.5
        store.save(configuration)
        candidate.completePreparation(with: .ready)

        #expect(await transaction.value == .cancelled)
        #expect(commitCalls == 0)
        #expect((screen.runtimeSession as AnyObject?) === old)
        #expect(old.cleanupCallCount == 0)
        #expect(candidate.cleanupCallCount == 1)
    }

    @Test("An unchanged explicit selection still invalidates an older proposal")
    func explicitSelectionInvalidatesPreparedProposal() async {
        guard let nsScreen = NSScreen.screens.first else {
            Issue.record("No NSScreen available for test")
            return
        }
        let manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false,
            startAutomation: false,
            featureCatalog: FeatureCatalog(capabilities: .pro)
        ))
        manager.wallpapersGloballyEnabled = true
        let screen = Screen(nsScreen: nsScreen)
        let old = TestWallpaperRuntimeSession(summary: .notConfigured, wallpaperType: .video)
        let candidate = TestWallpaperRuntimeSession(
            summary: .notConfigured,
            wallpaperType: .html,
            preparationResult: nil
        )
        screen.installRuntimeSession(old)
        let generation = manager.bumpTransition(for: screen.id)

        let transaction = Task { @MainActor in
            await WallpaperSessionTransaction.prepareAndCommit(
                candidate,
                to: screen,
                replacing: old,
                timeout: .seconds(1),
                isStillCurrent: {
                    manager.isCurrentTransition(generation, for: screen.id)
                }
            )
        }
        for _ in 0..<20 where candidate.prepareCallCount == 0 {
            await Task.yield()
        }

        manager.beginExplicitWallpaperSelection(for: screen)
        candidate.completePreparation(with: .ready)

        #expect(await transaction.value == .cancelled)
        #expect((screen.runtimeSession as AnyObject?) === old)
        #expect(candidate.cleanupCallCount == 1)
    }

    @Test("Async explicit edits reject newer transition, configuration, and session identities")
    func asyncExplicitEditUsesFullIntentCAS() {
        let manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false,
            startAutomation: false,
            featureCatalog: FeatureCatalog(capabilities: .pro)
        ))
        guard let screen = manager.screens.first else {
            Issue.record("No NSScreen available for explicit-intent CAS test")
            return
        }
        let originalConfiguration = manager.configurationStore.get(
            for: screen.id,
            fingerprint: screen.displayFingerprint
        )
        defer {
            if let originalConfiguration {
                manager.configurationStore.save(originalConfiguration)
            } else {
                manager.configurationStore.remove(for: screen.id)
            }
            screen.resetRuntimeSession()
        }

        let firstSession = TestWallpaperRuntimeSession(
            summary: .notConfigured,
            wallpaperType: .scene
        )
        screen.installRuntimeSession(firstSession)
        let firstRevision = manager.configurationStore.revision(for: screen.id)
        let firstGeneration = manager.beginExplicitWallpaperSelection(for: screen)
        #expect(manager.isCurrentExplicitWallpaperSelection(
            firstGeneration,
            expectedConfigurationRevision: firstRevision,
            expectedSession: firstSession,
            for: screen
        ))

        _ = manager.bumpTransition(for: screen.id)
        #expect(!manager.isCurrentExplicitWallpaperSelection(
            firstGeneration,
            expectedConfigurationRevision: firstRevision,
            expectedSession: firstSession,
            for: screen
        ))

        let secondGeneration = manager.beginExplicitWallpaperSelection(for: screen)
        let secondRevision = manager.configurationStore.revision(for: screen.id)
        manager.configurationStore.save(ScreenConfiguration(
            screenID: screen.id,
            wallpaper: .html(source: .inline("<p>x</p>"), config: .default)
        ))
        #expect(!manager.isCurrentExplicitWallpaperSelection(
            secondGeneration,
            expectedConfigurationRevision: secondRevision,
            expectedSession: firstSession,
            for: screen
        ))

        let thirdGeneration = manager.beginExplicitWallpaperSelection(for: screen)
        let thirdRevision = manager.configurationStore.revision(for: screen.id)
        let replacementSession = TestWallpaperRuntimeSession(
            summary: .notConfigured,
            wallpaperType: .video
        )
        screen.installRuntimeSession(replacementSession)
        #expect(!manager.isCurrentExplicitWallpaperSelection(
            thirdGeneration,
            expectedConfigurationRevision: thirdRevision,
            expectedSession: firstSession,
            for: screen
        ))
    }

    @Test("Candidate error publication excludes cancellation and stale failures")
    func candidateErrorPublicationRequiresCurrentFailure() {
        #expect(WallpaperCandidateErrorPolicy.errorToPublish(
            .failed,
            isStillCurrent: true,
            candidateError: nil,
            fallbackWallpaperType: .html
        ) == .wallpaperPreparationFailed(type: .html, timedOut: false))
        #expect(WallpaperCandidateErrorPolicy.errorToPublish(
            .timedOut,
            isStillCurrent: true,
            candidateError: nil,
            fallbackWallpaperType: .scene
        ) == .wallpaperPreparationFailed(type: .scene, timedOut: true))
        #expect(WallpaperCandidateErrorPolicy.errorToPublish(
            .failed,
            isStillCurrent: true,
            candidateError: .sandboxRevoked,
            fallbackWallpaperType: .html
        ) == .sandboxRevoked)
        #expect(WallpaperCandidateErrorPolicy.errorToPublish(
            .cancelled,
            isStillCurrent: true,
            candidateError: nil,
            fallbackWallpaperType: .html
        ) == nil)
        #expect(!WallpaperCandidateErrorPolicy.shouldPublish(
            .cancelled,
            isStillCurrent: true
        ))
        #expect(!WallpaperCandidateErrorPolicy.shouldPublish(
            .failed,
            isStillCurrent: false
        ))
        #expect(WallpaperCandidateErrorPolicy.shouldPublish(
            .failed,
            isStillCurrent: true
        ))
        #expect(WallpaperCandidateErrorPolicy.shouldPublish(
            .timedOut,
            isStillCurrent: true
        ))
    }

    @Test("A pre-refresh ambient proposal cannot overwrite its normalized bookmark")
    func ambientCommitKeepsRefreshedBookmark() throws {
        let manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false,
            startAutomation: false,
            featureCatalog: FeatureCatalog(capabilities: .pro)
        ))
        let screenID: CGDirectDisplayID = 77
        let original = Data([0x01, 0x02])
        let refreshed = Data([0x03, 0x04])
        let proposed = ScreenConfiguration(
            screenID: screenID,
            wallpaper: .html(
                source: .folder(
                    bookmarkData: original,
                    indexFileName: "index.html"
                ),
                config: .default
            )
        )
        let effective = try #require(
            proposed.replacingHTMLBookmark(
                matching: original,
                with: refreshed
            )
        )

        // Candidate construction has already persisted the refreshed grant, but
        // the proposal owner's closure still captures the old value.
        manager.configurationStore.save(effective)
        let committed = manager.commitPreparedAmbientConfiguration(
            proposed: proposed,
            effective: effective,
            screenID: screenID,
            ownerCommit: {
                manager.saveConfiguration(proposed)
                return true
            }
        )

        #expect(committed)
        #expect(manager.configurationStore.get(for: screenID) == effective)
    }

    @Test("Rejected configuration commit keeps the old runtime")
    func rejectedCommitKeepsOldRuntime() async {
        guard let nsScreen = NSScreen.screens.first else {
            Issue.record("No NSScreen available for test")
            return
        }
        let screen = Screen(nsScreen: nsScreen)
        let old = TestWallpaperRuntimeSession(summary: .notConfigured, wallpaperType: .video)
        let candidate = TestWallpaperRuntimeSession(summary: .notConfigured, wallpaperType: .html)
        screen.installRuntimeSession(old)

        let result = await WallpaperSessionTransaction.prepareAndCommit(
            candidate,
            to: screen,
            replacing: old,
            timeout: .seconds(1),
            isStillCurrent: { true },
            beforeCommit: { false }
        )

        #expect(result == .failed)
        #expect((screen.runtimeSession as AnyObject?) === old)
        #expect(old.cleanupCallCount == 0)
        #expect(candidate.cleanupCallCount == 1)
    }

    @Test("Hard deadline cleans a candidate before cancellation-insensitive preparation drains")
    func hardDeadlineCleansCandidateBeforePreparationDrains() async {
        guard let nsScreen = NSScreen.screens.first else {
            Issue.record("No NSScreen available for test")
            return
        }
        let screen = Screen(nsScreen: nsScreen)
        let old = TestWallpaperRuntimeSession(summary: .notConfigured, wallpaperType: .video)
        let candidate = TestWallpaperRuntimeSession(
            summary: .notConfigured,
            wallpaperType: .html,
            preparationResult: nil
        )
        screen.installRuntimeSession(old)

        let result = await WallpaperSessionTransaction.prepareAndCommit(
            candidate,
            to: screen,
            replacing: old,
            timeout: .milliseconds(30),
            isStillCurrent: { true }
        )

        #expect(result == .timedOut)
        #expect(candidate.cleanupCallCount == 1)
        #expect((screen.runtimeSession as AnyObject?) === old)
        #expect(old.cleanupCallCount == 0)

        // The fake deliberately ignores cancellation. Resume it after checking
        // cleanup so the orphaned operation drains without extending resource
        // lifetime or leaking a continuation into the rest of the test run.
        candidate.completePreparation(with: .ready)
        await Task.yield()
        #expect((screen.runtimeSession as AnyObject?) === old)
    }

    @Test("Screen refresh during preparation cannot commit into the retired instance")
    func screenRefreshDuringPreparationKeepsAdoptedSessionAlive() async {
        guard let nsScreen = NSScreen.screens.first else {
            Issue.record("No NSScreen available for test")
            return
        }
        let original = Screen(nsScreen: nsScreen)
        let old = TestWallpaperRuntimeSession(summary: .notConfigured, wallpaperType: .video)
        let candidate = TestWallpaperRuntimeSession(
            summary: .notConfigured,
            wallpaperType: .video,
            preparationResult: nil
        )
        original.installRuntimeSession(old)
        var currentScreen = original

        let transaction = Task { @MainActor in
            await WallpaperSessionTransaction.prepareAndCommit(
                candidate,
                to: original,
                replacing: old,
                timeout: .seconds(1),
                isStillCurrent: { currentScreen === original }
            )
        }
        for _ in 0..<20 where candidate.prepareCallCount == 0 {
            await Task.yield()
        }

        let refreshed = Screen(nsScreen: nsScreen)
        refreshed.adoptRuntimeSession(from: original)
        currentScreen = refreshed
        candidate.completePreparation(with: .ready)

        #expect(await transaction.value == .cancelled)
        #expect((refreshed.runtimeSession as AnyObject?) === old)
        #expect(old.cleanupCallCount == 0)
        #expect(candidate.cleanupCallCount == 1)
    }

    @Test("Invalid proposal keeps the current runtime and skips configuration commit")
    func invalidProposalKeepsCurrentRuntimeAndConfiguration() {
        guard let nsScreen = NSScreen.screens.first else {
            Issue.record("No NSScreen available for test")
            return
        }
        let manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false,
            startAutomation: false,
            featureCatalog: FeatureCatalog(capabilities: .pro)
        ))
        manager.wallpapersGloballyEnabled = true
        let screen = Screen(nsScreen: nsScreen)
        let current = TestWallpaperRuntimeSession(
            summary: .notConfigured,
            wallpaperType: .video
        )
        screen.installRuntimeSession(current)
        let invalidProposal = ScreenConfiguration(
            screenID: screen.id,
            wallpaper: .html(source: .inline(""), config: .default)
        )
        var commitCalls = 0

        manager.restoreWallpaperSession(
            for: screen,
            configuration: invalidProposal,
            preservingState: false,
            intent: .proposal,
            beforeCommit: {
                commitCalls += 1
                return true
            }
        )

        #expect((screen.runtimeSession as AnyObject?) === current)
        #expect(current.cleanupCallCount == 0)
        #expect(commitCalls == 0)
    }

    @Test("Invalid persisted restore preserves the existing cleanup policy")
    func invalidPersistedRestoreCleansCurrentRuntime() {
        guard let nsScreen = NSScreen.screens.first else {
            Issue.record("No NSScreen available for test")
            return
        }
        let manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false,
            startAutomation: false,
            featureCatalog: FeatureCatalog(capabilities: .pro)
        ))
        manager.wallpapersGloballyEnabled = true
        let screen = Screen(nsScreen: nsScreen)
        let current = TestWallpaperRuntimeSession(
            summary: .notConfigured,
            wallpaperType: .video
        )
        screen.installRuntimeSession(current)
        let invalidPersistedConfiguration = ScreenConfiguration(
            screenID: screen.id,
            wallpaper: .html(source: .inline(""), config: .default)
        )

        manager.restoreWallpaperSession(
            for: screen,
            configuration: invalidPersistedConfiguration,
            preservingState: false
        )

        #expect(screen.runtimeSession == nil)
        #expect(current.cleanupCallCount == 1)
    }

    @Test("Every proposal restore entry point opts into proposal intent")
    func proposalRestoreEntryPointsUseProposalIntent() throws {
        let screensSource = try RepositoryRoot.source(
            "LiveWallpaper/App/ScreenManager+Screens.swift"
        )
        let managerSource = try RepositoryRoot.source(
            "LiveWallpaper/App/ScreenManager.swift"
        )
        let monitorSource = try RepositoryRoot.source(
            "LiveWallpaper/App/ScreenManager+Monitor.swift"
        )
        let wallpaperSource = try RepositoryRoot.source(
            "LiveWallpaper/App/ScreenManager+Wallpaper.swift"
        )
        let playbackSource = try RepositoryRoot.source(
            "LiveWallpaper/Runtime/Coordinators/PlaybackCoordinator+SessionLifecycle.swift"
        )

        #expect(screensSource.contains("intent: .proposal"))
        #expect(screensSource.contains("intent: intent"))
        #expect(
            managerSource.components(separatedBy: "intent: .proposal").count - 1 >= 2
        )
        #expect(monitorSource.contains("intent: .proposal"))
        #expect(wallpaperSource.contains("intent: intent"))
        #expect(playbackSource.contains("intent == .persistedConfiguration"))
    }

    @Test("Every explicit content selector begins a latest-intent boundary")
    func explicitContentSelectorsBeginLatestIntent() throws {
        let wallpaperSource = try RepositoryRoot.source(
            "LiveWallpaper/App/ScreenManager+Wallpaper.swift"
        )
        let monitorSource = try RepositoryRoot.source(
            "LiveWallpaper/App/ScreenManager+Monitor.swift"
        )
        let automationSource = try RepositoryRoot.source(
            "LiveWallpaper/App/ScreenManager+Automation.swift"
        )
        let sceneMutationSource = try RepositoryRoot.source(
            "LiveWallpaper/App/ScreenManager+SceneMutation.swift"
        )

        func selectorBeginsIntent(_ signature: String, in source: String) -> Bool {
            guard let start = source.range(of: signature)?.lowerBound else { return false }
            return source[start...].prefix(900).contains(
                "beginExplicitWallpaperSelection(for: screen)"
            )
        }

        #expect(selectorBeginsIntent("func setVideo(", in: wallpaperSource))
        #expect(selectorBeginsIntent("func setHTMLWallpaper(", in: wallpaperSource))
        #expect(selectorBeginsIntent("func switchToVideoWallpaper(", in: wallpaperSource))
        #expect(selectorBeginsIntent("func switchToHTMLWallpaper(", in: wallpaperSource))
        #expect(selectorBeginsIntent("func setSceneWallpaper(", in: monitorSource))
        #expect(selectorBeginsIntent("func importWallpaperEngineProject(", in: automationSource))
        #expect(selectorBeginsIntent("func activateWPEHistoryEntry(", in: automationSource))
        #expect(selectorBeginsIntent("func updateSceneDescriptor(", in: sceneMutationSource))
        let sceneIntent = try #require(sceneMutationSource.range(
            of: "let generation = beginExplicitWallpaperSelection(for: screen)"
        ))
        let sceneNoOp = try #require(sceneMutationSource.range(
            of: "guard current != descriptor else { return }"
        ))
        #expect(sceneIntent.lowerBound < sceneNoOp.lowerBound)
        #expect(
            sceneMutationSource.components(
                separatedBy: "guard isCurrentExplicitWallpaperSelection("
            ).count - 1 == 3
        )
    }

    @Test("Scene property patches validate latest intent at the renderer mutation point")
    func scenePropertyPatchAdmissionIsRendererLocal() throws {
        let sceneMutationSource = try RepositoryRoot.source(
            "LiveWallpaper/App/ScreenManager+SceneMutation.swift"
        )
        let sessionSource = try RepositoryRoot.source(
            "LiveWallpaper/Runtime/Session/SceneWallpaperSession.swift"
        )
        let renderActorSource = try RepositoryRoot.source(
            "LiveWallpaper/Runtime/Metal/RenderThread/WPEDisplayRenderActor.swift"
        )
        let scenePreviewSource = try RepositoryRoot.source(
            "LiveWallpaper/Views/ScreenDetail/SceneDetailView.swift"
        )
        let wallpaperSource = try RepositoryRoot.source(
            "LiveWallpaper/App/ScreenManager+Wallpaper.swift"
        )
        let screensSource = try RepositoryRoot.source(
            "LiveWallpaper/App/ScreenManager+Screens.swift"
        )
        let playbackHelpersSource = try RepositoryRoot.source(
            "LiveWallpaper/Runtime/Coordinators/PlaybackCoordinator+Helpers.swift"
        )

        #expect(sceneMutationSource.contains(
            "let sceneMutationToken = sceneSession.currentScenePropertyMutationToken()"
        ))
        #expect(sceneMutationSource.contains(
            "expectedIntent: sceneMutationToken"
        ))
        #expect(sessionSource.contains(
            "authority: scenePropertyMutationAuthority"
        ))
        #expect(renderActorSource.contains(
            "guard authority.isCurrent(token)"
        ))
        #expect(renderActorSource.contains(
            "renderer?.canApplyScenePropertyPatch(patch)"
        ))
        #expect(renderActorSource.contains(
            "func commitScenePropertyPatch("
        ))
        // Commit both applies the patch and refreshes the reload source of
        // truth, so an in-place reload (hibernate wake / retry) can't revert
        // the committed edits.
        #expect(renderActorSource.contains(
            "renderer.applyScenePropertyPatch(prepared.patch)"
        ))
        #expect(renderActorSource.contains(
            "renderer.descriptor = updatedDescriptor"
        ))
        #expect(sessionSource.contains(
            "waitForScenePropertyPosterCommit"
        ))
        #expect(sceneMutationSource.contains(
            "posterCommit: posterCommit"
        ))
        #expect(!scenePreviewSource.contains("Timer.publish"))
        #expect(wallpaperSource.contains(
            "advanceScenePropertyMutationIntent(for: screenID)"
        ))
        #expect(screensSource.contains(
            "advanceScenePropertyMutationIntent(for: configuration.screenID)"
        ))
        #expect(playbackHelpersSource.contains(
            "advanceSceneMutationIntent(configuration.screenID)"
        ))

        let preflight = try #require(sceneMutationSource.range(
            of: "await sceneSession.prepareScenePropertyPatch("
        ))
        let finalCAS = try #require(sceneMutationSource.range(
            of: "expectedSceneMutationToken: sceneMutationToken",
            range: preflight.upperBound..<sceneMutationSource.endIndex
        ))
        let persistence = try #require(sceneMutationSource.range(
            of: "saveConfiguration(configuration)",
            range: finalCAS.upperBound..<sceneMutationSource.endIndex
        ))
        let posterStage = try #require(sceneMutationSource.range(
            of: "stageScenePropertyPosterCommit(",
            range: finalCAS.upperBound..<persistence.lowerBound
        ))
        let rendererCommit = try #require(sceneMutationSource.range(
            of: "await sceneSession.commitScenePropertyPatch(",
            range: persistence.upperBound..<sceneMutationSource.endIndex
        ))
        let posterWait = try #require(scenePreviewSource.range(
            of: "await targetSession.waitForScenePropertyPosterCommit("
        ))
        let posterCapture = try #require(scenePreviewSource.range(
            of: "await targetSession.captureLivePosterFromNextFrame()",
            range: posterWait.upperBound..<scenePreviewSource.endIndex
        ))
        #expect(preflight.lowerBound < finalCAS.lowerBound)
        #expect(finalCAS.lowerBound < posterStage.lowerBound)
        #expect(posterStage.lowerBound < persistence.lowerBound)
        #expect(persistence.lowerBound < rendererCommit.lowerBound)
        #expect(posterWait.lowerBound < posterCapture.lowerBound)
    }

    @Test("Ambient and video candidate errors reuse the install-current predicate")
    func candidateErrorsReuseInstallCurrentPredicate() throws {
        let ambientSource = try RepositoryRoot.source(
            "LiveWallpaper/App/ScreenManager+AmbientTransaction.swift"
        )
        let videoSource = try RepositoryRoot.source(
            "LiveWallpaper/Runtime/Coordinators/PlaybackCoordinator+SessionLifecycle.swift"
        )

        #expect(ambientSource.contains("isStillCurrent: isCandidateStillCurrent"))
        #expect(ambientSource.contains(
            "isStillCurrent: isCandidateStillCurrent()"
        ))
        #expect(ambientSource.contains("errorToPublish("))

        #expect(videoSource.contains("isStillCurrent: isCandidateStillCurrent"))
        #expect(videoSource.contains(
            "isStillCurrent: isCandidateStillCurrent()"
        ))
        #expect(videoSource.contains("WallpaperCandidateErrorPolicy.shouldPublish("))
    }

    @Test("Refreshing without preserving sessions cleans up connected screen sessions")
    func refreshWithoutPreservingSessionsCleansUpConnectedSessions() {
        let manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false,
            startAutomation: false,
            featureCatalog: FeatureCatalog(capabilities: .pro)
        ))
        guard let screen = manager.screens.first else {
            Issue.record("No screen available for test")
            return
        }
        let session = TestWallpaperRuntimeSession(
            summary: WallpaperSessionSummary(
                wallpaperType: .html,
                activity: .active,
                supportsPlaybackControl: false,
                subtitle: "Aurora"
            ),
            wallpaperType: .html
        )

        screen.installRuntimeSession(session)

        manager.refreshScreens(preserveRuntimeSessions: false)

        #expect(session.cleanupCallCount == 1)
    }
}

@MainActor
private final class TestWallpaperRuntimeSession: WallpaperRuntimeSession {
    let wallpaperType: WallpaperType
    let summary: WallpaperSessionSummary
    let videoPlayer: WallpaperVideoPlayer? = nil
    let wallpaperWindow: NSWindow? = nil
    private(set) var cleanupCallCount = 0
    private(set) var prepareCallCount = 0
    private var preparationResult: WallpaperPreparationResult?
    private var preparationContinuation: CheckedContinuation<WallpaperPreparationResult, Never>?

    init(
        summary: WallpaperSessionSummary,
        wallpaperType: WallpaperType,
        preparationResult: WallpaperPreparationResult? = .ready
    ) {
        self.summary = summary
        self.wallpaperType = wallpaperType
        self.preparationResult = preparationResult
    }

    func updateFrame(to frame: CGRect) {}

    func show() {}

    func applyPerformanceProfile(_ profile: WallpaperPerformanceProfile) {}

    func prepareForDisplay(timeout: Duration) async -> WallpaperPreparationResult {
        prepareCallCount += 1
        if let preparationResult {
            return preparationResult
        }
        return await withCheckedContinuation { continuation in
            preparationContinuation = continuation
        }
    }

    func completePreparation(with result: WallpaperPreparationResult) {
        preparationResult = result
        preparationContinuation?.resume(returning: result)
        preparationContinuation = nil
    }

    func cleanup() {
        cleanupCallCount += 1
    }
}

// MARK: - Infrastructure ↔ Runtime boundary

@Suite("Infrastructure↔Runtime boundary")
struct InfrastructureRuntimeBoundaryTests {

    private static let baseline: [String: Set<String>] = [
        "Workshop/WallpaperEngineImportService.swift": ["HTMLWallpaperCompatibilityPolicy"],
    ]

    @Test("Infrastructure introduces no Runtime references beyond the approved baseline")
    func infrastructureDoesNotReferenceRuntimeTypesBeyondBaseline() throws {
        let runtimeTypes = try runtimeDeclaredTypeNames()
        #expect(!runtimeTypes.isEmpty, "Runtime type extraction found nothing — scan is misconfigured")

        let infrastructureFiles = try infrastructureSwiftFiles()
        #expect(
            !infrastructureFiles.isEmpty,
            Comment(rawValue: "Infrastructure scan found no files at \(infrastructureRoot.path) — the boundary is unenforced, not clean")
        )

        let sources = try infrastructureFiles.map { file in
            (
                path: file.path.replacingOccurrences(of: infrastructureRoot.path + "/", with: ""),
                source: try String(contentsOf: file, encoding: .utf8)
            )
        }
        let newCrossings = boundaryCrossings(
            runtimeTypes: runtimeTypes,
            infrastructureSources: sources,
            baseline: Self.baseline
        )

        #expect(
            newCrossings.isEmpty,
            Comment(rawValue: """
            New Infrastructure→Runtime coupling violates the architecture boundary:
            \(newCrossings.sorted().joined(separator: "\n"))
            """)
        )
    }

    @Test("Boundary baseline stays honest — no stale entries")
    func baselineHasNoStaleEntries() throws {
        let runtimeTypes = try runtimeDeclaredTypeNames()
        var stale: [String] = []

        for (relativePath, allowed) in Self.baseline {
            let file = infrastructureRoot.appendingPathComponent(relativePath)
            guard let code = try? String(contentsOf: file, encoding: .utf8) else {
                stale.append("\(relativePath) (file no longer exists)")
                continue
            }
            let stripped = stripComments(code)
            for type in allowed where !runtimeTypes.contains(type) || !containsIdentifier(type, in: stripped) {
                stale.append("\(relativePath): \(type)")
            }
        }

        #expect(
            stale.isEmpty,
            Comment(rawValue: """
            Baseline lists crossings that no longer exist — shrink the allow-list:
            \(stale.sorted().joined(separator: "\n"))
            """)
        )
    }

    @Test("Boundary fitness detector rejects a seeded Runtime dependency")
    func boundaryDetectorRejectsSeededRuntimeDependency() {
        let runtimeType = "WPEMetalSceneRenderer"
        let forbidden = boundaryCrossings(
            runtimeTypes: [runtimeType],
            infrastructureSources: [(path: "Seed.swift", source: "let renderer: WPEMetalSceneRenderer")],
            baseline: [:]
        )
        let proseOnly = boundaryCrossings(
            runtimeTypes: [runtimeType],
            infrastructureSources: [
                (path: "Seed.swift", source: "// WPEMetalSceneRenderer\nlet note = \"WPEMetalSceneRenderer\"")
            ],
            baseline: [:]
        )

        #expect(forbidden == ["Seed.swift references Runtime type WPEMetalSceneRenderer"])
        #expect(proseOnly.isEmpty)
    }

    // MARK: - Repository source scanning

    private var infrastructureRoot: URL {
        RepositoryRoot.url("LiveWallpaper/Infrastructure")
    }

    private func infrastructureSwiftFiles() throws -> [URL] {
        RepositoryRoot.swiftFiles(underURL: infrastructureRoot)
    }

    private func boundaryCrossings(
        runtimeTypes: Set<String>,
        infrastructureSources: [(path: String, source: String)],
        baseline: [String: Set<String>]
    ) -> [String] {
        var crossings: [String] = []
        for file in infrastructureSources {
            let code = stripComments(file.source)
            let allowed = baseline[file.path] ?? []
            for type in runtimeTypes.sorted() where !allowed.contains(type) {
                guard containsIdentifier(type, in: code) else { continue }
                crossings.append("\(file.path) references Runtime type \(type)")
            }
        }
        return crossings.sorted()
    }

    private func runtimeDeclaredTypeNames() throws -> Set<String> {
        let declaration = /^(?:public |internal |open )*(?:final )?(?:class|struct|enum|protocol|actor)\s+([A-Za-z_][A-Za-z0-9_]*)/
        var names: Set<String> = []
        for file in RepositoryRoot.swiftFiles(under: "LiveWallpaper/Runtime") {
            for line in try String(contentsOf: file, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false) {
                if let match = try declaration.prefixMatch(in: line) {
                    names.insert(String(match.output.1))
                }
            }
        }
        return names
    }

    private func containsIdentifier(_ identifier: String, in source: String) -> Bool {
        guard !identifier.isEmpty else { return false }
        func isIdentifierCharacter(_ character: Character) -> Bool {
            character == "_" || character.isLetter || character.isNumber
        }
        var searchStart = source.startIndex
        while let range = source.range(of: identifier, range: searchStart..<source.endIndex) {
            let boundaryBefore = range.lowerBound == source.startIndex
                || !isIdentifierCharacter(source[source.index(before: range.lowerBound)])
            let boundaryAfter = range.upperBound == source.endIndex
                || !isIdentifierCharacter(source[range.upperBound])
            if boundaryBefore && boundaryAfter { return true }
            searchStart = range.upperBound
        }
        return false
    }

    // MARK: - Non-code text stripping (so a type named only in prose never trips the scan)

    private func stripComments(_ source: String) -> String {
        stripLineComments(stripBlockComments(source))
    }

    private func stripBlockComments(_ source: String) -> String {
        var result = ""
        result.reserveCapacity(source.count)
        var index = source.startIndex
        var inString = false
        var escaped = false
        while index < source.endIndex {
            let character = source[index]
            let next = source.index(after: index)
            if inString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false; result.append(character) }
                else if character == "\n" { result.append(character) }
                index = next
            } else if character == "\"" {
                inString = true
                result.append(character)
                index = next
            } else if character == "/", next < source.endIndex, source[next] == "*" {
                index = source.index(after: next)
                while index < source.endIndex {
                    if source[index] == "*",
                       source.index(after: index) < source.endIndex,
                       source[source.index(after: index)] == "/" {
                        index = source.index(index, offsetBy: 2)
                        break
                    }
                    index = source.index(after: index)
                }
            } else {
                result.append(character)
                index = next
            }
        }
        return result
    }

    private func stripLineComments(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let commentStart = lineCommentStart(in: line) else { return line }
                return line[line.startIndex..<commentStart]
            }
            .joined(separator: "\n")
    }

    private func lineCommentStart(in line: Substring) -> Substring.Index? {
        var inString = false
        var escaped = false
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if escaped {
                escaped = false
            } else if inString && character == "\\" {
                escaped = true
            } else if character == "\"" {
                inString.toggle()
            } else if !inString && character == "/" {
                let next = line.index(after: index)
                if next < line.endIndex && line[next] == "/" {
                    return index
                }
            }
            index = line.index(after: index)
        }
        return nil
    }
}
