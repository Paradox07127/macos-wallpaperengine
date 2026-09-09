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

    /// The Web API treats an omitted `days` as `days=1`, so a Most Popular
    /// request must always state it; the page has no "trend, all time" — it
    /// defaults to seven days.
    @Test("Most Popular without a time frame asks for seven days explicitly")
    func mostPopularDefaultsToSevenDays() {
        let request = WorkshopQueryRequest(sort: .mostPopular)
        let values = Dictionary(
            uniqueKeysWithValues: request.apiQueryItems(apiKey: "FAKEKEY", appID: 431_960).map { ($0.name, $0.value ?? "") }
        )
        #expect(values["days"] == "7")
    }

    @Test("Most Popular + All Time normalises to one week")
    func mostPopularAllTimeNormalisesToOneWeek() {
        let request = WorkshopQueryRequest(sort: .mostPopular, timeFrame: .allTime)
        #expect(request.timeFrame == .oneWeek)
        #expect(request.days == 7)
        #expect(
            WorkshopQueryCacheKey.canonical(request)
                == WorkshopQueryCacheKey.canonical(WorkshopQueryRequest(sort: .mostPopular, timeFrame: .oneWeek))
        )
    }

    @Test("Control: Top Rated never sends days, whatever time frame is passed")
    func topRatedNeverSendsDays() {
        let request = WorkshopQueryRequest(sort: .topRated, timeFrame: .oneWeek)
        let names = Set(request.apiQueryItems(apiKey: "FAKEKEY", appID: 431_960).map(\.name))
        #expect(!names.contains("days"))
        #expect(request.days == nil)
    }

    @Test("Keyless trend URL carries days=7 by default")
    func keylessTrendURLCarriesDays() throws {
        let url = WorkshopPublicBrowseURL.url(for: WorkshopQueryRequest(sort: .mostPopular), appID: 431_960)
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.contains { $0.name == "days" && $0.value == "7" })
    }

    /// Steam's Resolution tag group, verbatim (25 values, verified 2026-09-07).
    static let steamResolutionTags: [String] = [
        "Standard Definition", "1280 x 720", "1366 x 768", "1920 x 1080", "2560 x 1440", "3840 x 2160",
        "Ultrawide Standard Definition", "Ultrawide 2560 x 1080", "Ultrawide 3440 x 1440",
        "Dual Standard Definition", "Dual 3840 x 1080", "Dual 5120 x 1440", "Dual 7680 x 2160",
        "Triple Standard Definition", "Triple 4096 x 768", "Triple 5760 x 1080", "Triple 7680 x 1440", "Triple 11520 x 2160",
        "Portrait Standard Definition", "Portrait 720 x 1280", "Portrait 1080 x 1920", "Portrait 1440 x 2560", "Portrait 2160 x 3840",
        "Other resolution", "Dynamic resolution",
    ]

    @Test("A persisted resolution selection survives, and undecodable raw values snap back to all")
    func persistedResolutionSelectionRestores() {
        func restore(_ raw: [String]) -> Set<WorkshopResolutionFilter> {
            BrowseViewModel.restoredSelection(
                raw: raw,
                all: WorkshopResolutionFilter.selectableCases,
                decode: WorkshopResolutionFilter.init(rawValue:)
            )
        }
        let everything = Set(WorkshopResolutionFilter.selectableCases)
        #expect(restore([]) == everything)
        #expect(restore(["gone"]) == everything)
        // Raw values written by the pre-bucket build keep decoding.
        let survivor = restore(["fullHD1080"])
        #expect(survivor.count == 1)
        #expect(survivor.first?.rawValue == "fullHD1080")
    }

    /// The seven-bucket build persisted "everything" as seven raw values under
    /// the v1 key; read against nine buckets that is a narrowing that silently
    /// drops Triple and Other. The store starts over under v2.
    @Test("A v1 all-selected resolution store is retired, not read as a narrowing")
    @MainActor
    func legacyResolutionStoreIsRetired() throws {
        let suite = try TestScratch.defaultsSuite("workshop.browse.filter.resolutions.v1Retired")
        defer { suite.discard() }
        let v1Key = "loomscreen.workshop.filter.resolutions.v1"
        suite.defaults.set(
            ["standardDefinition", "fullHD1080", "quadHD1440", "ultraHD4K", "ultrawide", "portrait", "dual"],
            forKey: v1Key
        )

        let model = BrowseViewModel(services: WorkshopServices(), defaults: suite.defaults)

        #expect(model.selectedResolutions.count == 9)
        #expect(model.selectedResolutions == Set(WorkshopResolutionFilter.selectableCases))
        #expect(suite.defaults.object(forKey: v1Key) == nil)
    }

    @Test("Control: a v2 resolution store is restored as written")
    @MainActor
    func v2ResolutionStoreRestores() throws {
        let suite = try TestScratch.defaultsSuite("workshop.browse.filter.resolutions.v2Restores")
        defer { suite.discard() }
        suite.defaults.set(["ultraHD4K"], forKey: "loomscreen.workshop.filter.resolutions.v2")

        let model = BrowseViewModel(services: WorkshopServices(), defaults: suite.defaults)

        #expect(model.selectedResolutions == [.ultraHD4K])
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

    @Test("Maturity defaults to Everyone only, the way the signed-out page browses")
    func ageRatingDefault() {
        #expect(WorkshopAgeRatingFilter.defaultSelection == [.everyone])
        #expect(WorkshopAgeRatingFilter.mature.tag == "Mature")
    }

    @Test("Application and Asset are always excluded from every query")
    func applicationAndAssetAlwaysExcluded() {
        #expect(BrowseViewModel.alwaysExcludedTags == ["Application", "Asset"])
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
                id: 1, rawTitle: "t", shortDescription: "", creatorID: nil, creatorPersonaName: nil,
                previewImageURL: nil, fileSizeBytes: nil, timeUpdated: nil,
                subscriptionCount: nil, rating: nil, tags: tags,
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

    /// Derived labels used to carry the prefixed tags: `Triple 5760 x 1080` is
    /// 5.33:1, which the ratio table reads as Dual, and `Ultrawide Standard
    /// Definition` has no numbers at all.
    @Test("The card badge keys on Steam's real resolution tags")
    @MainActor
    func resolutionBadgeKeysOnSteamTags() {
        #expect(BrowseCard.resolutionShortLabel(for: ["Ultrawide 3440 x 1440"]) == "UW")
        #expect(BrowseCard.resolutionShortLabel(for: ["Ultrawide Standard Definition"]) == "UW")
        #expect(BrowseCard.resolutionShortLabel(for: ["Triple 5760 x 1080"]) == "Triple")
        #expect(BrowseCard.resolutionShortLabel(for: ["Portrait 1080 x 1920"]) == "Portrait")
        #expect(BrowseCard.resolutionShortLabel(for: ["1920 x 1080"]) == "1080p")

        let known = Set(BrowseCard.knownResolutionLabels.keys)
        #expect(known.isSubset(of: Set(Self.steamResolutionTags)))
        #expect(!known.contains("3440 x 1440"))
        #expect(!known.contains("5120 x 1440"))
    }

    // MARK: - W4-A: search target + Miscellaneous at the request layer

    @Test("Miscellaneous is Steam's facet minus Asset Pack, in the page's order")
    func miscellaneousTagList() {
        #expect(WorkshopMiscellaneousFilter.allTags == [
            "Approved", "Audio responsive", "3D", "Customizable", "Puppet Warp", "HDR",
            "Media Integration", "User Shortcut", "Video Texture",
        ])
    }

    @Test("Miscellaneous tags and the search target are part of the cache key")
    func miscellaneousAndSearchTargetChangeCacheKey() {
        let plain = WorkshopQueryRequest(sort: .topRated, searchText: "cat")
        let approved = WorkshopQueryRequest(sort: .topRated, searchText: "cat", miscellaneousTags: ["Approved"])
        let hdr = WorkshopQueryRequest(sort: .topRated, searchText: "cat", miscellaneousTags: ["HDR"])
        let titleOnly = WorkshopQueryRequest(sort: .topRated, searchText: "cat", searchTextTarget: .titleOnly)

        #expect(WorkshopQueryCacheKey.canonical(plain) != WorkshopQueryCacheKey.canonical(approved))
        #expect(WorkshopQueryCacheKey.canonical(approved) != WorkshopQueryCacheKey.canonical(hdr))
        #expect(WorkshopQueryCacheKey.canonical(plain) != WorkshopQueryCacheKey.canonical(titleOnly))
        // Same values, same key — including a differently ordered tag list.
        #expect(
            WorkshopQueryCacheKey.canonical(approved)
                == WorkshopQueryCacheKey.canonical(WorkshopQueryRequest(sort: .topRated, searchText: "cat", miscellaneousTags: [" Approved "]))
        )
        #expect(
            WorkshopQueryCacheKey.canonical(titleOnly)
                == WorkshopQueryCacheKey.canonical(WorkshopQueryRequest(sort: .topRated, searchText: "cat", searchTextTarget: .titleOnly))
        )
    }

    /// `search_text_target` only means something with a search text, so an
    /// empty search normalises it away — the default browse keeps one cache key.
    @Test("Control: without a search text the search target does not change the cache key")
    func searchTargetWithoutTextIsNormalised() {
        let request = WorkshopQueryRequest(sort: .topRated, searchTextTarget: .titleOnly)
        #expect(request.searchTextTarget == .all)
        #expect(WorkshopQueryCacheKey.canonical(request) == WorkshopQueryCacheKey.canonical(WorkshopQueryRequest(sort: .topRated)))
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
        try makeModel(name, settings: GlobalSettings())
    }

    /// Every read of Settings → Workshop goes through the injected loader: the
    /// presets exclusion used to read the real `SettingsManager`, so whoever
    /// ran the suite with presets shown got a different request shape.
    @Test("The presets exclusion and the default sort both read the injected settings")
    func requestShapeReadsInjectedSettings() throws {
        var settings = GlobalSettings()
        settings.showsWorkshopPresetsInBrowse = true
        settings.workshopDefaultSort = "lastUpdated"
        let (shown, shownSuite) = try Self.makeModel("settings.injected", settings: settings)
        defer { shownSuite.discard() }
        #expect(!shown.makeRequest(page: 1).excludedTags.contains("Preset"))
        #expect(shown.preferredSort == .lastUpdated)

        // Control: the plain `makeModel` is `GlobalSettings()` — presets hidden, Most Popular.
        let (hidden, hiddenSuite) = try Self.makeModel("settings.default")
        defer { hiddenSuite.discard() }
        #expect(hidden.makeRequest(page: 1).excludedTags.contains("Preset"))
        #expect(hidden.preferredSort == .mostPopular)
    }

    @Test("A pre-v2 maturity store is retired so the Everyone default takes effect")
    func retiredAgeStoreFallsBackToTheDefault() throws {
        let suite = try TestScratch.defaultsSuite("workshop.browse.filter.ages.v1")
        defer { suite.discard() }
        let v1Key = "loomscreen.workshop.filter.ages.v1"
        suite.defaults.set(["everyone", "questionable", "mature"], forKey: v1Key)

        let model = BrowseViewModel(services: WorkshopServices(), defaults: suite.defaults)

        #expect(model.selectedAgeRatings == [.everyone])
        #expect(suite.defaults.array(forKey: v1Key) == nil)
    }

    @Test("Striking out the last maturity chip returns to Everyone, not to every rating")
    func maturitySnapsBackToTheDefaultNotToEverything() throws {
        let (model, suite) = try Self.makeModel("maturitySnapBack")
        defer { suite.discard() }
        #expect(model.selectedAgeRatings == [.everyone])

        model.toggleAgeRating(.everyone)
        #expect(model.selectedAgeRatings == [.everyone])
        #expect(model.makeRequest(page: 1).excludedTags.contains("Mature"))

        model.isolateAgeRating(.everyone)
        #expect(model.selectedAgeRatings == [.everyone])

        suite.defaults.set([String](), forKey: "loomscreen.workshop.filter.ages.v2")
        let restored = BrowseViewModel(services: WorkshopServices(), defaults: suite.defaults)
        #expect(restored.selectedAgeRatings == [.everyone])
    }

    @Test("Control: the other facets still snap back to all-selected")
    func otherFacetsStillSnapBackToEverything() throws {
        let (model, suite) = try Self.makeModel("typeSnapBack")
        defer { suite.discard() }
        for type in WorkshopContentTypeFilter.selectableCases where model.selectedTypes.contains(type) {
            model.toggleType(type)
        }
        #expect(model.selectedTypes == Set(WorkshopContentTypeFilter.selectableCases))
    }

    @Test("Control: a v2 maturity store keeps the ratings the user opted into")
    func storedAgeSelectionSurvives() throws {
        let suite = try TestScratch.defaultsSuite("workshop.browse.filter.ages.v2")
        defer { suite.discard() }
        suite.defaults.set(["everyone", "mature"], forKey: "loomscreen.workshop.filter.ages.v2")

        let model = BrowseViewModel(services: WorkshopServices(), defaults: suite.defaults)

        #expect(model.selectedAgeRatings == [.everyone, .mature])
        #expect(!model.makeRequest(page: 1).excludedTags.contains("Mature"))
        #expect(model.makeRequest(page: 1).excludedTags.contains("Questionable"))
    }

    @Test("A tag-scoped browse still excludes the deselected maturity tag")
    func pinnedTagKeepsMaturityExclusion() throws {
        let (model, suite) = try Self.makeModel("pinnedTag")
        defer { suite.discard() }

        // Mature is deselected by default; the scope must not drop that exclusion.
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

    /// GetUserFiles takes `requiredtags` (`CPublishedFile_GetUserFiles_Request`
    /// field 10) and the profile page honours `requiredtags[]` (verified live
    /// 2026-09-07: `Video` kept 4/4, `Scene` 0/4, `Video`+`Abstract` 3/4), so
    /// the Miscellaneous facet follows into a creator scope on both paths.
    @Test("A creator-scoped browse carries the Miscellaneous selection on both paths")
    func creatorScopeCarriesMiscellaneousTags() throws {
        let (model, suite) = try Self.makeModel("creatorMisc")
        defer { suite.discard() }

        model.toggleMiscellaneous("Approved")
        model.applyScopeForTesting(creator: .init(steamID: "76561198000000001", name: nil))
        let request = model.makeRequest(page: 1)
        #expect(request.miscellaneousTags == ["Approved"])

        let keyed = try WorkshopQueryService.buildUserFilesURL(
            for: request,
            steamID: "76561198000000001",
            apiKey: "0123456789abcdef0123456789abcdef"
        )
        let keyedItems = try #require(URLComponents(url: keyed, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(keyedItems.contains { $0.name == "requiredtags[0]" && $0.value == "Approved" })

        let keyless = WorkshopPublicBrowseURL.url(for: request, appID: 431_960)
        let keylessItems = try #require(URLComponents(url: keyless, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(keylessItems.contains { $0.name == "requiredtags[]" && $0.value == "Approved" })
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

    @Test("Isolating 4K excludes every other Steam resolution tag, by its real name")
    func isolatedResolutionExcludesEveryOtherTag() throws {
        let (model, suite) = try Self.makeModel("resolution4K")
        defer { suite.discard() }

        model.isolateResolution(.ultraHD4K)
        let excluded = Set(model.makeRequest(page: 1).excludedTags)

        #expect(excluded.contains("1280 x 720"))
        #expect(excluded.contains("Ultrawide 3440 x 1440"))
        #expect(excluded.contains("Portrait 1080 x 1920"))
        #expect(excluded.contains("Dynamic resolution"))
        #expect(!excluded.contains("3840 x 2160"))
        let steamTags = Set(BrowseFilterTests.steamResolutionTags)
        #expect(excluded.intersection(steamTags).count == 24)
    }

    @Test("Control: a full resolution selection excludes no resolution tag")
    func fullResolutionSelectionExcludesNothing() throws {
        let (model, suite) = try Self.makeModel("resolutionAll")
        defer { suite.discard() }

        let excluded = Set(model.makeRequest(page: 1).excludedTags)
        #expect(excluded.isDisjoint(with: Set(BrowseFilterTests.steamResolutionTags)))
    }

    @Test("Asset packs are excluded on both the keyed and the keyless request")
    func assetExcludedOnBothPaths() throws {
        let (keyed, suite) = try Self.makeModel("asset")
        defer { suite.discard() }
        let keyedValues = keyed.makeRequest(page: 1)
            .apiQueryItems(apiKey: "FAKEKEY", appID: WorkshopQueryService.wallpaperEngineAppID)
        #expect(keyedValues.contains { $0.name.hasPrefix("excludedtags[") && $0.value == "Asset" })

        let keylessSuite = try TestScratch.defaultsSuite("workshop.browse.request.assetKeyless")
        defer { keylessSuite.discard() }
        let keyless = BrowseViewModel(services: WorkshopServices(), defaults: keylessSuite.defaults)
        #expect(keyless.usesKeylessSearch)
        let url = WorkshopPublicBrowseURL.url(for: keyless.makeRequest(page: 1), appID: 431_960)
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.contains { $0.name == "excludedtags[]" && $0.value == "Asset" })
    }

    // MARK: - W4-A control group

    /// Pinned before search-target and Miscellaneous existed: the default
    /// request (every facet fully selected, no search text) must stay this
    /// exact string on both paths — `WorkshopLiveParityTests` builds it too.
    @Test("Control: the default keyed query string is unchanged")
    func defaultKeyedQueryStringIsUnchanged() throws {
        let (model, suite) = try Self.makeModel("defaultShape.keyed")
        defer { suite.discard() }

        var components = try #require(URLComponents(string: "https://api.steampowered.com/IPublishedFileService/QueryFiles/v1/"))
        components.queryItems = model.makeRequest(page: 1).apiQueryItems(apiKey: "FAKEKEY", appID: 431_960)

        #expect(
            components.url?.absoluteString
                == "https://api.steampowered.com/IPublishedFileService/QueryFiles/v1/?key=FAKEKEY&appid=431960&numperpage=50&query_type=3&page=1&return_previews=true&return_tags=true&return_metadata=true&return_short_description=true&return_vote_data=true&return_children=true&days=7&excludedtags%5B0%5D=Application&excludedtags%5B1%5D=Asset&excludedtags%5B2%5D=Mature&excludedtags%5B3%5D=Preset&excludedtags%5B4%5D=Questionable"
        )
    }

    @Test("Control: the default keyless browse URL is unchanged")
    func defaultKeylessURLIsUnchanged() throws {
        let suite = try TestScratch.defaultsSuite("workshop.browse.request.defaultShape.keyless")
        defer { suite.discard() }
        let model = BrowseViewModel(services: WorkshopServices(), defaults: suite.defaults)
        #expect(model.usesKeylessSearch)

        let url = WorkshopPublicBrowseURL.url(for: model.makeRequest(page: 1), appID: 431_960)

        #expect(
            url.absoluteString
                == "https://steamcommunity.com/workshop/browse/?appid=431960&browsesort=trend&p=1&days=7&excludedtags%5B%5D=Application&excludedtags%5B%5D=Asset&excludedtags%5B%5D=Mature&excludedtags%5B%5D=Preset&excludedtags%5B%5D=Questionable"
        )
    }

    // MARK: - W4-A: search target (D7)

    @Test("A title-only search states search_text_target on both paths; the default and an empty search omit it")
    func searchTextTargetOnBothPaths() throws {
        let (keyed, suite) = try Self.makeModel("searchTarget.keyed")
        defer { suite.discard() }

        keyed.searchInput = "cat"
        keyed.searchTextTarget = .titleOnly
        let titleOnly = Self.queryValues(keyed)
        #expect(titleOnly["search_text"] == "cat")
        #expect(titleOnly["search_text_target"] == "1")

        keyed.searchTextTarget = .descriptionOnly
        #expect(Self.queryValues(keyed)["search_text_target"] == "2")

        keyed.searchTextTarget = .all
        #expect(Self.queryValues(keyed)["search_text_target"] == nil)

        // Control: the target is meaningless without a text, so it is not sent.
        keyed.searchTextTarget = .titleOnly
        keyed.searchInput = ""
        #expect(Self.queryValues(keyed)["search_text_target"] == nil)

        let keylessSuite = try TestScratch.defaultsSuite("workshop.browse.request.searchTarget.keyless")
        defer { keylessSuite.discard() }
        let keyless = BrowseViewModel(services: WorkshopServices(), defaults: keylessSuite.defaults)
        #expect(keyless.usesKeylessSearch)
        keyless.searchInput = "cat"
        keyless.searchTextTarget = .titleOnly
        let items = try Self.keylessItems(keyless)
        #expect(items.contains("searchtext=cat"))
        #expect(items.contains("search_text_target=1"))

        keyless.searchTextTarget = .all
        let defaultItems = try Self.keylessItems(keyless)
        #expect(!defaultItems.contains { $0.hasPrefix("search_text_target=") })
    }

    @Test("The search target persists across view models")
    func searchTextTargetPersists() throws {
        let suite = try TestScratch.defaultsSuite("workshop.browse.request.searchTarget.persist")
        defer { suite.discard() }
        let services = WorkshopServices()
        services.hasWebAPIKey = true

        let first = BrowseViewModel(services: services, defaults: suite.defaults)
        #expect(first.searchTextTarget == .all)
        first.searchTextTarget = .descriptionOnly

        let second = BrowseViewModel(services: services, defaults: suite.defaults)
        #expect(second.searchTextTarget == .descriptionOnly)
    }

    // MARK: - W4-A: Miscellaneous (D8 / D24)

    @Test("Miscellaneous alone: required tags with no match_all_tags, on both paths")
    func miscellaneousAloneRequiresTags() throws {
        let (keyed, suite) = try Self.makeModel("misc.approved")
        defer { suite.discard() }

        keyed.toggleMiscellaneous("Approved")
        let values = Self.queryValues(keyed)
        #expect(values["requiredtags[0]"] == "Approved")
        #expect(values["requiredtags[1]"] == nil)
        #expect(values["match_all_tags"] == nil)
        #expect(values["input_json"] == nil)

        // Two feature tags: both required, canonical (sorted) order, still no match_all_tags.
        keyed.toggleMiscellaneous("HDR")
        let two = keyed.makeRequest(page: 1)
            .apiQueryItems(apiKey: "FAKEKEY", appID: 431_960)
            .filter { $0.name.hasPrefix("requiredtags[") }
            .map { "\($0.name)=\($0.value ?? "")" }
        #expect(two == ["requiredtags[0]=Approved", "requiredtags[1]=HDR"])
        #expect(Self.queryValues(keyed)["match_all_tags"] == nil)

        let keylessSuite = try TestScratch.defaultsSuite("workshop.browse.request.misc.approvedKeyless")
        defer { keylessSuite.discard() }
        let keyless = BrowseViewModel(services: WorkshopServices(), defaults: keylessSuite.defaults)
        #expect(keyless.usesKeylessSearch)
        keyless.toggleMiscellaneous("Approved")
        let items = try Self.keylessItems(keyless)
        #expect(items.contains("requiredtags[]=Approved"))
        #expect(!items.contains { $0.hasPrefix("excludedtags[]=") && WorkshopGenre.allTags.contains(String($0.dropFirst("excludedtags[]=".count))) })
    }

    /// "Any of these genres AND each of these features" needs `taggroups`,
    /// which Steam only honours inside `input_json` (measured 2026-09-07:
    /// the query-string forms are ignored or 400, POST is 405).
    @Test("Miscellaneous with a genre narrowing sends key + input_json with taggroups")
    func miscellaneousWithGenreUsesTagGroups() throws {
        let (keyed, suite) = try Self.makeModel("misc.taggroups")
        defer { suite.discard() }

        keyed.isolateGenre("Anime")
        keyed.toggleGenre("Abstract")
        keyed.toggleMiscellaneous("Approved")
        let items = keyed.makeRequest(page: 1).apiQueryItems(apiKey: "FAKEKEY", appID: 431_960)

        #expect(items.map(\.name) == ["key", "input_json"])
        #expect(items[0].value == "FAKEKEY")
        let payload = try #require(items[1].value)
        let json = try #require(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
        let groups = try #require(json["taggroups"] as? [[String: [String]]])
        #expect(groups == [["tags": ["Abstract", "Anime"]], ["tags": ["Approved"]]])
        #expect(json["appid"] as? Int == 431_960)
        #expect(json["query_type"] as? Int == 3)
        #expect(json["days"] as? Int == 7)
        #expect(json["page"] as? Int == 1)
        #expect(json["numperpage"] as? Int == 50)
        for flag in ["return_previews", "return_tags", "return_metadata", "return_short_description", "return_vote_data", "return_children"] {
            #expect(json[flag] as? Bool == true, Comment(rawValue: flag))
        }
        let excluded = try #require(json["excludedtags"] as? [String])
        #expect(Set(excluded) == ["Application", "Asset", "Mature", "Preset", "Questionable"])
        #expect(json["requiredtags"] == nil)
        #expect(json["match_all_tags"] == nil)
        #expect(json["search_text"] == nil)

        // Keyless has no taggroups: features required, unselected genres excluded.
        let keylessSuite = try TestScratch.defaultsSuite("workshop.browse.request.misc.taggroupsKeyless")
        defer { keylessSuite.discard() }
        let keyless = BrowseViewModel(services: WorkshopServices(), defaults: keylessSuite.defaults)
        keyless.isolateGenre("Anime")
        keyless.toggleGenre("Abstract")
        keyless.toggleMiscellaneous("Approved")
        let keylessItems = try Self.keylessItems(keyless)
        #expect(keylessItems.filter { $0.hasPrefix("requiredtags[]=") } == ["requiredtags[]=Approved"])
        let excludedGenres = keylessItems
            .filter { $0.hasPrefix("excludedtags[]=") }
            .map { String($0.dropFirst("excludedtags[]=".count)) }
            .filter { WorkshopGenre.allTags.contains($0) }
        #expect(excludedGenres.count == 23)
        #expect(!excludedGenres.contains("Anime"))
        #expect(!excludedGenres.contains("Abstract"))
    }

    /// Search text, target and the rest of the query travel inside the JSON
    /// on the taggroups path — the same values the query string would carry.
    @Test("input_json carries the search text and target")
    func inputJSONCarriesSearch() throws {
        let (keyed, suite) = try Self.makeModel("misc.taggroups.search")
        defer { suite.discard() }

        keyed.isolateGenre("Anime")
        keyed.toggleMiscellaneous("HDR")
        keyed.searchInput = "city"
        keyed.searchTextTarget = .descriptionOnly
        let items = keyed.makeRequest(page: 2).apiQueryItems(apiKey: "FAKEKEY", appID: 431_960)
        let payload = try #require(items.last?.value)
        let json = try #require(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])

        #expect(json["search_text"] as? String == "city")
        #expect(json["search_text_target"] as? Int == 2)
        #expect(json["page"] as? Int == 2)
        let groups = try #require(json["taggroups"] as? [[String: [String]]])
        #expect(groups == [["tags": ["Anime"]], ["tags": ["HDR"]]])
    }

    /// A pinned tag is one required tag matched with `match_all_tags=true`, so
    /// features join it in the query string — no taggroups needed.
    @Test("Control: a pinned tag plus a feature tag stays a plain all-of query")
    func pinnedTagWithMiscellaneousStaysAllOf() throws {
        let (keyed, suite) = try Self.makeModel("misc.pinned")
        defer { suite.discard() }

        keyed.toggleMiscellaneous("Approved")
        keyed.applyScopeForTesting(pinnedTag: "Anime")
        let values = Self.queryValues(keyed)

        #expect(values["input_json"] == nil)
        #expect(values["requiredtags[0]"] == "Anime")
        #expect(values["requiredtags[1]"] == "Approved")
        #expect(values["match_all_tags"] == "true")
    }

    /// `URLComponents.queryItems` leaves `+` bare, which Steam reads as a
    /// space inside the JSON; the taggroups URL is built with a stricter
    /// encoding and must decode back to the same JSON.
    @Test("The taggroups URL has no bare + and its input_json decodes back")
    func tagGroupsURLEncoding() throws {
        let request = WorkshopQueryRequest(
            sort: .topRated,
            searchText: "a+b&c=d é",
            requiredTags: ["Anime", "Abstract"],
            matchAllTags: false,
            excludedTags: ["Application"],
            miscellaneousTags: ["Approved"]
        )
        let url = try WorkshopQueryService.buildQueryFilesURL(for: request, apiKey: "0123456789abcdef0123456789abcdef")

        let query = try #require(url.query(percentEncoded: true))
        #expect(!query.contains("+"))
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.map(\.name) == ["key", "input_json"])
        let payload = try #require(items[1].value)
        let json = try #require(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
        #expect(json["search_text"] as? String == "a+b&c=d é")
        let groups = try #require(json["taggroups"] as? [[String: [String]]])
        #expect(groups == [["tags": ["Abstract", "Anime"]], ["tags": ["Approved"]]])

        // Control: the plain query string keeps its shape through the same builder.
        let plain = try WorkshopQueryService.buildQueryFilesURL(for: WorkshopQueryRequest(sort: .topRated, excludedTags: ["Application"]), apiKey: "0123456789abcdef0123456789abcdef")
        #expect(plain.absoluteString.hasSuffix("&return_children=true&excludedtags%5B0%5D=Application"))
    }

    @Test("Miscellaneous toggles add and remove; deselecting the last one leaves an empty set")
    func miscellaneousToggle() throws {
        let (model, suite) = try Self.makeModel("misc.toggle")
        defer { suite.discard() }

        #expect(model.selectedMiscellaneous.isEmpty)
        model.toggleMiscellaneous("Approved")
        #expect(model.selectedMiscellaneous == ["Approved"])
        model.toggleMiscellaneous("HDR")
        #expect(model.selectedMiscellaneous == ["Approved", "HDR"])
        model.toggleMiscellaneous("Approved")
        #expect(model.selectedMiscellaneous == ["HDR"])
        // Not the genre rows' snap-back: an empty set is "no feature required".
        model.toggleMiscellaneous("HDR")
        #expect(model.selectedMiscellaneous.isEmpty)
        #expect(model.makeRequest(page: 1).miscellaneousTags.isEmpty)
    }

    @Test("Miscellaneous counts as an active filter only while non-empty")
    func miscellaneousActiveFilterCount() throws {
        let (model, suite) = try Self.makeModel("misc.count")
        defer { suite.discard() }
        let ribbon = BrowseFilterRibbon(viewModel: model, hasWebAPIKey: true)

        #expect(ribbon.activeFilterCount == 0)
        model.toggleMiscellaneous("Approved")
        #expect(ribbon.activeFilterCount == 1)
        model.toggleMiscellaneous("HDR")
        #expect(ribbon.activeFilterCount == 1)
        model.isolateGenre("Anime")
        #expect(ribbon.activeFilterCount == 2)
        model.resetFilters()
        #expect(ribbon.activeFilterCount == 0)

        // Maturity counts once it leaves the Everyone default, in either direction.
        model.toggleAgeRating(.mature)
        #expect(ribbon.activeFilterCount == 1)
        model.toggleAgeRating(.mature)
        #expect(ribbon.activeFilterCount == 0)
    }

    @Test("Miscellaneous persists, drops unknown tags, and is cleared by resetFilters")
    func miscellaneousPersistence() throws {
        let suite = try TestScratch.defaultsSuite("workshop.browse.request.misc.persist")
        defer { suite.discard() }
        let services = WorkshopServices()
        services.hasWebAPIKey = true

        let first = BrowseViewModel(services: services, defaults: suite.defaults)
        first.toggleMiscellaneous("Approved")
        first.toggleMiscellaneous("Video Texture")

        let second = BrowseViewModel(services: services, defaults: suite.defaults)
        #expect(second.selectedMiscellaneous == ["Approved", "Video Texture"])

        // A stored value outside the nine (a retired tag) is dropped, not snapped to all.
        suite.defaults.set(["Approved", "Asset Pack"], forKey: "loomscreen.workshop.filter.miscellaneous.v1")
        #expect(BrowseViewModel(services: services, defaults: suite.defaults).selectedMiscellaneous == ["Approved"])

        second.resetFilters()
        #expect(second.selectedMiscellaneous.isEmpty)
        #expect(BrowseViewModel(services: services, defaults: suite.defaults).selectedMiscellaneous.isEmpty)
    }

    private static func keylessItems(_ model: BrowseViewModel) throws -> [String] {
        let url = WorkshopPublicBrowseURL.url(for: model.makeRequest(page: 1), appID: 431_960)
        return try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            .map { "\($0.name)=\($0.value ?? "")" }
    }

    /// Mirrors the page: its time menu has no "trend, all time" — picking All
    /// Time there switches the sort to Top Rated (All Time).
    @Test("All Time under Most Popular switches the sort to Top Rated")
    func allTimeUnderMostPopularSwitchesToTopRated() throws {
        let (model, suite) = try Self.makeModel("allTime")
        defer { suite.discard() }

        #expect(model.preferredTimeFrame == .oneWeek)
        model.updateSort(.mostPopular)
        model.updateTimeFrame(.thirtyDays)
        model.updateTimeFrame(.allTime)

        #expect(model.preferredSort == .topRated)
        #expect(model.preferredTimeFrame == .thirtyDays)
    }

    // MARK: - Default sort (Settings → Workshop)

    private static func makeModel(_ name: String, settings: GlobalSettings) throws -> (BrowseViewModel, TestScratch.DefaultsSuite) {
        let suite = try TestScratch.defaultsSuite("workshop.browse.request.\(name)")
        let services = WorkshopServices()
        services.hasWebAPIKey = true
        return (BrowseViewModel(services: services, defaults: suite.defaults, loadGlobalSettings: { settings }), suite)
    }

    private static func queryValues(_ model: BrowseViewModel) -> [String: String] {
        Dictionary(
            uniqueKeysWithValues: model.makeRequest(page: 1).apiQueryItems(apiKey: "FAKEKEY", appID: 431_960).map { ($0.name, $0.value ?? "") }
        )
    }

    @Test("An unconfigured install browses Most Popular over one week")
    func unconfiguredDefaultIsMostPopularOneWeek() throws {
        let (model, suite) = try Self.makeModel("defaultSort.unconfigured", settings: GlobalSettings())
        defer { suite.discard() }

        #expect(model.preferredSort == .mostPopular)
        #expect(model.preferredTimeFrame == .oneWeek)
        let values = Self.queryValues(model)
        #expect(values["query_type"] == "3")
        #expect(values["days"] == "7")
    }

    @Test("A configured default sort seeds the browse, and a windowless sort sends no days")
    func configuredDefaultSortSeedsBrowse() throws {
        var settings = GlobalSettings()
        settings.workshopDefaultSort = "topRated"
        let (model, suite) = try Self.makeModel("defaultSort.topRated", settings: settings)
        defer { suite.discard() }

        #expect(model.preferredSort == .topRated)
        let values = Self.queryValues(model)
        #expect(values["query_type"] == "0")
        #expect(values["days"] == nil)
    }

    @Test("A configured default window seeds Most Popular")
    func configuredDefaultTimeFrameSeedsBrowse() throws {
        var settings = GlobalSettings()
        settings.workshopDefaultTimeFrame = "thirtyDays"
        let (model, suite) = try Self.makeModel("defaultSort.thirtyDays", settings: settings)
        defer { suite.discard() }

        #expect(model.preferredTimeFrame == .thirtyDays)
        #expect(Self.queryValues(model)["days"] == "30")
    }

    /// Relevance only ranks against a search text, so it cannot be a browse
    /// default even if a hand-edited store says so.
    @Test("Unknown and Relevance default sorts fall back to Most Popular", arguments: ["bogus", "search"])
    func unknownDefaultSortFallsBack(raw: String) throws {
        var settings = GlobalSettings()
        settings.workshopDefaultSort = raw
        let (model, suite) = try Self.makeModel("defaultSort.fallback.\(raw)", settings: settings)
        defer { suite.discard() }

        #expect(model.preferredSort == .mostPopular)
    }

    /// All Time is not a window (`days` is nil), so it falls back like an unknown value.
    @Test("Unknown and All Time default windows fall back to one week", arguments: ["bogus", "allTime"])
    func unknownDefaultTimeFrameFallsBack(raw: String) throws {
        var settings = GlobalSettings()
        settings.workshopDefaultTimeFrame = raw
        let (model, suite) = try Self.makeModel("defaultSort.window.\(raw)", settings: settings)
        defer { suite.discard() }

        #expect(model.preferredTimeFrame == .oneWeek)
    }

    @Test("Clearing the search text returns to the configured default sort")
    func clearingSearchReturnsToConfiguredDefault() throws {
        var settings = GlobalSettings()
        settings.workshopDefaultSort = "lastUpdated"
        let (model, suite) = try Self.makeModel("defaultSort.clearSearch", settings: settings)
        defer { suite.discard() }

        model.searchInput = "city"
        model.updateSort(.search)
        #expect(model.preferredSort == .search)

        model.searchInput = ""
        #expect(model.preferredSort == .lastUpdated)
    }

    /// The pinned-tag request drops the search text but reused `preferredSort`,
    /// so a Relevance search followed by a tag click reached the request
    /// layer's Top Rated fallback instead of the configured default.
    @Test(
        "Pinning a tag during a Relevance search browses the configured default sort",
        arguments: [("mostPopular", "3", "7"), ("lastUpdated", "21", nil)]
    )
    func pinnedTagAfterRelevanceSearchUsesConfiguredDefault(raw: String, queryType: String, days: String?) throws {
        var settings = GlobalSettings()
        settings.workshopDefaultSort = raw
        let (model, suite) = try Self.makeModel("defaultSort.pinnedTag.\(raw)", settings: settings)
        defer { suite.discard() }

        model.searchInput = "city"
        model.updateSort(.search)
        model.applyScopeForTesting(pinnedTag: "Anime")

        let values = Self.queryValues(model)
        #expect(values["query_type"] == queryType)
        #expect(values["days"] == days)
    }

    /// The pane keeps one view model for the whole process, so a default
    /// changed in Settings has to be picked up when Browse is shown again.
    @Test("Returning to Browse picks up a default sort changed in Settings")
    func onAppearRereadsDefaultSort() async throws {
        let suite = try TestScratch.defaultsSuite("workshop.browse.request.defaultSort.onAppear")
        defer { suite.discard() }
        let store = MutableSettings(defaultSort: "mostPopular")
        let services = Self.makeStubbedServices()
        services.hasWebAPIKey = true
        let model = BrowseViewModel(services: services, defaults: suite.defaults, loadGlobalSettings: { store.settings })
        #expect(model.preferredSort == .mostPopular)

        store.settings.workshopDefaultSort = "lastUpdated"
        model.onAppear()

        #expect(model.preferredSort == .lastUpdated)
        #expect(Self.queryValues(model)["query_type"] == "21")

        // `onAppear` fires `reload()` on a detached task; a second, awaited one
        // proves the fetch reaches the stub session and not the real network.
        await model.reload()
        #expect(BrowseReloadStub.requestCount(queryType: "21") >= 1)
    }

    @Test("Control: a sort picked this session survives a settings change on reappear")
    func onAppearKeepsSessionSort() async throws {
        let suite = try TestScratch.defaultsSuite("workshop.browse.request.defaultSort.onAppearSession")
        defer { suite.discard() }
        let store = MutableSettings(defaultSort: "mostPopular")
        let services = Self.makeStubbedServices()
        services.hasWebAPIKey = true
        let model = BrowseViewModel(services: services, defaults: suite.defaults, loadGlobalSettings: { store.settings })

        model.updateSort(.newest)
        store.settings.workshopDefaultSort = "lastUpdated"
        model.onAppear()

        #expect(model.preferredSort == .newest)

        await model.reload()
        #expect(BrowseReloadStub.requestCount(queryType: "1") >= 1)
    }

    // MARK: - W4-B: a rejected key browses keyless (D11 / D23)

    /// The stubbed keychain's key, so a verdict can name the key it is about.
    private static let stubbedKey = String(repeating: "a1b2c3d4", count: 4)

    /// Valve's 401/403 is permanent ("Retrying will not help") and every keyed
    /// request after it counts against the same IP limit the keyless page
    /// shares, so a rejected key has to browse exactly as no key would.
    @Test("A stored key Valve rejected selects the keyless request shape and the public page")
    func rejectedKeyBrowsesKeyless() async throws {
        let suite = try TestScratch.defaultsSuite("workshop.browse.request.rejectedKey")
        defer { suite.discard() }
        let services = Self.makeStubbedServices()
        services.hasWebAPIKey = true
        await services.noteAuthVerdict(accepted: false, keyFingerprint: WorkshopQueryService.keyFingerprint(Self.stubbedKey))
        try #require(services.isKeyless)
        let model = BrowseViewModel(services: services, defaults: suite.defaults, publicSource: Self.makeStubbedPublicSource())

        #expect(model.usesKeylessSearch)
        #expect(model.makeRequest(page: 1).numPerPage == WorkshopPublicBrowseURL.itemsPerPage)

        // The genre facet takes the exclusion form on the keyless path.
        model.isolateGenre("Anime")
        #expect(model.makeRequest(page: 1).requiredTags.isEmpty)
        #expect(model.makeRequest(page: 1).excludedTags.contains("Landscape"))

        let marker = "w4b-\(UUID().uuidString)"
        model.searchInput = marker
        await model.reload()

        #expect(BrowseReloadStub.hosts(containing: marker) == ["steamcommunity.com"])
    }

    /// The keyless creator page ignores `excludedtags` and states no total,
    /// so a creator scope cannot be carried over when the key goes away.
    @Test("Losing the key leaves the creator scope")
    func keyLossLeavesCreatorScope() async throws {
        let suite = try TestScratch.defaultsSuite("workshop.browse.request.keyLossCreator")
        defer { suite.discard() }
        let services = Self.makeStubbedServices()
        services.hasWebAPIKey = true
        let model = BrowseViewModel(services: services, defaults: suite.defaults, publicSource: Self.makeStubbedPublicSource())
        model.applyScopeForTesting(creator: .init(steamID: "76561198000000001", name: nil))
        try #require(model.makeRequest(page: 1).creatorSteamID != nil)

        await services.noteAuthVerdict(accepted: false, keyFingerprint: WorkshopQueryService.keyFingerprint(Self.stubbedKey))
        try #require(services.isKeyless)
        await model.browsePathChanged()

        #expect(model.creatorFilter == nil)
        #expect(model.makeRequest(page: 1).creatorSteamID == nil)
        #expect(model.lastError != .missingAPIKey)
    }

    /// Belt and braces under the pane's `onChange`: a creator-scoped request
    /// that still reaches the keyless fetch is refused, not sent to the page.
    @Test("A keyless creator-scoped fetch is refused")
    func keylessCreatorFetchIsRefused() async throws {
        let suite = try TestScratch.defaultsSuite("workshop.browse.request.keylessCreatorRefused")
        defer { suite.discard() }
        let services = Self.makeStubbedServices()
        services.hasWebAPIKey = true
        await services.noteAuthVerdict(accepted: false, keyFingerprint: WorkshopQueryService.keyFingerprint(Self.stubbedKey))
        let model = BrowseViewModel(services: services, defaults: suite.defaults, publicSource: Self.makeStubbedPublicSource())
        model.applyScopeForTesting(creator: .init(steamID: "76561198000000001", name: nil))

        let marker = "76561198000000001"
        await model.reload()

        #expect(model.lastError == .missingAPIKey)
        #expect(!model.isLoading)
        #expect(BrowseReloadStub.hosts(containing: marker).isEmpty, "nothing went to Steam")
    }

    @Test("The rejected-key notice stays until dismissed and clears with the rejection")
    func keyRejectedNoticeLifecycle() async throws {
        let suite = try TestScratch.defaultsSuite("workshop.browse.request.rejectedKeyNotice")
        defer { suite.discard() }
        let services = Self.makeStubbedServices()
        services.hasWebAPIKey = true
        let model = BrowseViewModel(services: services, defaults: suite.defaults)
        let fingerprint = WorkshopQueryService.keyFingerprint(Self.stubbedKey)
        #expect(!model.showsKeyRejectedNotice)

        await services.noteAuthVerdict(accepted: false, keyFingerprint: fingerprint)
        #expect(model.showsKeyRejectedNotice)

        // A key Valve accepts again (saved and validated) clears it by itself.
        await services.noteAuthVerdict(accepted: true, keyFingerprint: fingerprint)
        #expect(!model.showsKeyRejectedNotice)

        await services.noteAuthVerdict(accepted: false, keyFingerprint: fingerprint)
        #expect(model.showsKeyRejectedNotice)
        model.dismissKeyRejectedNotice()
        #expect(!model.showsKeyRejectedNotice)
        #expect(services.apiKeyRejected, "dismissing the notice does not forgive the key")
    }

    private static func makeStubbedPublicSource() -> WorkshopPublicSearchSource {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("workshop-browse-public-\(UUID().uuidString)", isDirectory: true)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BrowseReloadStub.self]
        let session = URLSession(configuration: config)
        return WorkshopPublicSearchSource(
            metadata: SteamWorkshopMetadataService(session: session),
            session: session,
            cache: WorkshopQueryCache(directoryURL: directory.appendingPathComponent("public-cache"))
        )
    }

    /// Everything `reload()` can touch is isolated: a scratch keychain slot
    /// (never the developer's real key), a scratch cache, and a session whose
    /// only transport is `BrowseReloadStub`.
    private static func makeStubbedServices() -> WorkshopServices {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("workshop-browse-reload-\(UUID().uuidString)", isDirectory: true)
        let keychain = WorkshopKeychainStore(
            directory: directory,
            slot: WorkshopKeychainSlotSpy(stored: String(repeating: "a1b2c3d4", count: 4)).slot()
        )
        let cache = WorkshopQueryCache(directoryURL: directory.appendingPathComponent("cache"))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BrowseReloadStub.self]
        let service = WorkshopQueryService(
            keychain: keychain,
            cache: cache,
            session: URLSession(configuration: config),
            countIssuedRequest: {}
        )
        return WorkshopServices(keychain: keychain, cache: cache, queryService: service)
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

