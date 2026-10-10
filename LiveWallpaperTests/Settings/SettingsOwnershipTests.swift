import Foundation
import LiveWallpaperCore
import Testing
@testable import LiveWallpaper

@Suite("UI-08: General Settings ownership characterization", .serialized)
@MainActor
struct GeneralSettingsOwnershipCharacterizationTests {

    @Test("Mirrored and unrelated global settings survive a durable manager restart")
    func settingsRoundTripSurvivesManagerRestart() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GeneralSettingsOwnership-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let directory = ConfigurationDirectory(root: root)
        let manager = SettingsManager(directory: directory)
        let existingStartOnLogin = manager.loadGlobalSettings().startOnLogin
        let manualLocation = WeatherLocationPreference.ManualLocation(
            latitude: 40.7128,
            longitude: -74.0060,
            name: "UI-08 Fixture"
        )
        let history = WPEHistoryEntry(
            origin: WPEOrigin(
                workshopID: "ui-08-history",
                title: "Ownership Fixture",
                originalType: .video,
                sourceFolderBookmark: Data([0x08]),
                cacheRelativePath: "wpe-cache/ui-08-history",
                previewFileName: "preview.jpg"
            ),
            importedAt: Date(timeIntervalSince1970: 1_700_000_008),
            lastUsedAt: Date(timeIntervalSince1970: 1_700_000_108)
        )
        let displayDefaults = DisplayDefaults(
            video: DisplayPlaybackDefaults(
                playbackSpeed: 1.25,
                frameRateLimit: .fps30,
                muted: false,
                videoVolume: 0.25
            )
        )
        let expected = GlobalSettings(
            globalPauseOnBattery: true,
            preservePlaybackOnLock: true,
            startOnLogin: existingStartOnLogin,
            pauseOnFullScreen: false,
            pauseOnWindowOcclusion: false,
            pauseInLowPowerMode: false,
            showInDock: true,
            weatherLocation: WeatherLocationPreference(source: .manual, manual: manualLocation),
            globalShortcutsEnabled: false,
            recentWPEImports: [history],
            deletedWorkshopIDs: ["ui-08-deleted"],
            applicationPerformanceRules: [
                ApplicationPerformanceRule(
                    bundleID: "com.example.ui08",
                    displayName: "UI-08 Fixture",
                    trigger: .neverPause
                ),
            ],
            videoCacheMaxBytesPerScreen: 320 * 1024 * 1024,
            displayDefaults: displayDefaults,
            audioResponseEnabled: true,
            adaptiveFrameRateEnabled: true
        )

        manager.saveGlobalSettings(expected)
        await manager.flushPendingWrites()

        let persistedURL = directory.url(for: .globalSettings)
        #expect(FileManager.default.fileExists(atPath: persistedURL.path))

        let restarted = SettingsManager(directory: directory).loadGlobalSettings()
        #expect(restarted.globalPauseOnBattery == expected.globalPauseOnBattery)
        #expect(restarted.preservePlaybackOnLock == expected.preservePlaybackOnLock)
        #expect(restarted.startOnLogin == expected.startOnLogin)
        #expect(restarted.pauseOnFullScreen == expected.pauseOnFullScreen)
        #expect(restarted.pauseOnWindowOcclusion == expected.pauseOnWindowOcclusion)
        #expect(restarted.pauseInLowPowerMode == expected.pauseInLowPowerMode)
        #expect(restarted.showInDock == expected.showInDock)
        #expect(restarted.weatherLocation == expected.weatherLocation)
        #expect(restarted.applicationPerformanceRules == expected.applicationPerformanceRules)
        #expect(restarted.videoCacheMaxBytesPerScreen == expected.videoCacheMaxBytesPerScreen)
        #expect(restarted.audioResponseEnabled == expected.audioResponseEnabled)
        #expect(restarted.adaptiveFrameRateEnabled == expected.adaptiveFrameRateEnabled)

        #expect(restarted.globalShortcutsEnabled == false)
        #expect(restarted.recentWPEImports == [history])
        #expect(restarted.deletedWorkshopIDs == ["ui-08-deleted"])
        #expect(restarted.displayDefaults == displayDefaults)
    }

    @Test("Settings navigation visibility follows the capability and SKU matrix")
    func settingsNavigationVisibilityMatchesCapabilities() {
        // `.audioResponse` is Pro-only: the capture pipeline is compiled out of
        // Lite, so Lite (and fail-closed unconfigured) must not list the page.
        let systemWallpaper: [SettingsNavigation] = if #available(macOS 26.0, *) {
            [.systemWallpaper]
        } else {
            []
        }
        // Sidebar order is grouped: Setup, Playback, Content, Data, Support.
        let common: [SettingsNavigation] = [
            .general,
            .appearance,
            .displayDefaults,
            .shortcuts,
            .performancePower,
            .integrations,
            .overlays,
        ] + systemWallpaper + [
            .backupRestore,
            .advanced,
            .about,
        ]
        let shippingPro = SettingsNavigation.availableItems(
            capabilities: .pro,
            includeWorkshopOnline: false
        ).map(\.destination)
        let directPro = SettingsNavigation.availableItems(
            capabilities: .pro.withWorkshopOnline(),
            includeWorkshopOnline: true
        ).map(\.destination)
        #expect(SettingsNavigation.availableItems(capabilities: .lite).map(\.destination) == common)
        #expect(SettingsNavigation.availableItems(capabilities: .unconfigured).map(\.destination) == common)
        #expect(shippingPro == [
            .general,
            .appearance,
            .displayDefaults,
            .shortcuts,
            .performancePower,
            .integrations,
            .overlays,
        ] + systemWallpaper + [
            .storage,
            .backupRestore,
            .advanced,
            .about,
        ])
        #expect(directPro == [
            .general,
            .appearance,
            .displayDefaults,
            .shortcuts,
            .performancePower,
            .integrations,
            .overlays,
        ] + systemWallpaper + [
            .workshopSetup,
            .storage,
            .backupRestore,
            .advanced,
            .about,
        ])
    }

}
