#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

@Suite("Workshop browse filters → query tags")
struct BrowseFilterTests {

    @Test("Workshop sort modes map to Steam QueryFiles query_type codes")
    func sortQueryTypeCodes() {
        #expect(WorkshopSortMode.mostPopular.queryTypeCode == 3)
        #expect(WorkshopSortMode.topRated.queryTypeCode == 0)
        #expect(WorkshopSortMode.newest.queryTypeCode == 1)
        #expect(WorkshopSortMode.lastUpdated.queryTypeCode == 21)
        #expect(WorkshopSortMode.mostSubscribed.queryTypeCode == 9)
        #expect(WorkshopSortMode.search.queryTypeCode == 12)
    }

    @Test("Workshop time frames map to Steam QueryFiles days values")
    func timeFrameDays() {
        #expect(WorkshopTimeFrame.today.days == 1)
        #expect(WorkshopTimeFrame.oneWeek.days == 7)
        #expect(WorkshopTimeFrame.thirtyDays.days == 30)
        #expect(WorkshopTimeFrame.threeMonths.days == 90)
        #expect(WorkshopTimeFrame.sixMonths.days == 180)
        #expect(WorkshopTimeFrame.oneYear.days == 365)
        #expect(WorkshopTimeFrame.allTime.days == nil)
    }

    @Test("Most popular request preserves time frame days")
    func mostPopularRequestPreservesTimeFrameDays() {
        let request = WorkshopQueryRequest(sort: .mostPopular, timeFrame: .sixMonths)

        #expect(request.sort == .mostPopular)
        #expect(request.timeFrame == .sixMonths)
        #expect(request.days == 180)
    }

    @Test("Top rated all time ignores incompatible time frame")
    func topRatedAllTimeIgnoresIncompatibleTimeFrame() {
        let request = WorkshopQueryRequest(sort: .topRated, timeFrame: .sixMonths)

        #expect(request.sort == .topRated)
        #expect(request.timeFrame == .allTime)
        #expect(request.days == nil)
    }

    @Test("Search keeps the user-selected sort as query_type")
    func searchKeepsUserSelectedSort() {
        let request = WorkshopQueryRequest(sort: .mostSubscribed, searchText: "cyberpunk")

        #expect(request.sort == .mostSubscribed)

        let values = Dictionary(
            uniqueKeysWithValues: request.apiQueryItems(apiKey: "FAKEKEY", appID: 431960).map { ($0.name, $0.value ?? "") }
        )
        #expect(values["query_type"] == "9")
        #expect(values["search_text"] == "cyberpunk")
    }

    @Test("Relevance sort combines with search text")
    func relevanceSortCombinesWithSearchText() {
        let request = WorkshopQueryRequest(sort: .search, searchText: "city")

        #expect(request.sort == .search)
    }

    @Test("Relevance sort without search text falls back to top rated")
    func relevanceWithoutSearchTextFallsBack() {
        let request = WorkshopQueryRequest(sort: .search)

        #expect(request.sort == .topRated)
    }

    @Test("Search with Most Popular keeps the time frame days")
    func searchWithMostPopularKeepsTimeFrameDays() {
        let request = WorkshopQueryRequest(sort: .mostPopular, searchText: "city", timeFrame: .oneWeek)

        #expect(request.sort == .mostPopular)
        #expect(request.days == 7)
    }

    @Test("A persisted all-deselected category restores to all-selected")
    func persistedEmptyCategoryRestoresToAllSelected() {
        func restoreTypes(_ raw: [String]) -> Set<WorkshopContentTypeFilter> {
            BrowseViewModel.restoredSelection(
                raw: raw,
                all: WorkshopContentTypeFilter.selectableCases,
                decode: WorkshopContentTypeFilter.init(rawValue:)
            )
        }
        let everything = Set(WorkshopContentTypeFilter.selectableCases)

        // Written by a pre-snap-back build that let the user deselect them all.
        #expect(restoreTypes([]) == everything)
        // Every raw value stopped decoding (renamed cases).
        #expect(restoreTypes(["gone", "obsolete"]) == everything)
        // A genuine narrowing survives untouched.
        #expect(restoreTypes(["scene"]) == [.scene])
        #expect(restoreTypes(["scene", "bogus"]) == [.scene])
    }

