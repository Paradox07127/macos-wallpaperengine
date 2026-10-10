import AppKit
import Foundation
import ImageIO
@testable import LiveWallpaper
import LiveWallpaperCore
import Metal
import os
import SwiftUI
import Testing
import WebKit

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
        // Not the English literal: the app language follows the user's preference.
        #expect(displayNames[1] == HTMLSource.inline("<html></html>").displayName)
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
        let plan = AppStartupPlan(runtimeOptions: options)

        #expect(plan.screenManagerOptions.restoreSavedWallpapers == false)
        #expect(plan.screenManagerOptions.startAutomation == false)
        #expect(plan.showSettingsOnLaunch == true)
    }

    @Test("UI launch tests can request settings on launch through environment")
    func uiLaunchTestingCanOpenSettingsOnLaunchThroughEnvironment() {
        let options = AppRuntimeOptions(
            arguments: ["LiveWallpaper", "--ui-testing"],
            environment: ["LIVEWALLPAPER_OPEN_SETTINGS": "1"],
            isXCTestLoaded: false
        )
        let plan = AppStartupPlan(runtimeOptions: options)

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

        let plan = AppStartupPlan(runtimeOptions: runtime)

        #expect(plan.screenManagerOptions.restoreSavedWallpapers)
        #expect(plan.screenManagerOptions.startAutomation)
        #if LITE_BUILD
        #expect(plan.screenManagerOptions.featureCatalog.capabilities.sku == .lite)
        #expect(!plan.screenManagerOptions.featureCatalog.isEnabled(.workshopOnline))
        #else
        #expect(plan.screenManagerOptions.featureCatalog.capabilities.sku == .pro)
        #expect(plan.screenManagerOptions.featureCatalog.isEnabled(.workshopOnline))
        #endif
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

    @Test("Tapping Pause during a policy suspend clears intent, and playback stays stopped when it lifts")
    func pauseTapDuringPolicySuspendStaysPaused() {
        let playback = FakePlaybackController(isPlaying: true)
        guard let screen = makeScreen(installing: playback) else {
            Issue.record("No NSScreen available for test")
            return
        }

        playback.applyPerformanceProfile(.suspended)
        #expect(!playback.isPlaying, "Policy suspend should stop visible playback")
        #expect(playback.userIntendsToPlay, "Policy suspend must not touch user intent")

        makeManager().togglePlayback(for: screen)
        #expect(!playback.userIntendsToPlay, "A tap on the Pause-labelled button kept the intent to play")
        #expect(playback.pauseCount == 1)

        playback.applyPerformanceProfile(.quality)
        #expect(!playback.isPlaying, "A wallpaper the user paused resumed when the policy suspend lifted")
    }

    /// Not two `Screen`s: `Screen.id` comes from the panel, so two on one `NSScreen`
    /// collide and a second physical display would make this vacuous on CI.
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

        #expect(!ScreenManager.globalToggleWantsPause([suspended]))
    }

    @Test("Toggle follows the button label, which shows intent: a policy-suspended wallpaper pauses")
    func toggleFollowsButtonLabelShowingIntent() {
        let playback = FakePlaybackController(isPlaying: false, userIntendsToPlay: true)
        guard let screen = makeScreen(installing: playback) else {
            Issue.record("No NSScreen available for test")
            return
        }

        makeManager().togglePlayback(for: screen)

        #expect(!playback.userIntendsToPlay)
        #expect(playback.pauseCount == 1)
        #expect(playback.playCount == 0)
    }
}

@Suite("WeatherReactivePolicy")
struct WeatherReactivePolicyTests {
    @Test("Particles draw without a wallpaper session, but obey the master gate")
    func particlesDoNotRequireAWallpaper() {
        #expect(WeatherReactivePolicy.shouldDrawParticles(effect: .rain, wallpapersEnabled: true))
        #expect(WeatherReactivePolicy.shouldDrawParticles(effect: .snow, wallpapersEnabled: true))
        #expect(!WeatherReactivePolicy.shouldDrawParticles(effect: .none, wallpapersEnabled: true))
        #expect(!WeatherReactivePolicy.shouldDrawParticles(effect: .rain, wallpapersEnabled: false))
    }

