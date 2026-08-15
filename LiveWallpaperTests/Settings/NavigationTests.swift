import Testing
@testable import LiveWallpaper

@Suite("Settings navigation")
struct NavigationTests {
    @Test("Search matches settings titles and keywords")
    func searchMatchesTitlesAndKeywords() {
        let items = SettingsNavigation.filteredResults(
            matching: "battery",
            capabilities: .pro,
            includeWorkshopOnline: false
        )

        #expect(items.map(\.destination).contains(.performancePower))
        #expect(!items.map(\.destination).contains(.general))
    }

    @Test("Settings navigation stays scoped to settings tasks")
    func settingsNavigationStaysScopedToSettingsTasks() {
        let titles = SettingsNavigation.availableItems(
            capabilities: .pro,
            includeWorkshopOnline: false
        ).map(\.title)

        #expect(titles.contains("General"))
        #expect(titles.contains("Performance"))
        #expect(!titles.contains("Performance & Power"))
        #expect(titles.contains("Audio Response"))
        #expect(titles.contains("Weather"))
        #expect(titles.contains("Display Defaults"))
        #expect(!titles.contains("Audio & Weather"))
        #expect(!titles.contains("Bookmarks"))
        #expect(!titles.contains("Apple Aerials"))
        #expect(!titles.contains("Steam Workshop"))
    }

    @Test("Audio and weather search route to separate settings pages")
    func audioAndWeatherSearchRouteSeparately() {
        let audioItems = SettingsNavigation.filteredResults(
            matching: "audio",
            capabilities: .pro,
            includeWorkshopOnline: false
        )
        let weatherItems = SettingsNavigation.filteredResults(
            matching: "weather",
            capabilities: .pro,
            includeWorkshopOnline: false
        )

        #expect(audioItems.map(\.destination).contains(.audioResponse))
        #expect(!audioItems.map(\.destination).contains(.weather))
        #expect(weatherItems.map(\.destination).contains(.weather))
        #expect(!weatherItems.map(\.destination).contains(.audioResponse))
    }

    @Test("Settings search keeps performance concise and hides global reset")
    func settingsSearchKeepsPerformanceConciseAndHidesGlobalReset() {
        let performanceItems = SettingsNavigation.filteredResults(
            matching: "power",
            capabilities: .pro,
            includeWorkshopOnline: false
        )
        let resetItems = SettingsNavigation.filteredResults(
            matching: "reset defaults",
            capabilities: .pro,
            includeWorkshopOnline: false
        )

        #expect(performanceItems.map(\.title).contains("Performance"))
        #expect(!performanceItems.map(\.title).contains("Performance & Power"))
        #expect(resetItems.map(\.destination) == [.displayDefaults])
    }

    @Test("Lite settings hide Pro-only storage")
    func liteSettingsHideProOnlyStorage() {
        let items = SettingsNavigation.availableItems(
            capabilities: .lite,
            includeWorkshopOnline: true
        )

        #expect(!items.map(\.destination).contains(.storage))
        #expect(!items.map(\.destination).contains(.workshopSetup))
    }

    @Test("Lite settings hide the Pro-only audio response page")
    func liteSettingsHideAudioResponse() {
        let liteItems = SettingsNavigation.availableItems(
            capabilities: .lite,
            includeWorkshopOnline: false
        )
        let proItems = SettingsNavigation.availableItems(
            capabilities: .pro,
            includeWorkshopOnline: false
        )

        #expect(!liteItems.map(\.destination).contains(.audioResponse))
        #expect(proItems.map(\.destination).contains(.audioResponse))
    }

    @Test("Display defaults and diagnostics are searchable")
    func displayDefaultsAndDiagnosticsAreSearchable() {
        let defaultsItems = SettingsNavigation.filteredResults(
            matching: "playback defaults",
            capabilities: .pro,
            includeWorkshopOnline: false
        )
        let diagnosticsItems = SettingsNavigation.filteredResults(
            matching: "diagnostics",
            capabilities: .pro,
            includeWorkshopOnline: false
        )

        #expect(defaultsItems.map(\.destination).contains(.displayDefaults))
        #expect(diagnosticsItems.map(\.destination).contains(.advanced))
    }