    @Test("Query request emits sort and time frame as API query items")
    func queryRequestAPIQueryItemsIncludeSortAndTimeFrame() {
        let request = WorkshopQueryRequest(
            sort: .mostPopular,
            page: 2,
            numPerPage: 25,
            timeFrame: .threeMonths,
            requiredTags: ["Scene"],
            excludedTags: ["Application"]
        )

        let values = Dictionary(
            uniqueKeysWithValues: request.apiQueryItems(apiKey: "FAKEKEY", appID: 431960).map { ($0.name, $0.value ?? "") }
        )

        #expect(values["appid"] == "431960")
        #expect(values["query_type"] == "3")
        #expect(values["days"] == "90")
        #expect(values["page"] == "2")
        #expect(values["numperpage"] == "25")
        #expect(values["requiredtags[0]"] == "Scene")
        #expect(values["match_all_tags"] == "true")
        #expect(values["excludedtags[0]"] == "Application")
    }

    @Test("match_all_tags is stated whenever there are required tags, and omitted otherwise")
    func matchAllTagsStatedWithRequiredTags() {
        let anyOf = WorkshopQueryRequest(
            sort: .topRated,
            requiredTags: ["Anime", "Landscape"],
            matchAllTags: false
        )
        let anyOfValues = Dictionary(
            uniqueKeysWithValues: anyOf.apiQueryItems(apiKey: "FAKEKEY", appID: WorkshopQueryService.wallpaperEngineAppID).map { ($0.name, $0.value ?? "") }
        )
        #expect(anyOfValues["match_all_tags"] == "false")

        let noTags = WorkshopQueryRequest(sort: .topRated, excludedTags: ["Application"])
        let noTagNames = Set(noTags.apiQueryItems(apiKey: "FAKEKEY", appID: WorkshopQueryService.wallpaperEngineAppID).map(\.name))
        #expect(!noTagNames.contains("match_all_tags"))
    }

    @Test("match_all_tags is part of the cache key")
    func matchAllTagsChangesCacheKey() {
        let all = WorkshopQueryRequest(sort: .topRated, requiredTags: ["Anime"], matchAllTags: true)
        let any = WorkshopQueryRequest(sort: .topRated, requiredTags: ["Anime"], matchAllTags: false)
        #expect(WorkshopQueryCacheKey.canonical(all) != WorkshopQueryCacheKey.canonical(any))
    }

    @Test("All-time time frame omits days from API query items")
    func allTimeOmitsDaysAPIQueryItem() {
        let request = WorkshopQueryRequest(sort: .topRated, timeFrame: .allTime)

        let names = Set(request.apiQueryItems(apiKey: "FAKEKEY", appID: 431960).map(\.name))

        #expect(!names.contains("days"))
    }

    @Test("Last updated omits incompatible days API query item")
    func lastUpdatedOmitsIncompatibleDaysAPIQueryItem() {
        let request = WorkshopQueryRequest(sort: .lastUpdated, timeFrame: .threeMonths)

        let values = Dictionary(
            uniqueKeysWithValues: request.apiQueryItems(apiKey: "FAKEKEY", appID: 431960).map { ($0.name, $0.value ?? "") }
        )

        #expect(values["query_type"] == "21")
        #expect(values["days"] == nil)
    }

    @Test("Content-type filter maps to the right tag")
    func contentTypeTags() {
        #expect(WorkshopContentTypeFilter.scene.requiredTags == ["Scene"])
        #expect(WorkshopContentTypeFilter.video.requiredTags == ["Video"])
        #expect(WorkshopContentTypeFilter.web.requiredTags == ["Web"])
        #expect(WorkshopContentTypeFilter.scene.tag == "Scene")
    }

    @Test("Selectable cases exclude the no-restriction sentinels")
    func selectableCases() {
        #expect(WorkshopContentTypeFilter.selectableCases == [.scene, .video, .web])
        #expect(!WorkshopResolutionFilter.selectableCases.contains(.any))
    }

    @Test("Maturity defaults to all-selected (show everything; narrow by deselecting)")
    func ageRatingDefault() {
        #expect(WorkshopAgeRatingFilter.defaultSelection == Set(WorkshopAgeRatingFilter.allCases))
        #expect(WorkshopAgeRatingFilter.mature.tag == "Mature")
    }

    @Test("Application is always excluded from every query")
    func applicationAlwaysExcluded() {
        #expect(BrowseViewModel.alwaysExcludedTags == ["Application"])
    }

    @Test("Preset is excluded from Browse unless the user opts in via Settings → Workshop")
    func presetExclusionFollowsSetting() {
        let hidden = BrowseViewModel.excludedTags(showsPresets: false)
        #expect(hidden.contains("Preset"))
        #expect(hidden.contains("Application"))

        let shown = BrowseViewModel.excludedTags(showsPresets: true)
        #expect(!shown.contains("Preset"))
        #expect(shown.contains("Application"))
    }