    @Test("Global wallpaper disable suppresses both weather particle and widget demand")
    func disabledWallpapersNeverDemandWeather() {
        let overlay = WeatherOverlayConfiguration(particleEffect: .rain, weatherReactive: true)
        for widgetPlaced in [false, true] {
            #expect(!WeatherReactivePolicy.shouldMonitor(
                overlays: [overlay], weatherWidgetPlaced: widgetPlaced, wallpapersEnabled: false
            ))
            #expect(WeatherReactivePolicy.shouldMonitor(
                overlays: [overlay], weatherWidgetPlaced: widgetPlaced, wallpapersEnabled: true
            ))
        }
    }

    @Test("weather is fetched only for a display that both draws particles and follows the sky")
    func monitorNeedsBothSwitches() {
        func overlay(effect: ParticleEffect, reactive: Bool) -> WeatherOverlayConfiguration {
            WeatherOverlayConfiguration(particleEffect: effect, weatherReactive: reactive)
        }

        #expect(WeatherReactivePolicy.shouldMonitor(overlays: [overlay(effect: .rain, reactive: true)]))
        #expect(
            !WeatherReactivePolicy.shouldMonitor(overlays: [overlay(effect: .none, reactive: true)]),
            "fetching for a display whose weather overlay is switched off"
        )
        #expect(!WeatherReactivePolicy.shouldMonitor(overlays: [overlay(effect: .rain, reactive: false)]))
        #expect(!WeatherReactivePolicy.shouldMonitor(overlays: [overlay(effect: .none, reactive: false)]))
        #expect(!WeatherReactivePolicy.shouldMonitor(overlays: []))
        #expect(WeatherReactivePolicy.shouldMonitor(
            overlays: [overlay(effect: .none, reactive: true), overlay(effect: .snow, reactive: true)]
        ))
    }

    @Test("wind direction resolves to the side it actually blows towards")
    func windDirectionSign() {
        #expect(WeatherWindPolicy.horizontalBias(fromDegrees: 270) > 0.99)   // westerly → right
        #expect(WeatherWindPolicy.horizontalBias(fromDegrees: 90) < -0.99)   // easterly → left
        #expect(abs(WeatherWindPolicy.horizontalBias(fromDegrees: 0)) < 0.001)
        #expect(abs(WeatherWindPolicy.horizontalBias(fromDegrees: 180)) < 0.001)
        #expect(WeatherWindPolicy.horizontalBias(fromDegrees: .nan) == 0)
    }

    /// The lean comes from `atan(wind / fall)`, so the same wind tilts snow far
    /// more than rain — a snowflake falls about an order of magnitude slower.
    @Test("the same wind leans snow much further than rain")
    func windTiltsSlowParticlesMore() {
        let wind = 25.0
        let rain = WeatherWindPolicy.tiltRadians(
            windSpeedKPH: wind, fallSpeedMPS: WeatherWindPolicy.FallSpeed.rain
        )
        let snow = WeatherWindPolicy.tiltRadians(
            windSpeedKPH: wind, fallSpeedMPS: WeatherWindPolicy.FallSpeed.snow
        )
        #expect(rain > 0)
        #expect(snow > rain)
        #expect(WeatherWindPolicy.tiltRadians(windSpeedKPH: 0, fallSpeedMPS: 8) == 0)
        let gale = WeatherWindPolicy.tiltRadians(windSpeedKPH: 200, fallSpeedMPS: 1)
        #expect(gale < .pi / 6)
        let breeze = WeatherWindPolicy.tiltRadians(windSpeedKPH: 15, fallSpeedMPS: 8)
        let strong = WeatherWindPolicy.tiltRadians(windSpeedKPH: 45, fallSpeedMPS: 8)
        let storm = WeatherWindPolicy.tiltRadians(windSpeedKPH: 90, fallSpeedMPS: 8)
        #expect(breeze < strong)
        #expect(strong < storm)
        #expect(WeatherWindPolicy.tiltRadians(windSpeedKPH: .nan, fallSpeedMPS: 8) == 0)
        #expect(WeatherWindPolicy.tiltRadians(windSpeedKPH: 20, fallSpeedMPS: 0) == 0)
    }

    @Test("weather off means the preset alone")
    func weatherOffIgnoresWindAndIntensity() {
        for intensity in [WeatherIntensity.light, .moderate, .heavy] {
            #expect(
                WeatherReactivePolicy.resolvedParticleDensity(
                    userDensity: 1.0, weatherReactive: false, intensity: intensity
                ) == 1.0,
                "intensity \(intensity) leaked into a non-reactive display"
            )
        }
    }

    @Test("intensity scaling can be switched off on its own")
    func intensityScalingIsOptional() {
        let heavy = WeatherReactivePolicy.resolvedParticleDensity(
            userDensity: 1.0, weatherReactive: true, intensity: .heavy, intensityEnabled: true
        )
        let flat = WeatherReactivePolicy.resolvedParticleDensity(
            userDensity: 1.0, weatherReactive: true, intensity: .heavy, intensityEnabled: false
        )
        #expect(heavy > 1.0, "heavy rain did not thicken the field")
        #expect(flat == 1.0, "intensity still applied with the switch off")
    }

    @Test("weather sub-options carry their intended defaults")
    func weatherSubOptionDefaults() {
        let config = VideoEffectConfig()
        #expect(config.weatherWind == false)
        #expect(config.weatherIntensity == true)

        // Configurations written before these keys existed must land on the
        // same values rather than on `false` for both.
        let legacy = #"{"weatherReactive":true}"#.data(using: .utf8)!
        let decoded = try! JSONDecoder().decode(VideoEffectConfig.self, from: legacy)
        #expect(decoded.weatherWind == false)
        #expect(decoded.weatherIntensity == true)
    }

    @Test("WMO intensity survives the mapping")
    func wmoIntensityIsPreserved() {
        // Drizzle 51/53/55, rain 61/63/65, snow 71/73/75, showers 80/81/82.
        for (light, moderate, heavy) in [(51, 53, 55), (61, 63, 65), (71, 73, 75), (80, 81, 82)] {
            #expect(WeatherCodePolicy.intensity(forWMOCode: light) == .light, "\(light)")
            #expect(WeatherCodePolicy.intensity(forWMOCode: moderate) == .moderate, "\(moderate)")
            #expect(WeatherCodePolicy.intensity(forWMOCode: heavy) == .heavy, "\(heavy)")
        }
    }

    /// 77 is snow grains — the lightest snow there is.
    @Test("snow grains are the lightest snow, not the heaviest")
    func snowGrainsAreLight() {
        #expect(WeatherCodePolicy.intensity(forWMOCode: 77) == .light)
    }

    @Test("freezing drizzle and freezing rain are flagged, plain ones are not")
    func freezingCodesAreFlagged() {
        for code in [56, 57, 66, 67] {
            #expect(WeatherCodePolicy.isFreezing(wmoCode: code), "\(code)")
        }
        for code in [51, 55, 61, 65, 71, 75, 95] {
            #expect(!WeatherCodePolicy.isFreezing(wmoCode: code), "\(code)")
        }
    }

    @Test("codes without an intensity axis answer moderate")
    func nonGradedCodesAreModerate() {
        for code in [0, 1, 2, 3, 45, 48] {
            #expect(WeatherCodePolicy.intensity(forWMOCode: code) == .moderate, "\(code)")
        }
    }

    @Test("intensity scales the user's density without taking it over")
    func intensityScalesUserDensity() {
        func density(_ user: Double, _ intensity: WeatherIntensity, reactive: Bool = true) -> Double {
            WeatherReactivePolicy.resolvedParticleDensity(
                userDensity: user, weatherReactive: reactive, intensity: intensity
            )
        }
        #expect(density(1.0, .light) < density(1.0, .moderate))
        #expect(density(1.0, .moderate) < density(1.0, .heavy))
        #expect(density(0.4, .heavy) < density(1.0, .heavy))
        #expect(density(1.0, .heavy, reactive: false) == 1.0)
        #expect(density(1.0, .light, reactive: false) == 1.0)
        #expect(density(3.0, .heavy) <= 3.0)
        #expect(density(0.2, .light) >= 0.2)
        #expect(density(.nan, .moderate).isFinite)
    }

    @Test("Turning the display's particles off beats Match local weather")
    func masterSwitchOffWinsOverWeather() {
        // `.none` is exactly what "Show on This Display" writes when it is switched off.
        #expect(WeatherReactivePolicy.resolvedParticleEffect(
            chosen: .none, weatherReactive: true, weatherEffect: .snow
        ) == .none)

        #expect(WeatherReactivePolicy.resolvedParticleEffect(
            chosen: .rain, weatherReactive: true, weatherEffect: .snow
        ) == .snow)

        #expect(WeatherReactivePolicy.resolvedParticleEffect(
            chosen: .rain, weatherReactive: false, weatherEffect: .snow
        ) == .rain)
        #expect(WeatherReactivePolicy.resolvedParticleEffect(
            chosen: .none, weatherReactive: false, weatherEffect: .snow
        ) == .none)
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
    @Test("Legacy reorder safely recovers an invalid stored cursor", arguments: [-1, Int.min, Int.max])
    func legacyReorderRecoversInvalidCursor(cursor: Int) throws {
        let screen = try Screen(nsScreen: #require(NSScreen.screens.first))
        let primary = Data([1]), other = Data([2])
        var configuration = ScreenConfiguration(screenID: screen.id, videoBookmarkData: primary, playlistBookmarks: [other])
        configuration.playlistCursorIndex = cursor
        let store = WallpaperConfigurationStore(persistence: AutomationTestConfigurationPersistence([configuration]))
        let orchestrator = WallpaperAutomationOrchestrator(
            configurationStore: store, automationCoordinator: WallpaperAutomationCoordinator(),
            playableVideoLoader: FakePlayableVideoLoader(), screensProvider: { [screen] },
            saveConfiguration: { store.save($0) }, recordBookmarkDisplayName: { _, _ in },
            setupPreparedVideoPlayback: { _, _, _, _ in Issue.record("Reorder must not rebuild playback") },
            restoreProposedConfiguration: { _, _ in Issue.record("Retained active bookmark must not reload") },
            bumpTransition: { _ in 0 }, isCurrentTransition: { _, _ in true },
            prepareAutomation: { _, _, _, _ in
                Issue.record("Retained active bookmark must not reload")
                return .cancelled
            }
        )
        orchestrator.replacePlaylist(ordered: [other, primary], primary: primary, for: screen)
        #expect(store.get(for: screen.id)?.playlistCursorIndex == 1)
        #expect(store.get(for: screen.id)?.activeWallpaper == .video(bookmarkData: primary))
        #expect(store.get(for: screen.id)?.combinedPlaylist == [other, primary])
    }

    @Test("Universal queue navigation reaches the product restore path for every wallpaper type")
    func universalQueueRoutesAllTypes() async throws {
        let screen = try Screen(nsScreen: #require(NSScreen.screens.first))
        let entries = [
            WallpaperQueueEntry(title: "Video", content: .video(bookmarkData: Data([1]))),
            WallpaperQueueEntry(title: "Web", content: .html(source: .inline("hello"), config: .default)),
            WallpaperQueueEntry(title: "Scene", content: .scene(SceneDescriptor(workshopID: "42", cacheRelativePath: "wpe-cache/42", entryFile: "scene.json", capabilityTier: .imageOnly))),
        ]
        var initial = ScreenConfiguration(screenID: screen.id, wallpaper: entries[0].content, fitMode: .aspectFit)
        initial.wallpaperQueue = entries
        initial.playlistRotationMinutes = 1
        let persistence = AutomationTestConfigurationPersistence([initial])
        let store = WallpaperConfigurationStore(persistence: persistence)
        var restored: [WallpaperContent] = []
        let orchestrator = WallpaperAutomationOrchestrator(
            configurationStore: store, automationCoordinator: WallpaperAutomationCoordinator(),
            playableVideoLoader: FakePlayableVideoLoader(), screensProvider: { [screen] },
            saveConfiguration: { store.save($0) }, recordBookmarkDisplayName: { _, _ in },
            setupPreparedVideoPlayback: { _, _, _, _ in Issue.record("Universal entries must use the common product restore path") },
            restoreProposedConfiguration: { _, _ in },
            bumpTransition: { _ in 0 }, isCurrentTransition: { _, _ in true },
            prepareAutomation: { _, proposed, _, intended in
                guard intended() else { return .cancelled }
                restored.append(proposed.activeWallpaper)
                store.save(proposed)
                return .ready
            }, libraryEntryAvailable: { _ in true }
        )
        for step in [orchestrator.advancePlaylist, orchestrator.advancePlaylist, orchestrator.advancePlaylist, orchestrator.regressPlaylist] {
            step(screen)
            for _ in 0 ..< 50 {
                await Task.yield()
            }
        }
        #expect(restored == [entries[1].content, entries[2].content, entries[0].content, entries[2].content])
        #expect(store.get(for: screen.id)?.fitMode == .aspectFit)
        #expect(try WallpaperAutomationCoordinator.hasDemand(#require(store.get(for: screen.id))))
        orchestrator.replaceWallpaperQueue([entries[2], entries[0], entries[1]], for: screen)
        #expect(store.get(for: screen.id)?.playlistCursorIndex == 0)
        orchestrator.suspendForUserAbsence()
        orchestrator.advancePlaylist(for: screen)
        #expect(restored.count == 4)
    }

    @Test(
        "Saving a playlist after previewing a row keeps that row on screen and rotates on from it",
        .timeLimit(.minutes(1)), arguments: [true, false]
    )
    func savingAfterPreviewMovesCursorToPreviewedRow(previewed: Bool) async throws {
        let screen = try Screen(nsScreen: #require(NSScreen.screens.first))
        let entries = (0 ..< 4).map {
            WallpaperQueueEntry(id: "row\($0)", title: "Row \($0)", content: .html(source: .inline("row\($0)"), config: .default))
        }
        var initial = ScreenConfiguration(screenID: screen.id, wallpaper: entries[0].content)
        initial.wallpaperQueue = entries
        initial.playlistCursorIndex = 0
        let store = WallpaperConfigurationStore(persistence: AutomationTestConfigurationPersistence([initial]))
        var restored: [WallpaperContent] = []
        let orchestrator = WallpaperAutomationOrchestrator(
            configurationStore: store, automationCoordinator: WallpaperAutomationCoordinator(),
            playableVideoLoader: FakePlayableVideoLoader(), screensProvider: { [screen] },
            saveConfiguration: { store.save($0) }, recordBookmarkDisplayName: { _, _ in },
            setupPreparedVideoPlayback: { _, _, _, _ in Issue.record("Queue entries must use the common product restore path") },
            restoreProposedConfiguration: { _, proposed in
                restored.append(proposed.activeWallpaper)
                store.save(proposed)
            },
            bumpTransition: { _ in 0 }, isCurrentTransition: { _, _ in true },
            prepareAutomation: { _, proposed, _, intended in
                guard intended() else { return .cancelled }
                restored.append(proposed.activeWallpaper)
                store.save(proposed)
                return .ready
            }, libraryEntryAvailable: { _ in true }
        )
        if previewed {
            orchestrator.previewEntry(entries[2], for: screen)
        }
        let shownBeforeSave = restored.count
        orchestrator.updateAutomation(
            queue: entries, slots: [], mode: .playlist, rotationMinutes: 5, shuffle: false,
            previewedEntryID: previewed ? entries[2].id : nil, for: screen
        )
        #expect(restored.count == shownBeforeSave, "saving reloaded a wallpaper the display already shows")
        #expect(store.get(for: screen.id)?.playlistCursorIndex == (previewed ? 2 : 0))
        orchestrator.advancePlaylist(for: screen)
        for _ in 0 ..< 50 where restored.count == shownBeforeSave {
            await Task.yield()
        }
        #expect(restored.last == entries[previewed ? 3 : 1].content, "the next rotation did not continue after the saved row")
    }

    @Test(
        "Saving a playlist whose previewed row never reached the display keeps the cursor on what is shown",
        .timeLimit(.minutes(1)), arguments: [WallpaperMode.playlist, .libraryShuffle]
    )
    func savingWithUnshownPreviewKeepsCursor(previousMode: WallpaperMode) async throws {
        let screen = try Screen(nsScreen: #require(NSScreen.screens.first))
        let entries = (0 ..< 4).map {
            WallpaperQueueEntry(id: "row\($0)", title: "Row \($0)", content: .html(source: .inline("row\($0)"), config: .default))
        }
        var initial = ScreenConfiguration(screenID: screen.id, wallpaper: entries[0].content)
        initial.wallpaperQueue = entries
        initial.playlistCursorIndex = 0
        initial.wallpaperMode = previousMode
        let store = WallpaperConfigurationStore(persistence: AutomationTestConfigurationPersistence([initial]))
        var restored: [WallpaperContent] = []
        let orchestrator = WallpaperAutomationOrchestrator(
            configurationStore: store, automationCoordinator: WallpaperAutomationCoordinator(),
            playableVideoLoader: FakePlayableVideoLoader(), screensProvider: { [screen] },
            saveConfiguration: { store.save($0) }, recordBookmarkDisplayName: { _, _ in },
            setupPreparedVideoPlayback: { _, _, _, _ in Issue.record("Queue entries must use the common product restore path") },
            restoreProposedConfiguration: { _, proposed in
                restored.append(proposed.activeWallpaper)
                store.save(proposed)
            },
            bumpTransition: { _ in 0 }, isCurrentTransition: { _, _ in true },
            prepareAutomation: { _, proposed, _, intended in
                guard intended() else { return .cancelled }
                restored.append(proposed.activeWallpaper)
                store.save(proposed)
                return .ready
            }, libraryEntryAvailable: { _ in true }
        )
        orchestrator.updateAutomation(
            queue: entries, slots: [], mode: .playlist, rotationMinutes: 5, shuffle: false,
            previewedEntryID: entries[2].id, for: screen
        )
        for _ in 0 ..< 50 {
            await Task.yield()
        }
        let expectedApplied = previousMode == .playlist ? [] : [entries[0].content]
        #expect(restored == expectedApplied, "saving applied the unshown preview instead of the row the old rules pick")
        #expect(store.get(for: screen.id)?.playlistCursorIndex == 0, "the cursor moved to a preview the display never showed")
        let shownBeforeAdvance = restored.count
        orchestrator.advancePlaylist(for: screen)
        for _ in 0 ..< 50 where restored.count == shownBeforeAdvance {
            await Task.yield()
        }
        #expect(restored.last == entries[1].content, "the next rotation stepped on from the unshown preview")
    }

    @Test("Library shuffle follows live membership, skips missing sources and preserves the curated queue")
    func libraryShuffleUsesLiveMembership() async throws {
        let screen = try Screen(nsScreen: #require(NSScreen.screens.first))
        let first = WallpaperQueueEntry(id: "first", title: "First", content: .html(source: .inline("first"), config: .default))
        let second = WallpaperQueueEntry(id: "second", title: "Second", content: .html(source: .inline("second"), config: .default))
        let missing = WallpaperQueueEntry(id: "missing", title: "Missing", content: .video(bookmarkData: Data([99])))
        var initial = ScreenConfiguration(screenID: screen.id, wallpaper: first.content, fitMode: .aspectFit)
        initial.wallpaperMode = .libraryShuffle
        initial.wallpaperQueue = [first]
        initial.playlistRotationMinutes = 120
        let store = WallpaperConfigurationStore(persistence: AutomationTestConfigurationPersistence([initial]))
        let entries = OSAllocatedUnfairLock<[WallpaperQueueEntry]>(initialState: [first, second, missing])
        let liveEntries: @MainActor () -> [LibraryShuffleCandidate] = { entries.withLock { $0 }.map(LibraryShuffleCandidate.init) }
        var restored: [WallpaperContent] = []
        var marks: [AutomaticSwitchMark.Source] = []
        let orchestrator = WallpaperAutomationOrchestrator(
            configurationStore: store, automationCoordinator: WallpaperAutomationCoordinator(),
            playableVideoLoader: FakePlayableVideoLoader(), screensProvider: { [screen] },
            saveConfiguration: { store.save($0) }, recordBookmarkDisplayName: { _, _ in },
            setupPreparedVideoPlayback: { _, _, _, _ in Issue.record("Shuffle must use the common restore path") },
            restoreProposedConfiguration: { _, _ in },
            bumpTransition: { _ in 0 }, isCurrentTransition: { _, _ in true },
            prepareAutomation: { _, proposed, source, intended in
                guard intended() else { return .cancelled }
                restored.append(proposed.activeWallpaper)
                if let source {
                    marks.append(source)
                }
                store.save(proposed)
                return .ready
            },
            libraryEntries: liveEntries, libraryEntryAvailable: { $0.id != "missing" }
        )
        orchestrator.advanceLibraryShuffle(for: screen)
        for _ in 0 ..< 50 where restored.isEmpty {
            await Task.yield()
        }
        #expect(restored == [second.content])
        let third = WallpaperQueueEntry(id: "third", title: "Third", content: .html(source: .inline("third"), config: .default))
        entries.withLock { $0 = [second, third, missing] }
        orchestrator.advanceLibraryShuffle(for: screen)
        for _ in 0 ..< 50 where restored.count < 2 {
            await Task.yield()
        }
        #expect(restored == [second.content, third.content])
        #expect(marks == [.libraryShuffle, .libraryShuffle])
        let saved = try #require(store.get(for: screen.id))
        #expect(saved.wallpaperQueue == [first])
        #expect(saved.playlistRotationMinutes == 120)
        #expect(saved.fitMode == .aspectFit)
        entries.withLock { $0 = [third, missing] }
        orchestrator.advanceLibraryShuffle(for: screen)
        for _ in 0 ..< 50 {
            await Task.yield()
        }
        #expect(restored.count == 2)
        entries.withLock { $0 = [first] }
        orchestrator.advanceLibraryShuffle(for: screen)
        orchestrator.suspendForUserAbsence()
        for _ in 0 ..< 50 {
            await Task.yield()
        }
        #expect(restored.count == 2)
    }

    @Test("Library shuffle has its own timer without needing a playlist")
    func libraryShuffleTimer() async throws {
        let screen = try Screen(nsScreen: #require(NSScreen.screens.first))
        let ticks = AsyncStream<Date>.makeStream()
        let coordinator = WallpaperAutomationCoordinator(tickStreamFactory: { ticks.stream })
        defer { coordinator.stop(); ticks.continuation.finish() }
        var configuration = ScreenConfiguration(screenID: screen.id, videoBookmarkData: Data([1]))
        configuration.wallpaperMode = .libraryShuffle
        configuration.libraryShuffleRotationMinutes = 5
        #expect(WallpaperAutomationCoordinator.hasDemand(configuration))
        var randomSwitches = 0
        var playlistSwitches = 0
        coordinator.start(
            screenProvider: { [screen] }, configurationProvider: { _ in configuration },
            scheduleHandler: { _ in }, playlistHandler: { _ in playlistSwitches += 1 },
            libraryShuffleHandler: { _ in randomSwitches += 1 }, runInitialScheduleCheck: false
        )
        let baseline = Date(timeIntervalSince1970: 1000)
        ticks.continuation.yield(baseline)
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        ticks.continuation.yield(baseline.addingTimeInterval(4 * 60))
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        #expect(randomSwitches == 0)
        ticks.continuation.yield(baseline.addingTimeInterval(5 * 60))
        for _ in 0 ..< 50 where randomSwitches == 0 {
            await Task.yield()
        }
        #expect(randomSwitches == 1)
        #expect(playlistSwitches == 0)
        configuration.libraryShuffleRotationMinutes = 1
        ticks.continuation.yield(baseline.addingTimeInterval(6 * 60))
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        #expect(randomSwitches == 1)
        ticks.continuation.yield(baseline.addingTimeInterval(7 * 60))
        for _ in 0 ..< 50 where randomSwitches < 2 {
            await Task.yield()
        }
        #expect(randomSwitches == 2)
        configuration.wallpaperMode = .playlist
        ticks.continuation.yield(baseline.addingTimeInterval(10 * 60))
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        #expect(randomSwitches == 2)
    }

    @Test("Library shuffle excludes the current content and duplicate entry IDs")
    func libraryShuffleCandidates() {
        let current = WallpaperContent.html(source: .inline("current"), config: .default)
        let next = WallpaperQueueEntry(id: "next", title: "Next", content: .video(bookmarkData: Data([2])))
        #expect(LibraryShufflePolicy.candidates(in: [], excluding: current, origin: nil).isEmpty)
        let entries = [WallpaperQueueEntry(title: "Current", content: current), next, next].map(LibraryShuffleCandidate.init)
        #expect(LibraryShufflePolicy.candidates(in: entries, excluding: current, origin: nil).map(\.resolvedEntry) == [next])
    }

    @Test("A failed automation entry gets exactly one retry, is marked and is skipped on later rotations")
    func automationRetryAndSkip() async throws {
        let screen = try Screen(nsScreen: #require(NSScreen.screens.first))
        let entries = ["current", "bad", "good"].map {
            WallpaperQueueEntry(id: $0, title: $0, content: .html(source: .inline($0), config: .default))
        }
        var initial = ScreenConfiguration(screenID: screen.id, wallpaper: entries[0].content)
        initial.wallpaperQueue = entries
        let store = WallpaperConfigurationStore(persistence: AutomationTestConfigurationPersistence([initial]))
        var attempts: [String] = []
        let orchestrator = WallpaperAutomationOrchestrator(
            configurationStore: store, automationCoordinator: WallpaperAutomationCoordinator(),
            playableVideoLoader: FakePlayableVideoLoader(), screensProvider: { [screen] },
            saveConfiguration: { store.save($0) }, recordBookmarkDisplayName: { _, _ in },
            setupPreparedVideoPlayback: { _, _, _, _ in }, restoreProposedConfiguration: { _, _ in },
            bumpTransition: { _ in 0 }, isCurrentTransition: { _, _ in true },
            prepareAutomation: { _, proposed, _, intended in
                guard intended() else { return .cancelled }
                let id = proposed.activeWallpaper.htmlSource == .inline("bad") ? "bad" : "good"
                attempts.append(id)
                if id == "bad" {
                    return .failed
                }
                store.save(proposed)
                return .ready
            }, libraryEntryAvailable: { _ in true }
        )
        orchestrator.advancePlaylist(for: screen)
        for _ in 0 ..< 100 where attempts.count < 3 {
            await Task.yield()
        }
        #expect(attempts == ["bad", "bad", "good"])
        let marked = try #require(store.get(for: screen.id))
        #expect(marked.automationFailures["bad"]?.entry == entries[1])
        #expect(marked.playlistCursorIndex == 2)
        var reset = marked
        reset.activeWallpaper = entries[0].content
        reset.playlistCursorIndex = 0
        store.save(reset)
        orchestrator.advancePlaylist(for: screen)
        for _ in 0 ..< 100 where attempts.count < 4 {
            await Task.yield()
        }
        #expect(attempts == ["bad", "bad", "good", "good"])
        reset.automationFailures = [:]
        store.save(reset)
        orchestrator.advancePlaylist(for: screen)
        for _ in 0 ..< 100 where attempts.count < 7 {
            await Task.yield()
        }
        #expect(attempts.suffix(3) == ["bad", "bad", "good"])
        orchestrator.stopMonitoring()
    }

    @Test("A skipped source records why: missing source, failed load or timeout", arguments: [
        (true, WallpaperPreparationResult.failed, WallpaperAutomationFailure.Reason.loadFailed),
        (true, .timedOut, .timedOut),
        (false, .ready, .sourceMissing),
    ])
    func automationSkipRecordsReason(available: Bool, result: WallpaperPreparationResult, reason: WallpaperAutomationFailure.Reason) async throws {
        let screen = try Screen(nsScreen: #require(NSScreen.screens.first))
        let entries = ["current", "bad"].map {
            WallpaperQueueEntry(id: $0, title: $0, content: .html(source: .inline($0), config: .default))
        }
        var initial = ScreenConfiguration(screenID: screen.id, wallpaper: entries[0].content)
        initial.wallpaperQueue = entries
        let store = WallpaperConfigurationStore(persistence: AutomationTestConfigurationPersistence([initial]))
        let orchestrator = WallpaperAutomationOrchestrator(
            configurationStore: store, automationCoordinator: WallpaperAutomationCoordinator(),
            playableVideoLoader: FakePlayableVideoLoader(), screensProvider: { [screen] },
            saveConfiguration: { store.save($0) }, recordBookmarkDisplayName: { _, _ in },
            setupPreparedVideoPlayback: { _, _, _, _ in }, restoreProposedConfiguration: { _, _ in },
            bumpTransition: { _ in 0 }, isCurrentTransition: { _, _ in true },
            prepareAutomation: { _, _, _, intended in intended() ? result : .cancelled },
            libraryEntryAvailable: { _ in available }
        )
        orchestrator.advancePlaylist(for: screen)
        for _ in 0 ..< 200 where store.get(for: screen.id)?.automationFailures["bad"] == nil {
            await Task.yield()
        }
        #expect(store.get(for: screen.id)?.automationFailures["bad"]?.reason == reason)
        orchestrator.stopMonitoring()
    }

    @Test("A missing source on an offline volume is skipped this round without being recorded", arguments: [true, false])
    func automationSkipsOfflineVolumeWithoutRecording(volumeUnavailable: Bool) async throws {
        let screen = try Screen(nsScreen: #require(NSScreen.screens.first))
        let badBookmark = Data("bad".utf8)
        let entries = [
            WallpaperQueueEntry(id: "current", title: "current", content: .html(source: .inline("current"), config: .default)),
            WallpaperQueueEntry(id: "bad", title: "bad", content: .video(bookmarkData: badBookmark)),
            WallpaperQueueEntry(id: "good", title: "good", content: .html(source: .inline("good"), config: .default)),
        ]
        var initial = ScreenConfiguration(screenID: screen.id, wallpaper: entries[0].content)
        initial.wallpaperQueue = entries
        let store = WallpaperConfigurationStore(persistence: AutomationTestConfigurationPersistence([initial]))
        var checkedBookmarks: [Data] = []
        let orchestrator = WallpaperAutomationOrchestrator(
            configurationStore: store, automationCoordinator: WallpaperAutomationCoordinator(),
            playableVideoLoader: FakePlayableVideoLoader(), screensProvider: { [screen] },
            saveConfiguration: { store.save($0) }, recordBookmarkDisplayName: { _, _ in },
            setupPreparedVideoPlayback: { _, _, _, _ in }, restoreProposedConfiguration: { _, _ in },
            bumpTransition: { _ in 0 }, isCurrentTransition: { _, _ in true },
            prepareAutomation: { _, proposed, _, intended in
                guard intended() else { return .cancelled }
                store.save(proposed)
                return .ready
            },
            libraryEntryAvailable: { $0.id != "bad" },
            bookmarkVolumeUnavailable: { data in
                checkedBookmarks.append(data)
                return volumeUnavailable
            }
        )
        orchestrator.advancePlaylist(for: screen)
        for _ in 0 ..< 200 where store.get(for: screen.id)?.activeWallpaper != entries[2].content {
            await Task.yield()
        }
        let result = try #require(store.get(for: screen.id))
        #expect(result.activeWallpaper == entries[2].content)
        #expect(checkedBookmarks == [badBookmark])
        #expect(result.automationFailures["bad"]?.reason == (volumeUnavailable ? nil : .sourceMissing))
        orchestrator.stopMonitoring()
    }

    @Test("A scene whose source folder sits on an offline volume is skipped this round without being recorded")
    func automationSkipsOfflineSceneVolumeWithoutRecording() async throws {
        let screen = try Screen(nsScreen: #require(NSScreen.screens.first))
        let folderBookmark = Data("steam-library".utf8)
        let origin = WPEOrigin(
            workshopID: "7", title: "Scene", originalType: .scene, sourceFolderBookmark: folderBookmark,
            cacheRelativePath: nil, previewFileName: nil
        )
        let scene = WallpaperContent.scene(SceneDescriptor(
            workshopID: "7", cacheRelativePath: "7", entryFile: "scene.json", capabilityTier: .imageOnly
        ))
        let entries = [
            WallpaperQueueEntry(id: "current", title: "current", content: .html(source: .inline("current"), config: .default)),
            WallpaperQueueEntry(id: "bad", title: "bad", content: scene, origin: origin),
            WallpaperQueueEntry(id: "good", title: "good", content: .html(source: .inline("good"), config: .default)),
        ]
        var initial = ScreenConfiguration(screenID: screen.id, wallpaper: entries[0].content)
        initial.wallpaperQueue = entries
        let store = WallpaperConfigurationStore(persistence: AutomationTestConfigurationPersistence([initial]))
        var checkedBookmarks: [Data] = []
        let orchestrator = WallpaperAutomationOrchestrator(
            configurationStore: store, automationCoordinator: WallpaperAutomationCoordinator(),
            playableVideoLoader: FakePlayableVideoLoader(), screensProvider: { [screen] },
            saveConfiguration: { store.save($0) }, recordBookmarkDisplayName: { _, _ in },
            setupPreparedVideoPlayback: { _, _, _, _ in }, restoreProposedConfiguration: { _, _ in },
            bumpTransition: { _ in 0 }, isCurrentTransition: { _, _ in true },
            prepareAutomation: { _, proposed, _, intended in
                guard intended() else { return .cancelled }
                store.save(proposed)
                return .ready
            },
            libraryEntryAvailable: { $0.id != "bad" },
            bookmarkVolumeUnavailable: { data in
                checkedBookmarks.append(data)
                return true
            }
        )
        orchestrator.advancePlaylist(for: screen)
        for _ in 0 ..< 200 where store.get(for: screen.id)?.activeWallpaper != entries[2].content {
            await Task.yield()
        }
        let result = try #require(store.get(for: screen.id))
        #expect(result.activeWallpaper == entries[2].content)
        #expect(checkedBookmarks == [folderBookmark])
        #expect(result.automationFailures["bad"] == nil)
        orchestrator.stopMonitoring()
    }

    @Test("A successful retry is not marked, and cancelling a pending load never marks or retries it")
    func automationRetrySuccessAndCancellation() async throws {
        let screen = try Screen(nsScreen: #require(NSScreen.screens.first))
        let entry = WallpaperQueueEntry(id: "next", title: "Next", content: .html(source: .inline("next"), config: .default))
        var initial = ScreenConfiguration(screenID: screen.id, wallpaper: .html(source: .inline("current"), config: .default))
        initial.wallpaperMode = .libraryShuffle
        let store = WallpaperConfigurationStore(persistence: AutomationTestConfigurationPersistence([initial]))
        var attempts = 0
        var pending: CheckedContinuation<WallpaperPreparationResult, Never>?
        let hold = OSAllocatedUnfairLock(initialState: false)
        let orchestrator = WallpaperAutomationOrchestrator(
            configurationStore: store, automationCoordinator: WallpaperAutomationCoordinator(),
            playableVideoLoader: FakePlayableVideoLoader(), screensProvider: { [screen] },
            saveConfiguration: { store.save($0) }, recordBookmarkDisplayName: { _, _ in },
            setupPreparedVideoPlayback: { _, _, _, _ in }, restoreProposedConfiguration: { _, _ in },
            bumpTransition: { _ in 0 }, isCurrentTransition: { _, _ in true },
            prepareAutomation: { _, proposed, _, intended in
                attempts += 1
                if hold.withLock({ $0 }) {
                    return await withCheckedContinuation { pending = $0 }
                }
                if attempts == 1 {
                    return .failed
                }
                guard intended() else { return .cancelled }
                store.save(proposed)
                return .ready
            }, libraryEntries: { [LibraryShuffleCandidate(entry)] }, libraryEntryAvailable: { _ in true }
        )
        orchestrator.advanceLibraryShuffle(for: screen)
        for _ in 0 ..< 100 where attempts < 2 {
            await Task.yield()
        }
        #expect(attempts == 2)
        #expect(store.get(for: screen.id)?.automationFailures.isEmpty == true)
        store.save(initial)
        hold.withLock { $0 = true }
        orchestrator.advanceLibraryShuffle(for: screen)
        for _ in 0 ..< 100 where pending == nil {
            await Task.yield()
        }
        #expect(pending != nil)
        orchestrator.suspendForUserAbsence()
        pending?.resume(returning: .cancelled)
        for _ in 0 ..< 50 {
            await Task.yield()
        }
        #expect(attempts == 3)
        #expect(store.get(for: screen.id)?.automationFailures.isEmpty == true)
        #expect(store.get(for: screen.id)?.activeWallpaper == initial.activeWallpaper)
    }

    @Test("The one shared automation task is released and stream cancellation drains on stop")
    func automationClockIsReleased() async throws {
        let screen = try Screen(nsScreen: #require(NSScreen.screens.first))
        var config = ScreenConfiguration(screenID: screen.id, videoBookmarkData: Data([1]))
        config.wallpaperMode = .libraryShuffle
        let ticks = AsyncStream<Date>.makeStream()
        var coordinator: WallpaperAutomationCoordinator? = WallpaperAutomationCoordinator(tickStreamFactory: { ticks.stream })
        weak let weakCoordinator = coordinator
        coordinator?.start(screenProvider: { [screen] }, configurationProvider: { _ in config },
                           scheduleHandler: { _ in }, playlistHandler: { _ in }, runInitialScheduleCheck: false)
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        #expect(coordinator?.taskStartCountForTesting == 1)
        coordinator = nil
        for _ in 0 ..< 50 {
            await Task.yield()
        }
        #expect(weakCoordinator == nil)
        ticks.continuation.finish()
    }

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

    private static let dayPage = WallpaperQueueEntry(title: "Day", content: .html(source: .inline("day"), config: .default))
    private static let eveningPage = WallpaperQueueEntry(title: "Evening", content: .html(source: .inline("evening"), config: .default))
    private static let fallbackVideo = WallpaperQueueEntry(title: "Fallback", content: .video(bookmarkData: Data([9])))

    private static func plannedConfiguration(for screen: Screen) -> ScreenConfiguration {
        var config = ScreenConfiguration(screenID: screen.id, wallpaper: fallbackVideo.content)
        config.wallpaperMode = .schedule
        config.scheduleFallback = fallbackVideo
        config.scheduleSlots = [
            ScheduleSlot(startHour: 12, endHour: 18, label: "Day", wallpaper: dayPage),
            ScheduleSlot(startHour: 18, endHour: 22, label: "Evening", wallpaper: eveningPage),
        ]
        return config
    }

    private static func scheduleOrchestrator(
        store: WallpaperConfigurationStore,
        screen: Screen,
        clock: @escaping @MainActor () -> Date,
        bump: @escaping @MainActor (CGDirectDisplayID) -> Int = { _ in 0 },
        note: @escaping @MainActor (Screen, AutomaticSwitchMark.Source) -> Void = { _, _ in },
        restore: @escaping @MainActor (Screen, ScreenConfiguration) -> Void
    ) -> WallpaperAutomationOrchestrator {
        WallpaperAutomationOrchestrator(
            configurationStore: store, automationCoordinator: WallpaperAutomationCoordinator(),
            playableVideoLoader: FakePlayableVideoLoader(), screensProvider: { [screen] },
            saveConfiguration: { store.save($0) }, recordBookmarkDisplayName: { _, _ in },
            setupPreparedVideoPlayback: { _, _, _, _ in }, restoreProposedConfiguration: restore,
            bumpTransition: bump, isCurrentTransition: { _, _ in true }, now: clock,
            prepareAutomation: { screen, proposed, source, intended in
                guard intended() else { return .cancelled }
                if let source {
                    note(screen, source)
                }
                restore(screen, proposed)
                return .ready
            }, libraryEntryAvailable: { _ in true }
        )
    }

    /// Automatic switches run on the orchestrator's selection task.
    private static func settle() async {
        for _ in 0 ..< 50 {
            await Task.yield()
        }
    }

    @Test("A schedule switch and a playlist step mark the display; a schedule check that changes nothing does not")
    func automaticSwitchesMarkTheDisplay() async throws {
        let screen = try Screen(nsScreen: #require(NSScreen.screens.first))
        let store = WallpaperConfigurationStore(persistence: AutomationTestConfigurationPersistence([Self.plannedConfiguration(for: screen)]))
        var marks: [AutomaticSwitchMark.Source] = []
        let orchestrator = Self.scheduleOrchestrator(
            store: store, screen: screen, clock: { automationTime(12, 0, 30) },
            note: { _, source in marks.append(source) },
            restore: { _, config in store.save(config) }
        )
        orchestrator.checkAndApplySchedule(for: screen)
        await Self.settle()
        #expect(marks == [.schedule])
        orchestrator.checkAndApplySchedule(for: screen, force: true)
        await Self.settle()
        #expect(marks == [.schedule], "a check that left the display alone marked it")

        var queued = try #require(store.get(for: screen.id))
        queued.wallpaperMode = .playlist
        queued.wallpaperQueue = [Self.dayPage, Self.eveningPage]
        store.save(queued)
        orchestrator.advancePlaylist(for: screen)
        await Self.settle()
        #expect(marks == [.schedule, .playlist])
    }

    @Test("A schedule check that finds the planned wallpaper already showing leaves the configuration revision alone")
    func settledScheduleCheckKeepsRevision() throws {
        let screen = try Screen(nsScreen: #require(NSScreen.screens.first))
        var showingPlan = Self.plannedConfiguration(for: screen).applyingAutomationEntry(Self.dayPage)
        showingPlan.displayFingerprint = screen.displayFingerprint
        let store = WallpaperConfigurationStore(persistence: AutomationTestConfigurationPersistence([showingPlan]))
        var restores = 0
        let orchestrator = Self.scheduleOrchestrator(
            store: store, screen: screen, clock: { automationTime(12, 0, 30) },
            restore: { _, _ in restores += 1 }
        )
        let revision = store.revision(for: screen.id)
        orchestrator.checkAndApplySchedule(for: screen)
        #expect(restores == 0)
        #expect(store.revision(for: screen.id) == revision, "a check with nothing to switch invalidated the restore candidate in flight")
    }

    private static func pickByHand(on screen: Screen, in store: WallpaperConfigurationStore) throws {
        var picked = try #require(store.get(for: screen.id))
        picked.activeWallpaper = .html(source: .inline("picked"), config: .default)
        store.save(picked)
    }

    @Test("A hand-picked wallpaper holds until the next slot starts, and a failed apply is not retried within its slot")
    func manualPickHoldsUntilNextSlot() async throws {
        let screen = try Screen(nsScreen: #require(NSScreen.screens.first))
        let store = WallpaperConfigurationStore(persistence: AutomationTestConfigurationPersistence([Self.plannedConfiguration(for: screen)]))
        var clock = automationTime(12, 0, 30)
        var restored: [WallpaperContent] = []
        let orchestrator = Self.scheduleOrchestrator(store: store, screen: screen, clock: { clock }, restore: { _, config in
            restored.append(config.activeWallpaper)
            store.save(config)
        })

        orchestrator.checkAndApplySchedule(for: screen)
        await Self.settle()
        #expect(restored == [Self.dayPage.content])
        try Self.pickByHand(on: screen, in: store)
        clock = automationTime(13, 5)
        orchestrator.checkAndApplySchedule(for: screen)
        await Self.settle()
        #expect(restored.count == 1)
        #expect(try SchedulePolicy.pausedUntil(for: #require(store.get(for: screen.id)), now: clock, calendar: .current) == automationTime(18))

        clock = automationTime(18, 0, 30)
        orchestrator.checkAndApplySchedule(for: screen)
        await Self.settle()
        #expect(restored.last == Self.eveningPage.content)
        #expect(try SchedulePolicy.pausedUntil(for: #require(store.get(for: screen.id)), now: clock, calendar: .current) == nil)

        let failing = Self.scheduleOrchestrator(store: store, screen: screen, clock: { clock }, restore: { _, config in
            restored.append(config.activeWallpaper)
        })
        clock = automationTime(22, 0, 30)
        failing.checkAndApplySchedule(for: screen)
        await Self.settle()
        clock = automationTime(22, 1, 30)
        failing.checkAndApplySchedule(for: screen)
        await Self.settle()
        #expect(restored.count == 3)
    }

    @Test("A hold survives a relaunch, and a check while the user is away leaves the slot unsettled")
    func pauseSurvivesRelaunchAndAbsence() async throws {
        let screen = try Screen(nsScreen: #require(NSScreen.screens.first))
        let store = WallpaperConfigurationStore(persistence: AutomationTestConfigurationPersistence([Self.plannedConfiguration(for: screen)]))
        var clock = automationTime(12, 0, 30)
        let first = Self.scheduleOrchestrator(store: store, screen: screen, clock: { clock }, restore: { _, config in store.save(config) })
        first.checkAndApplySchedule(for: screen)
        await Self.settle()
        try Self.pickByHand(on: screen, in: store)

        clock = automationTime(14)
        var restored: [WallpaperContent] = []
        let relaunched = Self.scheduleOrchestrator(store: store, screen: screen, clock: { clock }, restore: { _, config in
            restored.append(config.activeWallpaper)
            store.save(config)
        })
        relaunched.startMonitoring()
        await Self.settle()
        #expect(restored.isEmpty)

        relaunched.suspendForUserAbsence()
        clock = automationTime(18, 0, 30)
        let settled = store.get(for: screen.id)?.scheduleSettledUntil
        relaunched.checkAndApplySchedule(for: screen)
        #expect(store.get(for: screen.id)?.scheduleSettledUntil == settled)
        relaunched.resumeAfterUserAbsence()
        await Self.settle()
        relaunched.stopMonitoring()
        #expect(restored == [Self.eveningPage.content])
    }

    @Test("Resuming and editing the plan apply the current slot at once")
    func resumeAndPlanEditsApplyNow() async throws {
        let screen = try Screen(nsScreen: #require(NSScreen.screens.first))
        let store = WallpaperConfigurationStore(persistence: AutomationTestConfigurationPersistence([Self.plannedConfiguration(for: screen)]))
        var clock = automationTime(12, 0, 30)
        var restored: [WallpaperContent] = []
        let orchestrator = Self.scheduleOrchestrator(store: store, screen: screen, clock: { clock }, restore: { _, config in
            restored.append(config.activeWallpaper)
            store.save(config)
        })
        orchestrator.checkAndApplySchedule(for: screen)
        await Self.settle()

        try Self.pickByHand(on: screen, in: store)
        clock = automationTime(13, 10)
        orchestrator.checkAndApplySchedule(for: screen, force: true)
        await Self.settle()
        #expect(restored == [Self.dayPage.content, Self.dayPage.content])

        try Self.pickByHand(on: screen, in: store)
        let slots = try #require(store.get(for: screen.id)?.scheduleSlots)
        orchestrator.updateAutomation(queue: [], slots: slots, mode: .schedule, rotationMinutes: nil, shuffle: false, for: screen)
        await Self.settle()
        #expect(restored.count == 3)
    }

    @Test("A hand-picked page holds through an old video-only slot", .timeLimit(.minutes(1)))
    func legacyVideoSlotKeepsManualWeb() async throws {
        let screen = try Screen(nsScreen: #require(NSScreen.screens.first))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("schedule-legacy-\(UUID().uuidString).mp4")
        try Data([0x00, 0x01]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        var config = ScreenConfiguration(screenID: screen.id, videoBookmarkData: Data([0x01]))
        config.wallpaperMode = .schedule
        config.scheduleSlots = [ScheduleSlot(startHour: 6, endHour: 12, videoBookmarkData: bookmark, label: "Morning")]
        let store = WallpaperConfigurationStore(persistence: AutomationTestConfigurationPersistence([config]))
        var clock = automationTime(6, 0, 30)
        var transitions = 0
        var commits = 0
        let orchestrator = Self.scheduleOrchestrator(
            store: store, screen: screen, clock: { clock },
            bump: { _ in
                transitions += 1
                return transitions
            },
            restore: { _, proposed in
                store.save(proposed)
                commits += 1
            }
        )

        orchestrator.checkAndApplySchedule(for: screen)
        for _ in 0 ..< 50 where commits == 0 {
            await Task.yield()
        }
        #expect(commits == 1)
        try Self.pickByHand(on: screen, in: store)
        clock = automationTime(8)
        orchestrator.checkAndApplySchedule(for: screen)
        await Self.settle()
        #expect(transitions == 1)
    }

    @Test("A web settings edit is written back to the current slot's entry")
    func htmlEditWritesBackToCurrentEntry() throws {
        let screen = try Screen(nsScreen: #require(NSScreen.screens.first))
        let page = WallpaperQueueEntry(title: "Page", content: .html(source: .inline("page"), config: .default))
        var config = ScreenConfiguration(screenID: screen.id, wallpaper: page.content)
        config.wallpaperMode = .schedule
        config.scheduleSlots = [ScheduleSlot(startHour: 0, endHour: 24, label: "All day", wallpaper: page)]
        let store = WallpaperConfigurationStore(persistence: AutomationTestConfigurationPersistence([config]))
        let coordinator = HTMLWallpaperCoordinator(
            configurationStore: store, screensProvider: { [screen] }, saveConfiguration: { store.save($0) },
            restoreWallpaperSession: { _, _, _, beforeCommit in _ = beforeCommit() },
            notifyWallpaperSessionChanged: {}, originReconciler: PreservingOriginReconciler()
        )
        var louder = HTMLConfig.default
        louder.audioVolume = 0.3

        coordinator.updateConfig(louder, for: screen)

        #expect(store.get(for: screen.id)?.scheduleSlots?.first?.wallpaper?.content == .html(source: .inline("page"), config: louder))
    }

    @Test("A scene edit is written back to the current slot's entry")
    func sceneEditWritesBackToCurrentEntry() {
        let scene = SceneDescriptor(workshopID: "42", cacheRelativePath: "wpe-cache/42", entryFile: "scene.json", capabilityTier: .imageOnly)
        let entry = WallpaperQueueEntry(title: "Scene", content: .scene(scene))
        var config = ScreenConfiguration(screenID: 1, wallpaper: entry.content)
        config.wallpaperMode = .schedule
        config.scheduleSlots = [ScheduleSlot(startHour: 0, endHour: 24, label: "All day", wallpaper: entry)]
        let edited = scene.withPropertyOverrides(["gain": .number(0.5)])

        let written = SchedulePolicy.writingBack(.scene(edited), into: config, now: automationTime(13), calendar: .current)

        #expect(written.scheduleSlots?.first?.wallpaper?.content == .scene(edited))
        #expect(written.scheduleSlots?.first?.wallpaper?.id == entry.id)
    }

    @Test("A scene edit is written back to the fallback when the plan has no slots")
    func sceneEditWritesBackToFallbackWithoutSlots() {
        let scene = SceneDescriptor(workshopID: "42", cacheRelativePath: "wpe-cache/42", entryFile: "scene.json", capabilityTier: .imageOnly)
        let entry = WallpaperQueueEntry(title: "Scene", content: .scene(scene))
        var config = ScreenConfiguration(screenID: 1, wallpaper: entry.content)
        config.wallpaperMode = .schedule
        config.scheduleSlots = nil
        config.scheduleFallback = entry
        let edited = scene.withPropertyOverrides(["gain": .number(0.5)])

        let written = SchedulePolicy.writingBack(.scene(edited), into: config, now: automationTime(13), calendar: .current)

        #expect(written.scheduleFallback?.content == .scene(edited))
        #expect(written.scheduleFallback?.id == entry.id)
        #expect(written.scheduleSlots == nil)
    }

    @Test("Both save paths claim an unsettled slot for a hand-picked wallpaper")
    func bothSaveFunnelsClaimUnsettledSlot() throws {
        let screen = Screen(nsScreen: AutomationTestNSScreen(displayID: 0xA170_0001))
        let manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false, startAutomation: false,
            powerMonitor: FakePowerMonitor(), fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(), displayRegistry: FakeDisplayRegistry(screens: [screen]),
            featureCatalog: FeatureCatalog(capabilities: .lite), originReconciler: PreservingOriginReconciler()
        ))
        defer { manager.clearWallpaperForScreen(screen) }
        let planned = WallpaperQueueEntry(title: "Planned", content: .html(source: .inline("planned"), config: .default))
        var unsettled = ScreenConfiguration(screenID: screen.id, wallpaper: planned.content)
        unsettled.wallpaperMode = .schedule
        unsettled.scheduleSlots = [ScheduleSlot(startHour: 0, endHour: 24, label: "All day", wallpaper: planned)]
        unsettled.scheduleSettledUntil = Date(timeIntervalSinceNow: -3600)
        var picked = unsettled

        picked.activeWallpaper = .html(source: .inline("picked"), config: .default)
        manager.configurationStore.save(unsettled)
        manager.saveConfiguration(picked)
        let viaManager = try #require(manager.configurationStore.get(for: screen.id)?.scheduleSettledUntil)

        picked.activeWallpaper = .video(bookmarkData: Data([7]))
        manager.configurationStore.save(unsettled)
        manager.playbackCoordinator.save(picked)
        let viaPlayback = try #require(manager.configurationStore.get(for: screen.id)?.scheduleSettledUntil)

        for settled in [viaManager, viaPlayback] {
            #expect(settled > Date() && settled <= Date(timeIntervalSinceNow: 86400))
        }
    }

    @Test("A preview shows an entry without saving the list or moving the cursor")
    func previewShowsAnEntryWithoutSavingTheList() throws {
        let screen = try Screen(nsScreen: #require(NSScreen.screens.first))
        let saved = [Self.dayPage, Self.eveningPage]
        var config = ScreenConfiguration(screenID: screen.id, wallpaper: saved[1].content)
        config.wallpaperQueue = saved
        config.playlistCursorIndex = 1
        let store = WallpaperConfigurationStore(persistence: AutomationTestConfigurationPersistence([config]))
        var restored: [WallpaperContent] = []
        let orchestrator = Self.scheduleOrchestrator(store: store, screen: screen, clock: { automationTime(12) }, restore: { _, proposed in
            restored.append(proposed.activeWallpaper)
            store.save(proposed)
        })
        let draft = WallpaperQueueEntry(title: "Draft", content: .html(source: .inline("draft"), config: .default))

        orchestrator.previewEntry(draft, for: screen)
        #expect(restored == [draft.content])
        #expect(store.get(for: screen.id)?.wallpaperQueue == saved)
        #expect(store.get(for: screen.id)?.playlistCursorIndex == 1)

        orchestrator.previewEntry(saved[0], for: screen)
        #expect(restored == [draft.content, saved[0].content])
        #expect(store.get(for: screen.id)?.playlistCursorIndex == 1)
    }

    @Test("Cancelling a trial puts back the remembered page as well as what was on screen")
    func cancelledTrialKeepsRememberedPage() throws {
        let screen = Screen(nsScreen: AutomationTestNSScreen(displayID: 0xA170_0002))
        let manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false, startAutomation: false,
            powerMonitor: FakePowerMonitor(), fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(), displayRegistry: FakeDisplayRegistry(screens: [screen]),
            featureCatalog: FeatureCatalog(capabilities: .lite), originReconciler: PreservingOriginReconciler()
        ))
        manager.wallpapersGloballyEnabled = false
        defer { manager.clearWallpaperForScreen(screen) }
        var showing = ScreenConfiguration(screenID: screen.id, wallpaper: .video(bookmarkData: Data([7])))
        showing.savedHTMLSource = .inline("P")
        manager.configurationStore.save(showing)
        let trial = WallpaperQueueEntry(title: "Q", content: .html(source: .inline("Q"), config: .default))
        var shownBeforeTrial: ScreenConfiguration?

        WallpaperAutomationSheet.startTrial(trial, shownBeforeTrial: &shownBeforeTrial, manager: manager, screen: screen)
        #expect(manager.getConfiguration(for: screen)?.activeWallpaper == trial.content)
        WallpaperAutomationSheet.cancelTrial(restoring: shownBeforeTrial, manager: manager, screen: screen)

        let restored = try #require(manager.getConfiguration(for: screen))
        #expect(restored.activeWallpaper == showing.activeWallpaper)
        #expect(restored.savedHTMLSource == .inline("P"))
    }

    @Test("A preview overtaken by an automatic switch is not put back on Cancel")
    func cancelAfterAutomaticSwitchKeepsTheSwitch() {
        let screen = Screen(nsScreen: AutomationTestNSScreen(displayID: 0xA170_0003))
        let manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false, startAutomation: false,
            powerMonitor: FakePowerMonitor(), fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(), displayRegistry: FakeDisplayRegistry(screens: [screen]),
            featureCatalog: FeatureCatalog(capabilities: .lite), originReconciler: PreservingOriginReconciler()
        ))
        manager.wallpapersGloballyEnabled = false
        defer { manager.clearWallpaperForScreen(screen) }
        manager.configurationStore.save(ScreenConfiguration(screenID: screen.id, wallpaper: .video(bookmarkData: Data([7]))))
        let trial = WallpaperQueueEntry(title: "Q", content: .html(source: .inline("Q"), config: .default))
        var shownBeforeTrial: ScreenConfiguration?
        var preview: (entryID: WallpaperQueueEntry.ID, switchSerial: Int?)? = (trial.id, manager.automaticSwitchMark(for: screen.displayFingerprint)?.serial)
        WallpaperAutomationSheet.startTrial(trial, shownBeforeTrial: &shownBeforeTrial, manager: manager, screen: screen)

        let switched = ScreenConfiguration(screenID: screen.id, wallpaper: .video(bookmarkData: Data([8])))
        manager.configurationStore.save(switched)
        manager.noteAutomaticSwitch(on: screen, source: .schedule)
        WallpaperAutomationSheet.endTrialIfSwitched(
            &preview, shownBeforeTrial: &shownBeforeTrial, currentSerial: manager.automaticSwitchMark(for: screen.displayFingerprint)?.serial
        )
        WallpaperAutomationSheet.cancelTrial(restoring: shownBeforeTrial, manager: manager, screen: screen)

        #expect(preview == nil)
        #expect(manager.getConfiguration(for: screen)?.activeWallpaper == switched.activeWallpaper, "Cancel put back what was showing before the automatic switch")
    }

    @Test("Removing the playing row plays the row that takes its place; removing another row leaves the display alone")
    func removingPlayingRowPlaysItsSuccessor() async throws {
        let screen = try Screen(nsScreen: #require(NSScreen.screens.first))
        let rows = ["A", "B", "C"].map { WallpaperQueueEntry(id: $0, title: $0, content: .html(source: .inline($0), config: .default)) }
        func run(saving queue: [WallpaperQueueEntry]) async -> (restored: [WallpaperContent], cursor: Int?) {
            var config = ScreenConfiguration(screenID: screen.id, wallpaper: rows[0].content)
            config.wallpaperQueue = rows
            config.playlistCursorIndex = 0
            let store = WallpaperConfigurationStore(persistence: AutomationTestConfigurationPersistence([config]))
            var restored: [WallpaperContent] = []
            let orchestrator = Self.scheduleOrchestrator(store: store, screen: screen, clock: { automationTime(12) }, restore: { _, proposed in
                restored.append(proposed.activeWallpaper)
                store.save(proposed)
            })
            orchestrator.updateAutomation(queue: queue, slots: [], mode: .playlist, rotationMinutes: nil, shuffle: false, for: screen)
            await Self.settle()
            return (restored, store.get(for: screen.id)?.playlistCursorIndex)
        }

        let removedPlaying = await run(saving: [rows[1], rows[2]])
        #expect(removedPlaying.restored == [rows[1].content], "the removed row kept playing")
        #expect(removedPlaying.cursor == 0)
        let removedOther = await run(saving: [rows[0], rows[2]])
        #expect(removedOther.restored.isEmpty, "removing a row that was not playing changed the display")
        #expect(removedOther.cursor == 0)
    }

    @Test("Clearing every slot fills the day with the unscheduled-hours wallpaper at once")
    func clearedSlotsApplyFallback() async throws {
        let screen = try Screen(nsScreen: #require(NSScreen.screens.first))
        var planned = Self.plannedConfiguration(for: screen)
        planned.activeWallpaper = Self.dayPage.content
        let store = WallpaperConfigurationStore(persistence: AutomationTestConfigurationPersistence([planned]))
        var restored: [WallpaperContent] = []
        let orchestrator = Self.scheduleOrchestrator(store: store, screen: screen, clock: { automationTime(13) }, restore: { _, proposed in
            restored.append(proposed.activeWallpaper)
            store.save(proposed)
        })

        orchestrator.updateAutomation(queue: [], slots: [], mode: .schedule, rotationMinutes: nil, shuffle: false, for: screen)
        await Self.settle()

        #expect(restored == [Self.fallbackVideo.content])
    }

    @Test("Picking a library item again takes back only the entry that pick added")
    func pickerTogglesOnlyItsOwnAdditions() {
        func item(_ label: String) -> LiveWallpaper.LibraryItem {
            let bookmark = WallpaperBookmark(label: label, content: .html(source: .inline(label), config: .default))
            return LiveWallpaper.LibraryItem(
                id: "bookmark:\(bookmark.id)", title: label, kind: .web, source: .bookmark(bookmark),
                isSteam: false, createdAt: bookmark.createdAt, lastUsedAt: nil, onDisplays: [],
                thumbnail: nil, metadata: nil, isVariant: false, parentID: nil, isSupported: true
            )
        }
        let (first, second) = (item("A"), item("B"))
        var queue = [WallpaperQueueEntry(title: "X", content: .video(bookmarkData: Data([1])))]
        var added: [LiveWallpaper.LibraryItem.ID: WallpaperQueueEntry.ID] = [:]

        for picked in [first, second, first] {
            #expect(WallpaperAutomationSheet.togglePick(picked, queue: &queue, added: &added))
        }

        #expect(queue.map(\.title) == ["X", "B"])
        #expect(Array(added.keys) == [second.id])
        #expect(added[second.id] == queue.last?.id)
    }

    @Test("Chosen video files become entries in panel order; a file without a bookmark is counted, not added")
    func chosenVideoFilesBecomeEntriesInOrder() {
        let urls = ["a.mp4", "broken.mp4", "b.mov"].map { URL(fileURLWithPath: "/tmp/\($0)") }

        let chosen = WallpaperQueueEntry.videoFiles(urls) { url in
            url.lastPathComponent == "broken.mp4" ? nil : Data(url.lastPathComponent.utf8)
        }

        #expect(chosen.entries.map(\.title) == ["a.mp4", "b.mov"])
        #expect(chosen.entries.map(\.content) == [.video(bookmarkData: Data("a.mp4".utf8)), .video(bookmarkData: Data("b.mov".utf8))])
        #expect(chosen.failed == 1)
    }

    @Test("The end picker shows a stored midnight 0 as 24:00 and writes a choice back unchanged")
    func endPickerShowsStoredMidnightAsTwentyFour() {
        var stored = 0
        let end = WallpaperAutomationSheet.endHourBinding(Binding(get: { stored }, set: { stored = $0 }))

        #expect(end.wrappedValue == 24)
        end.wrappedValue = 6
        #expect(stored == 6)

        stored = 18
        #expect(end.wrappedValue == 18)
    }

    @Test("The playing row is the saved queue's cursor entry, only while the playlist runs")
    func playingRowIsTheSavedQueuesCursorEntry() {
        let queue = ["A", "B", "C"].map { WallpaperQueueEntry(title: $0, content: .html(source: .inline($0), config: .default)) }
        var playlist = ScreenConfiguration(screenID: 1, wallpaper: queue[2].content)
        playlist.wallpaperQueue = queue
        playlist.playlistCursorIndex = 2
        var schedule = playlist
        schedule.wallpaperMode = .schedule
        let unqueued = ScreenConfiguration(screenID: 1, wallpaper: .html(source: .inline("current"), config: .default))
        let legacy = ScreenConfiguration(screenID: 1, videoBookmarkData: Data([1]), playlistBookmarks: [Data([2]), Data([3])], playlistCursorIndex: 1)

        #expect(WallpaperAutomationSheet.nowPlayingEntryID(in: playlist, insertedCurrent: nil, previewing: nil) == queue[2].id)
        #expect(WallpaperAutomationSheet.nowPlayingEntryID(in: schedule, insertedCurrent: nil, previewing: nil) == nil, "a daily schedule marked a playlist row as playing")
        #expect(WallpaperAutomationSheet.nowPlayingEntryID(in: unqueued, insertedCurrent: "current", previewing: nil) == "current", "the current wallpaper put first is not the playing row")
        #expect(WallpaperAutomationSheet.nowPlayingEntryID(in: legacy, insertedCurrent: nil, previewing: nil) == "legacy-video-1", "an old video list's cursor row is not the playing row")
    }

    @Test("A row previewed on the display is the playing row, ahead of the cursor row and the current wallpaper put first")
    func previewedRowIsThePlayingRow() {
        let queue = ["A", "B", "C"].map { WallpaperQueueEntry(id: $0, title: $0, content: .html(source: .inline($0), config: .default)) }
        var playlist = ScreenConfiguration(screenID: 1, wallpaper: queue[2].content)
        playlist.wallpaperQueue = queue
        playlist.playlistCursorIndex = 2
        let unqueued = ScreenConfiguration(screenID: 1, wallpaper: .html(source: .inline("current"), config: .default))

        #expect(WallpaperAutomationSheet.nowPlayingEntryID(in: playlist, insertedCurrent: nil, previewing: queue[0].id) == queue[0].id, "the cursor row stayed marked while another row was previewed")
        #expect(WallpaperAutomationSheet.nowPlayingEntryID(in: unqueued, insertedCurrent: "current", previewing: queue[1].id) == queue[1].id, "the current wallpaper put first stayed marked while another row was previewed")
    }

    @Test("A fallback picked in the panel is saved and fills the unscheduled hours at once")
    func pickedFallbackFillsUnscheduledHours() async throws {
        let screen = try Screen(nsScreen: #require(NSScreen.screens.first))
        let planned = Self.plannedConfiguration(for: screen)
        let slots = try #require(planned.scheduleSlots)
        let store = WallpaperConfigurationStore(persistence: AutomationTestConfigurationPersistence([planned]))
        var restored: [WallpaperContent] = []
        let orchestrator = Self.scheduleOrchestrator(store: store, screen: screen, clock: { automationTime(10) }, restore: { _, proposed in
            restored.append(proposed.activeWallpaper)
            store.save(proposed)
        })
        let other = WallpaperQueueEntry(title: "Other", content: .html(source: .inline("other"), config: .default))

        orchestrator.updateAutomation(queue: [], slots: slots, fallback: other, mode: .schedule, rotationMinutes: nil, shuffle: false, for: screen)
        await Self.settle()

        #expect(store.get(for: screen.id)?.scheduleFallback == other)
        #expect(restored == [other.content])
    }

    @Test("Without a picked fallback, an old video-only plan still falls back to its primary video")
    func legacyPlanFallsBackToPrimaryVideo() throws {
        let screen = try Screen(nsScreen: #require(NSScreen.screens.first))
        let primary = Data([0x01])
        let slotVideo = Data([0x02])
        var config = ScreenConfiguration(screenID: screen.id, videoBookmarkData: primary)
        config.wallpaperMode = .schedule
        config.scheduleSlots = [ScheduleSlot(startHour: 6, endHour: 12, videoBookmarkData: slotVideo, label: "Morning")]
        config.activeWallpaper = .video(bookmarkData: slotVideo)
        let slots = try #require(config.scheduleSlots)
        let store = WallpaperConfigurationStore(persistence: AutomationTestConfigurationPersistence([config]))
        let orchestrator = Self.scheduleOrchestrator(store: store, screen: screen, clock: { automationTime(10) }, restore: { _, proposed in
            store.save(proposed)
        })

        orchestrator.updateAutomation(queue: [], slots: slots, mode: .schedule, rotationMinutes: nil, shuffle: false, for: screen)

        #expect(store.get(for: screen.id)?.scheduleFallback?.content == .video(bookmarkData: primary))
    }

    private static let morningAndAfternoon = [
        ScheduleSlot(startHour: 6, endHour: 12, label: "Morning"), ScheduleSlot(startHour: 12, endHour: 18, label: "Afternoon"),
    ]

    @Test("A preset adds its own hours when they are free, and nothing when they overlap a slot")
    func presetAddsItsHoursOnlyWhenFree() throws {
        let evening = try #require(WallpaperAutomationSheet.presetSlot(.evening, in: Self.morningAndAfternoon))
        #expect(evening.startHour == 18 && evening.endHour == 22)
        #expect(WallpaperAutomationSheet.presetSlot(.midday, in: Self.morningAndAfternoon) == nil, "an overlapping preset was added")
    }

    @Test("A drag onto another slot's hours is dropped; a drag into free hours moves the slot")
    func retimingRejectsOverlaps() throws {
        let slots = Self.morningAndAfternoon
        #expect(WallpaperAutomationSheet.retimed(slots, id: slots[1].id, start: 10, end: 16) == nil, "an overlapping drag was kept")
        let moved = try #require(WallpaperAutomationSheet.retimed(slots, id: slots[1].id, start: 13, end: 19))
        #expect(moved.map { [$0.startHour, $0.endHour] } == [[6, 12], [13, 19]])
    }

    @Test("A drag that leaves a slot with no hours is dropped")
    func retimingRejectsEmptySlots() {
        let slots = Self.morningAndAfternoon
        #expect(WallpaperAutomationSheet.retimed(slots, id: slots[0].id, start: 6, end: 6) == nil, "a zero-length drag was kept")
    }

    @Test("A double-click inserts two hours, or one where two do not fit")
    func insertFallsBackToOneHour() throws {
        let slots = [ScheduleSlot(startHour: 6, endHour: 12, label: "Morning"), ScheduleSlot(startHour: 13, endHour: 18, label: "Afternoon")]
        let inserted = try #require(WallpaperAutomationSheet.insertedSlot(atHour: 12, in: slots))
        #expect(inserted.startHour == 12 && inserted.endHour == 13)
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
            },
            prepareAutomation: { _, _, _, _ in
                Issue.record("Picking a legacy playlist row validates through the video loader")
                return .cancelled
            }
        )

        orchestrator.playPlaylistEntry(at: 1, for: screen)
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

    @Test("Rotation countdown freezes while the user is away and resumes from the remaining time", .timeLimit(.minutes(1)))
    func absenceFreezesRotationCountdown() async throws {
        let rotations = try await Self.rotationsAfterRestart(absent: true)
        #expect(rotations == [0, 1, 1], "absence time counted toward the countdown, or the elapsed time before absence was lost")
    }

    @Test("Turning automation off and on restarts the rotation countdown", .timeLimit(.minutes(1)))
    func plainRestartRestartsRotationCountdown() async throws {
        let rotations = try await Self.rotationsAfterRestart(absent: false)
        #expect(rotations == [0, 0, 1], "a plain stop/start carried the earlier countdown over")
    }

    /// 30-minute playlist ticked at 0 and 18 min, then stopped and restarted 300 min later.
    /// Returns cumulative rotations at restart+9, restart+13 and restart+31 min.
    private static func rotationsAfterRestart(absent: Bool) async throws -> [Int] {
        let screen = try Screen(nsScreen: #require(NSScreen.screens.first))
        let entries = [
            WallpaperQueueEntry(title: "A", content: .video(bookmarkData: Data([1]))),
            WallpaperQueueEntry(title: "B", content: .video(bookmarkData: Data([2]))),
        ]
        var initial = ScreenConfiguration(screenID: screen.id, wallpaper: entries[0].content)
        initial.wallpaperQueue = entries
        initial.playlistRotationMinutes = 30
        let store = WallpaperConfigurationStore(persistence: AutomationTestConfigurationPersistence([initial]))
        _ = store.loadAll()
        let streams = [AsyncStream<Date>.makeStream(), AsyncStream<Date>.makeStream()]
        var tasksStarted = 0
        let coordinator = WallpaperAutomationCoordinator(tickStreamFactory: {
            defer { tasksStarted += 1 }
            return streams[tasksStarted].stream
        })
        let t0 = Date(timeIntervalSince1970: 1000)
        var clock = t0
        var rotations = 0
        let orchestrator = WallpaperAutomationOrchestrator(
            configurationStore: store, automationCoordinator: coordinator,
            playableVideoLoader: FakePlayableVideoLoader(), screensProvider: { [screen] },
            saveConfiguration: { store.save($0) }, recordBookmarkDisplayName: { _, _ in },
            setupPreparedVideoPlayback: { _, _, _, _ in }, restoreProposedConfiguration: { _, _ in },
            bumpTransition: { _ in 0 }, isCurrentTransition: { _, _ in true }, now: { clock },
            prepareAutomation: { _, proposed, _, intended in
                guard intended() else { return .cancelled }
                rotations += 1
                store.save(proposed)
                return .ready
            }, libraryEntryAvailable: { _ in true }
        )
        func tick(_ stream: Int, atMinute minute: Double) async {
            clock = t0.addingTimeInterval(minute * 60)
            streams[stream].continuation.yield(clock)
            while coordinator.currentTime != clock {
                await Task.yield()
            }
            for _ in 0 ..< 50 {
                await Task.yield()
            }
        }

        orchestrator.startMonitoring()
        defer { orchestrator.stopMonitoring() }
        await tick(0, atMinute: 0)
        await tick(0, atMinute: 18)
        #expect(rotations == 0)
        if absent {
            orchestrator.suspendForUserAbsence()
            // Wake refreshes screens before the absence ends.
            orchestrator.refreshMonitoringIfActive()
            orchestrator.resumeAfterUserAbsence()
        } else {
            orchestrator.stopMonitoring()
            orchestrator.startMonitoring()
        }
        var counts: [Int] = []
        await tick(1, atMinute: 318)
        for minute in [327.0, 331, 349] {
            await tick(1, atMinute: minute)
            counts.append(rotations)
        }
        return counts
    }
}

private func automationTime(day: Int = 15, _ hour: Int, _ minute: Int = 0, _ second: Int = 0) -> Date {
    Calendar.current.date(from: DateComponents(year: 2026, month: 6, day: day, hour: hour, minute: minute, second: second))!
}

private final class AutomationTestNSScreen: NSScreen {
    let displayID: UInt32

    init(displayID: UInt32) {
        self.displayID = displayID
        super.init()
    }

    required init?(coder _: NSCoder) {
        nil
    }

    override var frame: NSRect {
        NSRect(x: 0, y: 0, width: 800, height: 600)
    }

    override var deviceDescription: [NSDeviceDescriptionKey: Any] {
        [NSDeviceDescriptionKey("NSScreenNumber"): displayID]
    }

    override var localizedName: String {
        "Automation test"
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
    @Test("Wallpaper playback does not keep the display awake")
    func wallpaperPlaybackDisablesDisplaySleepPrevention() throws {
        let source = try RepositoryRoot.source("LiveWallpaper/Runtime/Video/WallpaperVideoPlayer.swift")

        #expect(source.contains("preventsDisplaySleepDuringVideoPlayback = false"))
    }

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

    @Test("The current scene detail consumes a bounded first-frame image without retaining an animated preview")
    func sceneDetailPreviewFallbackDoesNotRetainAnimatedPreviewState() async throws {
        #if !LITE_BUILD
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("scene-static-consumer-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = NSMutableData()
        let gif = try #require(CGImageDestinationCreateWithData(data, "com.compuserve.gif" as CFString, 2, nil))
        for color in [CGColor(red: 1, green: 0, blue: 0, alpha: 1), CGColor(red: 0, green: 0, blue: 1, alpha: 1)] {
            let context = try #require(CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                                                 space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(color)
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
            try CGImageDestinationAddImage(gif, #require(context.makeImage()),
                                           [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.05]] as CFDictionary)
        }
        try #require(CGImageDestinationFinalize(gif))
        let previewURL = directory.appendingPathComponent("preview.gif")
        try (data as Data).write(to: previewURL)
        let input = try #require(CGImageSourceCreateWithData(data, nil))
        #expect(CGImageSourceGetCount(input) == 2)
        let origin = try WPEOrigin(workshopID: "static-fixture", title: "Static fixture", originalType: .scene,
                                   sourceFolderBookmark: directory.bookmarkData(options: .withSecurityScope),
                                   cacheRelativePath: nil, previewFileName: "preview.gif")
        let image = try #require(await ShelfThumbnailCache.Sources().scene(origin, CGSize(width: 32, height: 32)))
        #expect(image.width == 32 && image.height == 16)
        let pixel = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                           space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        pixel.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let bytes = try #require(pixel.data).assumingMemoryBound(to: UInt8.self)
        #expect(bytes[0] > 240 && bytes[2] < 10, "The static consumer returned an animated later frame instead of the red first frame")
        #endif
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

    private var policyAllowsPlayback: Bool

    init(isPlaying: Bool, userIntendsToPlay: Bool? = nil, policyAllowsPlayback: Bool? = nil) {
        self.isPlaying = isPlaying
        self.userIntendsToPlay = userIntendsToPlay ?? isPlaying
        // Default: policy is not suppressing — `isPlaying: false` alone means the user
        // paused; only intends-to-play-but-not-playing is a policy suspend.
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

    @Test("Refreshing a legacy bookmark keeps reordered primary and every other item", arguments: [0, 1, 2, 3], [0, 1, 2, 3])
    func bookmarkRefreshHonorsPrimaryPosition(primary: Int, cursor: Int) {
        var configuration = ScreenConfiguration(
            screenID: 1, videoBookmarkData: Data([1]),
            playlistBookmarks: [Data([2]), Data([3]), Data([4])]
        )
        configuration.playlistPrimaryIndex = primary
        let original = configuration.combinedPlaylist
        let refreshed = Data([99])
        PlaylistPolicy.refreshLegacyBookmark(at: cursor, in: &configuration, with: refreshed)
        var expected = original
        expected[cursor] = refreshed
        #expect(configuration.combinedPlaylist == expected)
        #expect(configuration.playlistPrimaryIndex == primary)
        #expect(configuration.savedVideoBookmarkData == (cursor == primary ? refreshed : Data([1])))
    }

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
        let playlist: [Data] = [Data([0x02]), Data([0x03])]

        var config = ScreenConfiguration(
            screenID: 1,
            videoBookmarkData: oldBookmark,
            particleEffect: .snow,
            effectConfig: effects,
            scheduleSlots: ScheduleSlot.defaultSlots,
            playlistBookmarks: playlist,
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
        #expect(config.playlistBookmarks == playlist)
        #expect(config.shufflePlaylist == true)
        #expect(config.playlistRotationMinutes == 15)
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

        config.activeWallpaper = .video(bookmarkData: scheduled)
        config.setHTMLWallpaper(source: .inline("<p>ambient</p>"))

        #expect(config.savedVideoBookmarkData == primary)
        #expect(config.videoBookmarkData == primary)
    }

    @Test("activateSavedVideoWallpaper prefers saved primary over active scheduled video")
    func activateSavedVideoUsesPrimary() {
        let primary = Data([0x01])
        let scheduled = Data([0xAA])
        var config = ScreenConfiguration(screenID: 8, videoBookmarkData: primary)

        config.activeWallpaper = .video(bookmarkData: scheduled)
        let restored = config.activateSavedVideoWallpaper()

        #expect(restored)
        #expect(config.activeWallpaper == .video(bookmarkData: primary))
        #expect(config.savedVideoBookmarkData == primary)
    }
}

@Suite("SchedulePolicy")
struct SchedulePolicyTests {
    @Test("Universal schedules cover midnight, restore the fallback and avoid redundant reloads")
    @MainActor
    func universalDailyCycle() throws {
        let web = WallpaperQueueEntry(title: "Web", content: .html(source: .inline("hello"), config: .default))
        let video = WallpaperQueueEntry(title: "Video", content: .video(bookmarkData: Data([1])))
        var config = ScreenConfiguration(screenID: 1, wallpaper: video.content)
        config.wallpaperMode = .schedule
        config.scheduleFallback = video
        config.scheduleSlots = [ScheduleSlot(startHour: 22, endHour: 6, label: "Night", wallpaper: web)]
        #expect(SchedulePolicy.decision(for: config, hour: 23) == .applyWallpaper(web))
        #expect(SchedulePolicy.decision(for: config, hour: 0) == .applyWallpaper(web))
        config = config.applyingAutomationEntry(web)
        #expect(SchedulePolicy.decision(for: config, hour: 3) == .none)
        #expect(SchedulePolicy.decision(for: config, hour: 6) == .applyWallpaper(video))
        let allDay = ScheduleSlot(startHour: 0, endHour: 24, label: "All day", wallpaper: web)
        #expect(SchedulePolicy.hourRanges(for: allDay) == [0 ..< 24])
        #expect(try !SchedulePolicy.conflicts(slot: allDay, against: #require(config.scheduleSlots)).isEmpty)
        config.scheduleSlots = [allDay]
        #expect(WallpaperAutomationCoordinator.hasDemand(config))
    }

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

    @Test("At a slot's start its video replaces a web wallpaper")
    func slotStartReplacesWebWallpaper() throws {
        let primary = Data([0x01])
        let slot = ScheduleSlot(startHour: 6, endHour: 12, videoBookmarkData: primary, label: "Morning")
        let page = try #require(URL(string: "https://example.com"))
        var configuration = ScreenConfiguration(
            screenID: 43,
            wallpaper: .html(source: .url(page), config: .default),
            scheduleSlots: [slot],
            savedVideoBookmarkData: primary
        )
        configuration.wallpaperMode = .schedule

        let result = SchedulePolicy.decision(for: configuration, hour: 8)

        #expect(result == .applySlot(slot: slot, bookmarkData: primary))
    }

    @Test("A hold lasts until the next slot edge, across midnight, and until midnight when no slot has a length")
    func nextBoundaryFollowsSlotEdges() {
        let night = [ScheduleSlot(startHour: 22, endHour: 6, label: "Night")]
        #expect(SchedulePolicy.nextBoundary(after: automationTime(23, 30), slots: night, calendar: .current) == automationTime(day: 16, 6))
        #expect(SchedulePolicy.nextBoundary(after: automationTime(3), slots: night, calendar: .current) == automationTime(6))
        let day = [ScheduleSlot(startHour: 6, endHour: 12, label: "A"), ScheduleSlot(startHour: 12, endHour: 18, label: "B")]
        #expect(SchedulePolicy.nextBoundary(after: automationTime(13), slots: day, calendar: .current) == automationTime(18))
        let allDay = [ScheduleSlot(startHour: 0, endHour: 24, label: "All day")]
        #expect(SchedulePolicy.nextBoundary(after: automationTime(13), slots: allDay, calendar: .current) == automationTime(day: 16, 0))
        let empty = [ScheduleSlot(startHour: 8, endHour: 8, label: "Empty")]
        #expect(SchedulePolicy.nextBoundary(after: automationTime(13), slots: empty, calendar: .current) == automationTime(day: 16, 0))
    }

    @Test("A content change claims an unsettled slot; a stale copy of the same content cannot reopen a settled one")
    func manualChangeClaimsUnsettledSlot() {
        let now = automationTime(13)
        let planned = WallpaperQueueEntry(title: "A", content: .html(source: .inline("a"), config: .default))
        var stored = ScreenConfiguration(screenID: 1, wallpaper: planned.content)
        stored.wallpaperMode = .schedule
        stored.scheduleSlots = [ScheduleSlot(startHour: 12, endHour: 18, label: "Day", wallpaper: planned)]
        stored.scheduleSettledUntil = automationTime(12)
        var picked = stored
        picked.activeWallpaper = .html(source: .inline("c"), config: .default)
        var louder = HTMLConfig.default
        louder.audioVolume = 0.3
        var edited = stored
        edited.activeWallpaper = .html(source: .inline("a"), config: louder)
        var settled = stored
        settled.scheduleSettledUntil = automationTime(18)
        var fresh = picked
        fresh.scheduleSettledUntil = automationTime(14)
        var playlist = picked
        playlist.wallpaperMode = .playlist

        func held(_ configuration: ScreenConfiguration, over previous: ScreenConfiguration?) -> Date? {
            SchedulePolicy.holdingManualChange(configuration, previous: previous, now: now, calendar: .current).scheduleSettledUntil
        }
        #expect(held(picked, over: stored) == automationTime(18))
        #expect(held(picked, over: nil) == automationTime(18))
        #expect(held(edited, over: settled) == automationTime(18))
        #expect(held(edited, over: stored) == automationTime(12))
        #expect(held(fresh, over: stored) == automationTime(14))
        #expect(held(playlist, over: stored) == automationTime(12))
    }

    @Test("With every slot cleared the unscheduled-hours wallpaper fills the day; without one the display is left alone")
    func emptySlotsFallBackToUnscheduledWallpaper() {
        let web = WallpaperQueueEntry(title: "Web", content: .html(source: .inline("hello"), config: .default))
        let video = WallpaperQueueEntry(title: "Video", content: .video(bookmarkData: Data([1])))
        var config = ScreenConfiguration(screenID: 1, wallpaper: web.content)
        config.wallpaperMode = .schedule
        config.scheduleFallback = video
        #expect(SchedulePolicy.decision(for: config, hour: 13) == .applyWallpaper(video))
        config.scheduleSlots = []
        #expect(SchedulePolicy.decision(for: config, hour: 13) == .applyWallpaper(video))
        #expect(SchedulePolicy.decision(for: config.applyingAutomationEntry(video), hour: 13) == .none)
        config.scheduleFallback = nil
        #expect(SchedulePolicy.decision(for: config, hour: 13) == .none)
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

    @Test("The first slot problem names its slots: an overlap names both, a zero-length slot names itself")
    func firstProblemNamesTheSlots() {
        let morning = ScheduleSlot(startHour: 6, endHour: 12, label: "A")
        let lateMorning = ScheduleSlot(startHour: 10, endHour: 14, label: "B")
        let empty = ScheduleSlot(startHour: 20, endHour: 20, label: "C")
        let afternoon = ScheduleSlot(startHour: 12, endHour: 18, label: "D")
        let allDay = ScheduleSlot(startHour: 0, endHour: 24, label: "E")

        #expect(SchedulePolicy.firstProblem(in: [morning, lateMorning]) == .overlap(morning.id, lateMorning.id))
        #expect(SchedulePolicy.firstProblem(in: [empty, morning]) == .noLength(empty.id))
        #expect(SchedulePolicy.firstProblem(in: [morning, afternoon]) == nil)
        #expect(SchedulePolicy.firstProblem(in: [allDay]) == nil)
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

    @Test("Failure diagnostics are captured before candidate cleanup while A stays installed")
    func captureFailureBeforeCleanup() async throws {
        let screen = try Screen(nsScreen: #require(NSScreen.screens.first))
        let active = TestWallpaperRuntimeSession(summary: .notConfigured, wallpaperType: .video)
        let candidate = TestWallpaperRuntimeSession(summary: .notConfigured, wallpaperType: .scene, preparationResult: .failed)
        screen.installRuntimeSession(active)
        var captured = false
        let result = await WallpaperSessionTransaction.prepareAndCommit(
            candidate, to: screen, replacing: active, timeout: .seconds(1), isStillCurrent: { true },
            beforeDiscard: { result in
                #expect(result == .failed)
                #expect(candidate.cleanupCallCount == 0)
                #expect(screen.runtimeSession === active)
                captured = true
            }
        )
        #expect(captured)
        #expect(result == .failed)
        #expect(candidate.cleanupCallCount == 1)
        #expect(active.cleanupCallCount == 0)
        #expect(screen.runtimeSession === active)
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

    @Test("A committed or cancelled candidate never consults isStillCurrent")
    func candidateErrorPublicationSkipsCurrencyCheckUnlessFailed() {
        var consulted = 0
        func stillCurrent() -> Bool {
            consulted += 1
            return true
        }
        _ = WallpaperCandidateErrorPolicy.errorToPublish(.ready, isStillCurrent: stillCurrent(), candidateError: nil, fallbackWallpaperType: .scene)
        _ = WallpaperCandidateErrorPolicy.shouldPublish(.ready, isStillCurrent: stillCurrent())
        _ = WallpaperCandidateErrorPolicy.shouldPublish(.cancelled, isStillCurrent: stillCurrent())
        #expect(consulted == 0)
        _ = WallpaperCandidateErrorPolicy.errorToPublish(.failed, isStillCurrent: stillCurrent(), candidateError: nil, fallbackWallpaperType: .scene)
        _ = WallpaperCandidateErrorPolicy.shouldPublish(.timedOut, isStillCurrent: stillCurrent())
        #expect(consulted == 2)
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

        // The fake ignores cancellation: resume it after the assertions, or its
        // continuation leaks into the rest of the run.
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

    @Test(
        "Screen refresh mid-crossfade closes the session that was still fading out",
        .enabled(if: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                 "Reduce Motion takes the immediate-cleanup path; there is no fade to orphan")
    )
    func screenRefreshMidCrossfadeCleansUpRetiringSession() {
        guard let nsScreen = NSScreen.screens.first else {
            Issue.record("No NSScreen available for test")
            return
        }
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 8, height: 8),
            styleMask: .borderless,
            backing: .buffered,
            defer: true
        )
        // AppKit releases a closed window by default; the fade animation and
        // ARC would then both let go of it.
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let original = Screen(nsScreen: nsScreen)
        let fading = TestWallpaperRuntimeSession(
            summary: .notConfigured,
            wallpaperType: .video,
            wallpaperWindow: window
        )
        let current = TestWallpaperRuntimeSession(summary: .notConfigured, wallpaperType: .video)
        original.installRuntimeSession(fading)
        original.installRuntimeSession(current)
        // Control: with a window to fade, replacement retires rather than cleans up.
        #expect(fading.cleanupCallCount == 0)

        let refreshed = Screen(nsScreen: nsScreen)
        refreshed.adoptRuntimeSession(from: original)

        #expect(fading.cleanupCallCount == 1)
        #expect(current.cleanupCallCount == 0)
        #expect((refreshed.runtimeSession as AnyObject?) === current)
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

    @Test("Resetting all sessions then refreshing without preserving sessions restores still-connected screens' saved wallpapers")
    func resetThenRefreshWithoutPreservingSessionsRestoresSavedWallpapers() async throws {
        guard let nsScreen = NSScreen.screens.first else {
            Issue.record("No NSScreen available for test")
            return
        }
        let screen = Screen(nsScreen: nsScreen)

        let originalConfigurations = SettingsManager.shared.loadConfigurations()
        defer { SettingsManager.shared.replaceAllConfigurations(originalConfigurations) }
        SettingsManager.shared.replaceAllConfigurations([
            ScreenConfiguration(screenID: screen.id, wallpaper: .html(source: .inline("<p>restore</p>"), config: .default)),
        ])

        let manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: true,
            startAutomation: false,
            powerMonitor: FakePowerMonitor(),
            fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(),
            displayRegistry: FakeDisplayRegistry(screens: [screen]),
            featureCatalog: FeatureCatalog(capabilities: .pro)
        ))
        defer { screen.resetRuntimeSession() }

        for _ in 0 ..< 200 where screen.runtimeSession == nil {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(screen.runtimeSession != nil, "precondition: construction should have restored the saved wallpaper")

        manager.resetAllWallpaperSessions()
        #expect(screen.runtimeSession == nil, "precondition: reset should have torn the session down")

        manager.refreshScreens(preserveRuntimeSessions: false)

        for _ in 0 ..< 200 where screen.runtimeSession == nil {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(screen.runtimeSession != nil, "screen wallpaper should be restored after resetAllWallpaperSessions() + refreshScreens(preserveRuntimeSessions: false), mirroring an imported backup")
    }
}

@MainActor
private final class TestWallpaperRuntimeSession: WallpaperRuntimeSession {
    let wallpaperType: WallpaperType
    let summary: WallpaperSessionSummary
    let videoPlayer: WallpaperVideoPlayer? = nil
    let wallpaperWindow: NSWindow?
    private(set) var cleanupCallCount = 0
    private(set) var prepareCallCount = 0
    private var preparationResult: WallpaperPreparationResult?
    private var preparationContinuation: CheckedContinuation<WallpaperPreparationResult, Never>?

    init(
        summary: WallpaperSessionSummary,
        wallpaperType: WallpaperType,
        preparationResult: WallpaperPreparationResult? = .ready,
        wallpaperWindow: NSWindow? = nil
    ) {
        self.summary = summary
        self.wallpaperType = wallpaperType
        self.preparationResult = preparationResult
        self.wallpaperWindow = wallpaperWindow
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