/// Answers every request with an empty page and remembers the URLs, so the
/// reappear tests can tell a stubbed fetch from a real one. The log is
/// process-wide (URLProtocol is registered by type); callers match on
/// `query_type` to find their own request among parallel tests'.
private final class BrowseReloadStub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var requests: [URL] = [] // guarded by `lock`

    /// Hosts of every recorded request whose URL carries `marker`.
    static func hosts(containing marker: String) -> Set<String> {
        lock.withLock { Set(requests.filter { $0.absoluteString.contains(marker) }.compactMap(\.host)) }
    }

    static func requestCount(queryType: String) -> Int {
        lock.withLock {
            requests.filter { url in
                url.host == "api.steampowered.com"
                    && URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                    .contains { $0.name == "query_type" && $0.value == queryType } == true
            }.count
        }
    }

    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        if let url = request.url {
            Self.lock.withLock { Self.requests.append(url) }
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"response":{"total":0}}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Stands in for `SettingsManager`: the Settings window rewrites the store
/// behind the view model's back, which is what the reappear tests change.
@MainActor
private final class MutableSettings {
    var settings = GlobalSettings()

    init(defaultSort: String) {
        settings.workshopDefaultSort = defaultSort
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

/// The sort and time-frame copy is Steam's own (Workshop_BrowseSort_* and
/// SharedFiles_Browse_Trend_Option_*, read from the community site's
/// localization chunks 2026-09-07), so a Wallpaper Engine user recognises each
/// option from the page. en and zh-Hans are pinned verbatim; the other three
/// only have to be present.
@Suite("Workshop sort and time-frame copy")
struct WorkshopSortCopyTests {
    private static let steamCopy: [String: (en: String, zhHans: String)] = [
        "Most Popular": ("Most Popular", "最热门"),
        "Top Rated All Time": ("Top Rated All Time", "最受好评（发布至今）"),
        "Most Recent": ("Most Recent", "最近发行"),
        "Last Updated": ("Last Updated", "最新更新"),
        "Total Unique Subscribers": ("Total Unique Subscribers", "不重复订阅者总计"),
        "Search Relevance": ("Search Relevance", "搜索相关度"),
        "Today": ("Today", "今天"),
        "One Week": ("One Week", "1 周"),
        "Thirty Days": ("Thirty Days", "30 天"),
        "Three Months": ("Three Months", "3 个月"),
        "Six Months": ("Six Months", "6 个月"),
        "One Year": ("One Year", "1 年"),
        "All Time": ("All Time", "发布至今"),
        "workshop.sort.most_popular_with_window": ("%1$@ (%2$@)", "%1$@（%2$@）"),
        "Sort Order": ("Sort Order", "排序顺序"),
        "Time Frame": ("Time Frame", "时间范围"),
        // Workshop_SearchTarget_*
        "Title & Description": ("Title & Description", "标题与描述"),
        "Title Only": ("Title Only", "仅限标题"),
        "Description Only": ("Description Only", "仅限描述"),
        "Specify what text fields of the item you want to search:": (
            "Specify what text fields of the item you want to search:", "指定您希望搜索的项目文本字段："
        ),
    ]

    /// The Miscellaneous chips with a rendering in `WorkshopTagLocalization`
    /// (`3D`, `HDR`, `Puppet Warp` are deliberately verbatim).
    private static let miscellaneousCopy = [
        "Approved", "Audio responsive", "Customizable", "Media Integration", "User Shortcut", "Video Texture",
    ]

    private static let settingsCopy = ["Default sort", "Default time frame"]

    /// W4-B: the Browse banner shown once Valve rejected the stored key.
    private static let keyRejectedCopy = ["Steam rejected the saved API key. Browsing without it.", "Open Settings"]

    private static func catalogStrings() throws -> [String: Any] {
        let data = try RepositoryRoot.data("LiveWallpaper/Resources/Localizable.xcstrings")
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(root["strings"] as? [String: Any])
    }

    private static func value(_ strings: [String: Any], key: String, locale: String) -> String? {
        let entry = strings[key] as? [String: Any]
        let localizations = entry?["localizations"] as? [String: Any]
        let unit = (localizations?[locale] as? [String: Any])?["stringUnit"] as? [String: Any]
        return unit?["value"] as? String
    }

    @Test("Sort and time-frame keys carry Steam's en and zh-Hans copy verbatim")
    func steamCopyIsVerbatim() throws {
        let strings = try Self.catalogStrings()
        for (key, copy) in Self.steamCopy.sorted(by: { $0.key < $1.key }) {
            #expect(Self.value(strings, key: key, locale: "en") == copy.en, "\(key) [en]")
            #expect(Self.value(strings, key: key, locale: "zh-Hans") == copy.zhHans, "\(key) [zh-Hans]")
        }
    }

    @Test("Sort, time-frame and the two Settings rows exist in all five languages")
    func copyExistsInFiveLanguages() throws {
        let strings = try Self.catalogStrings()
        for key in Array(Self.steamCopy.keys) + Self.settingsCopy + Self.miscellaneousCopy + Self.keyRejectedCopy {
            for locale in ["en", "zh-Hans", "zh-Hant", "ja", "es"] {
                let value = Self.value(strings, key: key, locale: locale) ?? ""
                #expect(!value.isEmpty, "\(key) [\(locale)]")
            }
        }
    }

    @Test("Relevance is offered under Steam's name")
    func relevanceUsesSteamName() throws {
        let ribbon = try RepositoryRoot.source("LiveWallpaper/Views/Workshop/BrowseFilterRibbon.swift")
        #expect(ribbon.contains("\"Search Relevance\""))
        #expect(!ribbon.contains("return \"Relevance\""))
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