    @Test("Mature maturity tag drives the spoiler-blur flag (case-insensitive)")
    func matureRatingDetection() {
        func item(tags: [String]) -> WorkshopQueryItem {
            WorkshopQueryItem(
                id: 1, title: "t", shortDescription: "", creatorID: nil, creatorPersonaName: nil,
                previewImageURL: nil, fileSizeBytes: nil, timeUpdated: nil,
                subscriptionCount: nil, voteScore: nil, tags: tags,
                visibility: .public, isBanned: false,
                steamCommunityURL: URL(string: "https://steamcommunity.com/")!
            )
        }
        #expect(item(tags: ["Scene", "Mature"]).isMatureRated)
        #expect(item(tags: ["mature"]).isMatureRated)
        #expect(!item(tags: ["Scene", "Questionable"]).isMatureRated)
        #expect(!item(tags: ["Everyone"]).isMatureRated)
    }

    @Test("excludedtags are canonicalized: trimmed, de-duplicated, sorted, exact-case")
    func excludedTagsCanonicalize() {
        let request = WorkshopQueryRequest(
            sort: .topRated,
            excludedTags: ["Mature", "Anime", "Application", "Mature", " Memes "]
        )
        #expect(request.requiredTags.isEmpty)
        #expect(request.excludedTags == ["Anime", "Application", "Mature", "Memes"])
    }

    @Test("Page count is ceil(total/perPage) capped at Steam's page limit of 1000")
    func pageCountCappedAtSteamLimit() {
        #expect(BrowseViewModel.pageCount(totalAvailable: 600_000, perPage: 50) == 1000)
        #expect(BrowseViewModel.pageCount(totalAvailable: 120, perPage: 50) == 3)
        #expect(BrowseViewModel.pageCount(totalAvailable: 50_000, perPage: 50) == 1000)
        #expect(BrowseViewModel.pageCount(totalAvailable: 50_001, perPage: 50) == 1000)
        #expect(BrowseViewModel.pageCount(totalAvailable: 1, perPage: 50) == 1)
    }

    @Test("Toggling the last selected chip snaps back to all-selected")
    func toggleSnapBackOnEmpty() {
        let all = WorkshopContentTypeFilter.selectableCases

        // Deselecting the only member would leave an empty set → snap back to full.
        #expect(BrowseViewModel.toggled(.scene, in: [.scene], all: all) == Set(all))

        // Normal toggle semantics unchanged.
        #expect(BrowseViewModel.toggled(.scene, in: Set(all), all: all) == [.video, .web])
        #expect(BrowseViewModel.toggled(.scene, in: [.video], all: all) == [.scene, .video])
    }

    @Test("Every filter case is identifiable + has a display name")
    func filterMetadata() {
        #expect(WorkshopContentTypeFilter.allCases.allSatisfy { !$0.displayName.isEmpty })
        #expect(WorkshopAgeRatingFilter.allCases.allSatisfy { !$0.displayName.isEmpty })
        #expect(Set(WorkshopContentTypeFilter.allCases.map(\.id)).count == WorkshopContentTypeFilter.allCases.count)
    }
}

@Suite("Workshop browse request shape")
@MainActor
struct BrowseRequestShapeTests {
    /// Keyed: the genre facet only takes the `requiredtags` + `match_all_tags`
    /// form on the QueryFiles path, so these cases have to hold a key.
    private static func makeModel(_ name: String) throws -> (BrowseViewModel, TestScratch.DefaultsSuite) {
        let suite = try TestScratch.defaultsSuite("workshop.browse.request.\(name)")
        let services = WorkshopServices()
        services.hasWebAPIKey = true
        return (BrowseViewModel(services: services, defaults: suite.defaults), suite)
    }

    @Test("A tag-scoped browse still excludes the deselected maturity tag")
    func pinnedTagKeepsMaturityExclusion() throws {
        let (model, suite) = try Self.makeModel("pinnedTag")
        defer { suite.discard() }

        model.toggleAgeRating(.mature)
        model.applyScopeForTesting(pinnedTag: "Anime")
        let request = model.makeRequest(page: 1)

        #expect(request.requiredTags == ["Anime"])
        #expect(request.matchAllTags)
        #expect(request.excludedTags.contains("Mature"))
        #expect(request.excludedTags.contains("Application"))
    }