    @Test("Localized frame-rate search reaches display defaults")
    func localizedFrameRateSearchReachesDisplayDefaults() {
        let items = SettingsNavigation.filteredResults(
            matching: "帧率",
            capabilities: .pro,
            includeWorkshopOnline: false
        )

        #expect(items.map(\.destination).contains(.displayDefaults))
    }

    @Test("Search results expose the matched setting hint")
    func searchResultsExposeMatchedSettingHint() {
        let item = SettingsNavigation.availableItems(
            capabilities: .pro,
            includeWorkshopOnline: false
        ).first { $0.destination == .displayDefaults }

        #expect(item?.searchMatchHint(matching: "frame rate") == "Frame Rate")
    }

    @Test("Search results expose section anchors for deep links")
    func searchResultsExposeSectionAnchorsForDeepLinks() {
        let displayResults = SettingsNavigation.filteredResults(
            matching: "frame rate",
            capabilities: .pro,
            includeWorkshopOnline: false
        )
        // The Workshop setup page is three sections now, so each of its three
        // concerns has to land on its own anchor rather than one shared "Setup".
        let connectionResults = SettingsNavigation.filteredResults(
            matching: "steamcmd",
            capabilities: .pro,
            includeWorkshopOnline: true
        )
        let apiKeyResults = SettingsNavigation.filteredResults(
            matching: "api key",
            capabilities: .pro,
            includeWorkshopOnline: true
        )
        let assetsResults = SettingsNavigation.filteredResults(
            matching: "engine assets",
            capabilities: .pro,
            includeWorkshopOnline: true
        )
        let storageResults = SettingsNavigation.filteredResults(
            matching: "video cache",
            capabilities: .pro,
            includeWorkshopOnline: false
        )

        #expect(displayResults.first { $0.destination == .displayDefaults }?.anchor == .displayDefaultsVideo)
        #expect(connectionResults.first { $0.destination == .workshopSetup }?.anchor == .workshopConnection)
        #expect(apiKeyResults.first { $0.destination == .workshopSetup }?.anchor == .workshopSetup)
        #expect(assetsResults.first { $0.destination == .workshopSetup }?.anchor == .workshopAssets)
        #expect(storageResults.first { $0.destination == .storage }?.anchor == .storageCaches)
    }

    @Test("Search result identity includes anchor")
    func searchResultIdentityIncludesAnchor() {
        let result = SettingsNavigationSearchResult(
            item: SettingsNavigationItem(
                destination: .displayDefaults,
                title: "Display Defaults",
                systemImage: "rectangle.3.group",
                keywords: []
            ),
            anchor: .displayDefaultsScene,
            matchHint: "Scene"
        )

        #expect(result.id == "displayDefaults:displayDefaultsScene")
    }

    @Test("Lite search does not expose unavailable display default sections")
    func liteSearchDoesNotExposeUnavailableDisplayDefaultSections() {
        let sceneResults = SettingsNavigation.filteredResults(
            matching: "scene",
            capabilities: .lite,
            includeWorkshopOnline: false
        )

        #expect(!sceneResults.contains { $0.anchor == .displayDefaultsScene })
        #expect(!sceneResults.map(\.destination).contains(.displayDefaults))
    }

    @Test("Archive search uses always visible storage anchor")
    func archiveSearchUsesAlwaysVisibleStorageAnchor() {
        let results = SettingsNavigation.filteredResults(
            matching: "archives",
            capabilities: .pro,
            includeWorkshopOnline: false
        )

        #expect(results.first { $0.destination == .storage }?.anchor == .storageDashboard)
    }
}
