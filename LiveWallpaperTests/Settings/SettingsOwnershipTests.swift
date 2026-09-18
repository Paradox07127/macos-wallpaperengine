import Foundation
import LiveWallpaperCore
import Testing
@testable import LiveWallpaper

@Suite("UI-08: General Settings ownership characterization", .serialized)
@MainActor
struct GeneralSettingsOwnershipCharacterizationTests {
    @Test("The root state inventory is fully assigned to candidate domain owners")
    func rootStateInventoryMatchesOwnershipFixture() throws {
        let source = try RepositoryRoot.source("LiveWallpaper/Views/Settings/GeneralSettingsView.swift")
        let actual = try Self.storedPropertyNames(in: source)
        let fixtureValues = OwnershipFixture.fieldsByDomain.values.flatMap(Array.init)

        #expect(fixtureValues.count == Set(fixtureValues).count, "A state field must have exactly one candidate owner")
        #expect(actual == Set(fixtureValues))
        #expect(actual.count == 45, "Changing the root state surface requires explicitly re-approving the UI-08 lock")
    }

    @Test("Each page mounts only its own system-capability probe")
    func eachPageMountsOnlyItsOwnSystemCapabilityProbe() throws {
        let source = try RepositoryRoot.source("LiveWallpaper/Views/Settings/GeneralSettingsView.swift")
        let propertyDefaults = try Self.slice(
            source,
            from: "struct GeneralSettingsView: View {",
            until: "private let page"
        )
        let initializer = try Self.slice(source, from: "init(page: GeneralSettingsPage = .general) {", until: "var body: some View")
        let scopes = try Self.slice(
            source,
            from: "private var systemStatusScopes: [SystemStatusScope] {",
            until: "private static func initialLoginItemStatus"
        )

        #expect(!propertyDefaults.contains("SMAppService.mainApp.status"))
        #expect(!propertyDefaults.contains("SystemAudioCaptureManager.shared.state"))
        #expect(!propertyDefaults.contains("CLLocationManager().authorizationStatus"))
        #expect(initializer.contains("Self.initialLoginItemStatus(for: page)"))
        #expect(initializer.contains("Self.initialAudioCaptureState(for: page)"))
        #expect(initializer.contains("Self.initialLocationAuthorizationStatus(for: page)"))
        #expect(Self.occurrences(".onAppear { refreshSystemStatusIndicators() }", in: source) == 1)

        for page in [.general, .integrations] as [OwnershipFixture.Page] {
            #expect(
                scopes.contains("case .\(page.rawValue):"),
                "Every Settings page needs an explicit system-probe ownership decision"
            )
            #expect(
                OwnershipFixture.mountCalls(for: page, sku: .pro).settingsReads == 1,
                "All pages still load the shared GlobalSettings snapshot exactly once"
            )
        }

        #expect(scopes.contains("case .general:\n            [.loginItem]"))
        #expect(scopes.contains("case .integrations:\n            #if !LITE_BUILD\n            [.audioCapture, .weatherLocation]"))
        #expect(scopes.contains("case .performancePower, .backupRestore, .advanced, .about:\n            []"))

        #expect(OwnershipFixture.mountCalls(for: .general, sku: .pro) == MountCalls(settingsReads: 1, loginStatusReads: 2, audioStateReads: 0, locationStatusReads: 0))
        #expect(OwnershipFixture.mountCalls(for: .integrations, sku: .pro) == MountCalls(settingsReads: 1, loginStatusReads: 0, audioStateReads: 2, locationStatusReads: 2))
        #expect(OwnershipFixture.mountCalls(for: .integrations, sku: .lite) == MountCalls(settingsReads: 1, loginStatusReads: 0, audioStateReads: 0, locationStatusReads: 2))
        #expect(OwnershipFixture.mountCalls(for: .backupRestore, sku: .lite) == MountCalls(settingsReads: 1, loginStatusReads: 0, audioStateReads: 0, locationStatusReads: 0))
    }

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
        await manager.flushPendingConfigurationWrites()

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

    @Test("Persistence and import keep the current cross-domain semantics")
    func persistenceAndImportSourceContracts() throws {
        let rootSource = try RepositoryRoot.source("LiveWallpaper/Views/Settings/GeneralSettingsView.swift")
        let update = try Self.slice(
            rootSource,
            from: "func updateGlobalSettings() {",
            until: "/// Defers the post"
        )
        let commitSource = try RepositoryRoot.source("LiveWallpaper/App/GlobalSettingsCommit.swift")
        let commit = try Self.slice(
            commitSource,
            from: "static func apply(",
            until: "/// Deferred so the post"
        )

        let expectedArguments = [
            "globalPauseOnBattery: globalPauseOnBattery",
            "preservePlaybackOnLock: preservePlaybackOnLock",
            "startOnLogin: startOnLogin",
            "pauseOnFullScreen: pauseOnFullScreen",
            "pauseOnWindowOcclusion: pauseOnWindowOcclusion",
            "pauseInLowPowerMode: pauseInLowPowerMode",
            "applicationPerformanceRules: applicationRules",
            "showInDock: showInDock",
            "wallpaperVisibleInScreenCapture: wallpaperVisibleInScreenCapture",
            "videoCacheMaxBytesPerScreen: Int(videoCacheBudgetMB) * 1024 * 1024",
            "audioResponseEnabled: audioResponseEnabled",
            "adaptiveFrameRateEnabled: adaptiveFrameRateEnabled",
            "weatherLocation: weatherLocation",
        ]
        let expectedAssignments = [
            "settings.globalPauseOnBattery = fields.globalPauseOnBattery",
            "settings.preservePlaybackOnLock = fields.preservePlaybackOnLock",
            "settings.startOnLogin = fields.startOnLogin",
            "settings.pauseOnFullScreen = fields.pauseOnFullScreen",
            "settings.pauseOnWindowOcclusion = fields.pauseOnWindowOcclusion",
            "settings.pauseInLowPowerMode = fields.pauseInLowPowerMode",
            "settings.applicationPerformanceRules = fields.applicationPerformanceRules",
            "settings.showInDock = fields.showInDock",
            "settings.wallpaperVisibleInScreenCapture = fields.wallpaperVisibleInScreenCapture",
            "settings.videoCacheMaxBytesPerScreen = fields.videoCacheMaxBytesPerScreen",
            "settings.audioResponseEnabled = fields.audioResponseEnabled",
            "settings.adaptiveFrameRateEnabled = fields.adaptiveFrameRateEnabled",
            "settings.weatherLocation = fields.weatherLocation",
        ]

        #expect(update.contains("GlobalSettingsCommit.apply("))
        #expect(update.contains("screenManager: screenManager"))
        for argument in expectedArguments {
            #expect(update.contains(argument), "Page stopped forwarding: \(argument)")
        }

        #expect(commit.contains("var settings = SettingsManager.shared.loadGlobalSettings()"))
        #expect(commit.contains("SettingsManager.shared.saveGlobalSettings(settings)"))
        #expect(commit.contains("screenManager.handleGlobalSettingsChanged()"))
        #expect(
            !commit.contains("var settings = GlobalSettings("),
            "Commit must remain read-modify-write"
        )
        for assignment in expectedAssignments {
            #expect(commit.contains(assignment), "Missing persistence mapping: \(assignment)")
        }
        #expect(commit.contains("if outcome.dockVisibilityChanged"))
        #expect(commit.contains("if outcome.weatherLocationChanged"))
        #expect(commit.contains("if outcome.audioResponseChanged"))

        let shortcuts = try RepositoryRoot.source("LiveWallpaper/Views/Settings/ShortcutsView.swift")
        #expect(shortcuts.contains("GlobalSettingsCommit.ShortcutsPageFields("))
        #expect(commitSource.contains("postAsync(.globalShortcutsDidChange)"))
        let workshop = try RepositoryRoot.source("LiveWallpaper/Views/Settings/WorkshopSettingsView.swift")
        #expect(workshop.contains("GlobalSettingsCommit.WorkshopPageFields("))

        let backup = try RepositoryRoot.source("LiveWallpaper/Views/Settings/BackupSection.swift")
        #expect(backup.contains("let summary = ConfigurationPorter.apply(bundle)"))
        #expect(backup.contains("screenManager.handleGlobalSettingsChanged()"))
        #expect(backup.contains("screenManager.resetAllWallpaperSessions()"))
        #expect(backup.contains("screenManager.refreshScreens(preserveRuntimeSessions: false)"))
        #expect(backup.contains("applyAudioResponseEnabled(settings.audioResponseEnabled)"))
        #expect(backup.contains("postSettingsNotificationAsync(.weatherLocationPreferenceDidChange)"))
        #expect(backup.contains("postSettingsNotificationAsync(.globalShortcutsDidChange)"))
    }

    @Test("SKU-specific controls stay behind compile and capability gates")
    func skuSpecificControlSourceContracts() throws {
        let root = try RepositoryRoot.source("LiveWallpaper/Views/Settings/GeneralSettingsView.swift")
        let audio = try RepositoryRoot.source("LiveWallpaper/Views/Settings/AudioSection.swift")
        let performance = try RepositoryRoot.source("LiveWallpaper/Views/Settings/PerformanceSection.swift")
        let about = try RepositoryRoot.source("LiveWallpaper/Views/Settings/AboutTab.swift")
        let detail = try RepositoryRoot.source("LiveWallpaper/Views/Settings/DetailContent.swift")

        #expect(root.contains("#if !LITE_BUILD\n    @State var audioCaptureState"))
        #expect(audio.contains("#if !LITE_BUILD\n        Section"))
        // Rendering is gated as a whole section, not row by row: gating only the rows
        // would leave Lite with a "Rendering" header and nothing under it.
        let renderingGate = try Self.slice(performance, from: "#if !LITE_BUILD", until: "#endif")
        #expect(renderingGate.contains("Adaptive frame rate"))
        #expect(renderingGate.contains("MetalFX upscaling"))
        #expect(renderingGate.contains("HDR output"))
        #expect(renderingGate.contains("Multithreaded rendering"))
        // The update readout is deliberately NOT SKU-gated: both SKUs ship from the same
        // GitHub release, so the unwrapped call site is pinned to keep a `#if` from creeping back.
        #expect(about.contains("UpdateStatusLine()\n                    .padding(.top, 2)"))
        #expect(!about.contains("LITE_BUILD"))
        #expect(detail.contains("if featureCatalog.isEnabled(.wpeImport)"))
        #expect(detail.contains("if featureCatalog.isEnabled(.workshopOnline)"))
    }
}

private extension GeneralSettingsOwnershipCharacterizationTests {
    enum FixtureError: Error {
        case missingBoundary(String)
    }

    static func storedPropertyNames(in source: String) throws -> Set<String> {
        let regex = try NSRegularExpression(
            pattern: #"(?m)^\s*@(State|AppStorage)[^\n]*\bvar\s+([A-Za-z_][A-Za-z0-9_]*)"#
        )
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return Set(regex.matches(in: source, range: range).compactMap { match in
            guard let nameRange = Range(match.range(at: 2), in: source) else { return nil }
            return String(source[nameRange])
        })
    }

    static func slice(_ source: String, from start: String, until end: String) throws -> String {
        guard let startRange = source.range(of: start) else {
            throw FixtureError.missingBoundary(start)
        }
        guard let endRange = source.range(of: end, range: startRange.upperBound..<source.endIndex) else {
            throw FixtureError.missingBoundary(end)
        }
        return String(source[startRange.lowerBound..<endRange.lowerBound])
    }

    static func occurrences(_ needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }
}