    @Test("A creator-scoped browse still excludes the deselected maturity tag")
    func creatorScopeKeepsMaturityExclusion() throws {
        let (model, suite) = try Self.makeModel("creator")
        defer { suite.discard() }

        model.toggleAgeRating(.mature)
        model.applyScopeForTesting(creator: .init(steamID: "76561198000000001", name: nil))
        let request = model.makeRequest(page: 1)

        #expect(request.creatorSteamID == "76561198000000001")
        #expect(request.excludedTags.contains("Mature"))
        #expect(request.excludedTags.contains("Application"))

        let url = try WorkshopQueryService.buildUserFilesURL(
            for: request,
            steamID: "76561198000000001",
            apiKey: "0123456789abcdef0123456789abcdef"
        )
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.contains { $0.name.hasPrefix("excludedtags[") && $0.value == "Mature" })
    }

    @Test("Isolating one genre requires it instead of excluding the other 24")
    func isolatedGenreBecomesRequiredTag() throws {
        let (model, suite) = try Self.makeModel("isolateGenre")
        defer { suite.discard() }

        model.isolateGenre("Anime")
        let request = model.makeRequest(page: 1)

        #expect(request.requiredTags == ["Anime"])
        #expect(!request.matchAllTags)
        #expect(!request.excludedTags.contains { WorkshopGenre.allTags.contains($0) })

        let values = Dictionary(
            uniqueKeysWithValues: request.apiQueryItems(
                apiKey: "FAKEKEY", appID: WorkshopQueryService.wallpaperEngineAppID
            ).map { ($0.name, $0.value ?? "") }
        )
        #expect(values["requiredtags[0]"] == "Anime")
        #expect(values["match_all_tags"] == "false")
    }

    @Test("Two selected genres are both required, matched as any-of")
    func twoGenresAreRequiredAnyOf() throws {
        let (model, suite) = try Self.makeModel("twoGenres")
        defer { suite.discard() }

        model.isolateGenre("Anime")
        model.toggleGenre("Landscape")
        let request = model.makeRequest(page: 1)

        #expect(request.requiredTags == ["Anime", "Landscape"])
        #expect(!request.matchAllTags)
        #expect(!request.excludedTags.contains { WorkshopGenre.allTags.contains($0) })
    }

    @Test("Partition facets keep excluding the deselected members")
    func partitionFacetsStillExclude() throws {
        let (model, suite) = try Self.makeModel("partitions")
        defer { suite.discard() }

        model.isolateType(.scene)
        model.isolateResolution(.ultraHD4K)
        let request = model.makeRequest(page: 1)

        #expect(request.excludedTags.contains("Video"))
        #expect(request.excludedTags.contains("Web"))
        #expect(request.excludedTags.contains("1920 x 1080"))
        #expect(!request.requiredTags.contains("Scene"))
        #expect(!request.requiredTags.contains("3840 x 2160"))
    }

    @Test("A full genre selection filters nothing")
    func allGenresSelectedFiltersNothing() throws {
        let (model, suite) = try Self.makeModel("allGenres")
        defer { suite.discard() }

        let request = model.makeRequest(page: 1)

        #expect(request.requiredTags.isEmpty)
        #expect(!request.excludedTags.contains { WorkshopGenre.allTags.contains($0) })
    }

    /// The public browse page has no `match_all_tags` and multiple
    /// `requiredtags[]` there are believed to AND, so the keyless path keeps the
    /// exclusion form the keyed path left behind.
    @Test("A keyless genre narrowing excludes the unselected genres")
    func keylessGenreUsesExclusionForm() throws {
        let suite = try TestScratch.defaultsSuite("workshop.browse.request.keylessGenre")
        defer { suite.discard() }
        // No API key: `usesKeylessSearch` is what selects the public page.
        let model = BrowseViewModel(services: WorkshopServices(), defaults: suite.defaults)

        model.isolateGenre("Anime")
        let request = model.makeRequest(page: 1)

        #expect(model.usesKeylessSearch)
        #expect(request.requiredTags.isEmpty)
        #expect(request.excludedTags.contains("Landscape"))
        #expect(!request.excludedTags.contains("Anime"))
    }

    /// Control: the same narrowing on the keyed path stays in the required-tag form.
    @Test("Control: a keyed genre narrowing still requires the selected genre")
    func keyedGenreStillUsesRequiredTags() throws {
        let (model, suite) = try Self.makeModel("keyedGenre")
        defer { suite.discard() }

        model.isolateGenre("Anime")
        let request = model.makeRequest(page: 1)

        #expect(!model.usesKeylessSearch)
        #expect(request.requiredTags == ["Anime"])
        #expect(!request.excludedTags.contains("Landscape"))
    }

    /// Synchronous throughout: `WorkshopServices` refreshes `hasWebAPIKey` from
    /// its own MainActor task, which cannot interleave without a suspension point.
    @Test("Next stays live when the client filter shrank a full page")
    func nextPageUsesRawPageCount() throws {
        let suite = try TestScratch.defaultsSuite("workshop.browse.request.rawCount")
        defer { suite.discard() }
        let services = WorkshopServices()
        services.hasWebAPIKey = true
        let model = BrowseViewModel(services: services, defaults: suite.defaults)

        // Steam returned a full page; one item was an Application/Preset and
        // never reached `items`.
        model.lastFetchedRawItemCount = 50
        #expect(model.items.isEmpty)
        #expect(model.canGoNextPage)

        model.lastFetchedRawItemCount = 49
        #expect(!model.canGoNextPage)
    }
}

@Suite("Workshop presets-in-Browse setting persistence")
struct WorkshopPresetsSettingTests {
    @Test("A settings blob without the key decodes as hidden (off)")
    func legacyBlobDecodesAsHidden() throws {
        let legacy = Data(#"{"showInDock":true}"#.utf8)
        let decoded = try JSONDecoder().decode(GlobalSettings.self, from: legacy)
        #expect(!decoded.showsWorkshopPresetsInBrowse)
    }

    @Test("An explicit opt-in survives a round trip")
    func optInRoundTrips() throws {
        var settings = GlobalSettings()
        settings.showsWorkshopPresetsInBrowse = true
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(GlobalSettings.self, from: data)
        #expect(decoded.showsWorkshopPresetsInBrowse)
    }
}

/// Source contracts for the Browse first-paint path. Each of these is a wiring
/// fact between a view and a view model that only a rendered pane could
/// otherwise show, so it is pinned where it is written.
@Suite("Workshop browse first-paint wiring")
struct BrowseFirstPaintWiringTests {
    @Test("reload() keeps the previous grid until the new page arrives")
    func reloadDoesNotClearItems() throws {
        let source = try RepositoryRoot.source("LiveWallpaper/Views/Workshop/BrowseViewModel.swift")
        let start = try #require(source.range(of: "func reload() async {"))
        let rest = source[start.upperBound...]
        let end = try #require(rest.range(of: "\n    }"))
        let body = String(rest[..<end.lowerBound])

        #expect(!body.contains("items = []"), "clearing here is what flashes the skeleton on every filter change")
    }

    @Test("The skeleton is gated on never having loaded a page, not on an empty grid")
    func skeletonGateUsesLoadedFlag() throws {
        let pane = try RepositoryRoot.source("LiveWallpaper/Views/Workshop/BrowsePane.swift")
        #expect(pane.contains("viewModel.hasLoadedPage"))
    }

    @Test("The request counter counts HTTP requests, not loading flags")
    func counterCountsNetworkRequests() throws {
        let pane = try RepositoryRoot.source("LiveWallpaper/Views/Workshop/BrowsePane.swift")
        let service = try RepositoryRoot.source("LiveWallpaper/Infrastructure/Workshop/WorkshopQueryService.swift")

        #expect(!pane.contains("WorkshopRequestCounter.increment"))
        #expect(service.contains("WorkshopRequestCounter.increment("))
    }

    @Test("Toggling “Show presets as wallpapers” reaches Browse through a notification")
    func presetVisibilityNotificationIsWired() throws {
        let names = try RepositoryRoot.source(
            "Packages/LiveWallpaperCore/Sources/LiveWallpaperCore/App/NotificationNames.swift"
        )
        let settings = try RepositoryRoot.source("LiveWallpaper/Views/Settings/WorkshopSettingsView.swift")
        let pane = try RepositoryRoot.source("LiveWallpaper/Views/Workshop/BrowsePane.swift")
        let backup = try RepositoryRoot.source("LiveWallpaper/Views/Settings/BackupSection.swift")
        let advanced = try RepositoryRoot.source("LiveWallpaper/Views/Settings/AdvancedSection.swift")

        #expect(names.contains("workshopPresetVisibilityDidChange"))
        #expect(settings.contains(".workshopPresetVisibilityDidChange"))
        #expect(pane.contains(".workshopPresetVisibilityDidChange"))
        // Restoring or resetting the store rewrites the setting behind the
        // toggle's back, so both re-post it like the other cross-window ones.
        #expect(backup.contains("postSettingsNotificationAsync(.workshopPresetVisibilityDidChange)"))
        #expect(advanced.contains("postSettingsNotificationAsync(.workshopPresetVisibilityDidChange)"))
    }
}
#endif
