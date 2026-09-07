#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import Testing

/// The keyless path against real browse-page markup: the page's own SSR
/// payload is the result set, and the id-harvest + `GetPublishedFileDetails`
/// round trip is only the fallback. Fixtures and their provenance are in
/// `LiveWallpaperTests/Fixtures/workshop/README.md`; every expected value
/// below was computed from the trimmed fixture, not typed in.
@Suite("Workshop keyless search over the SSR payload", .serialized)
@MainActor
struct WorkshopPublicSearchSSRTests {
    /// Page order of `browse_trend7_p1.html` (both the SSR `results[]` and the
    /// de-duplicated anchors yield this list).
    nonisolated static let expectedIDs: [UInt64] = [
        3_794_937_077, 3_795_510_669, 3_794_850_351, 3_795_008_547, 3_794_881_808,
        3_793_998_447, 3_793_923_399, 3_793_847_331, 3_793_885_664, 3_794_790_658,
        3_793_525_431, 3_794_768_582, 3_793_302_353, 3_794_989_445, 3_794_982_149,
        3_790_379_688, 3_796_263_268, 3_796_181_648, 3_796_021_944, 3_794_946_293,
        3_795_990_765, 3_795_306_555, 3_795_384_177, 3_793_777_290, 3_794_942_942,
        3_793_439_427, 3_794_565_886, 3_795_996_150, 3_796_494_818, 3_794_332_647,
    ]
    nonisolated static let expectedTotalCount = 2_747_905
    nonisolated static let expectedTotalPages = 1000

    /// The request the fixture page answers: `browsesort=trend&days=7&p=1`
    /// with Application/Asset/Preset excluded.
    nonisolated static let fixtureRequest = WorkshopQueryRequest(
        sort: .mostPopular,
        page: 1,
        numPerPage: 30,
        timeFrame: .oneWeek,
        excludedTags: ["Application", "Asset", "Preset"]
    )

    nonisolated static func fixture(_ name: String) throws -> Data {
        try RepositoryRoot.data("LiveWallpaperTests/Fixtures/workshop/\(name)")
    }

    /// Run-time variants of the captured page (`WorkshopBrowseFixture`), as the
    /// stub wants them.
    nonisolated static func derived(_ page: () throws -> String) throws -> Data {
        try Data(page().utf8)
    }

    private static func makeSource() -> (source: WorkshopPublicSearchSource, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("workshop-ssr-\(UUID().uuidString)", isDirectory: true)
        let session = KeylessPageStub.makeSession()
        let source = WorkshopPublicSearchSource(
            metadata: SteamWorkshopMetadataService(session: session),
            session: session,
            appID: WorkshopQueryService.wallpaperEngineAppID,
            cache: WorkshopQueryCache(directoryURL: directory),
            retryPolicy: RetryVirtualClock().makePolicy()
        )
        return (source, directory)
    }

    @Test("A real browse page resolves from its SSR payload in one request")
    func fullPageResolvesWithoutDetailsRequest() async throws {
        try KeylessPageStub.configure(html: Self.fixture("browse_trend7_p1.html"), details: .resolveAll(notFound: []))
        let (source, directory) = Self.makeSource()
        defer { try? FileManager.default.removeItem(at: directory) }

        let page = try await source.fetch(Self.fixtureRequest)

        #expect(page.items.map(\.id) == Self.expectedIDs)
        #expect(KeylessPageStub.browsePageRequests == 1)
        #expect(KeylessPageStub.detailRequests == 0, "the SSR payload carries everything; no details round trip")
        #expect(page.totalAvailable == Self.expectedTotalCount)
        #expect(page.totalPages == Self.expectedTotalPages)
        #expect(page.sourceItemCount == 30)
        #expect(page.nextCursor == "2")

        let first = try #require(page.items.first)
        #expect(first.title == "windows xp2（朋友的酒）")
        #expect(first.creatorID == "76561199471797274")
        #expect(first.creatorPersonaName == "海嗣收容专家")
        #expect(first.previewImageURL?.absoluteString
            == "https://images.steamusercontent.com/ugc/12506494599842728983/02B16F0FC38B65438430F8CEAE44F9B38479522A/")
        #expect(first.tags == ["Video", "Abstract", "Wallpaper", "3840 x 2160", "Everyone"])
        #expect(first.shortDescription == "朋友的酒DJ-Remix，关注B站 Seaboorn收容专家 喵，谢谢喵")
        #expect(first.subscriptionCount == 10605)
        #expect(first.viewCount == 2046)
        #expect(first.favoriteCount == 392)
        #expect(first.fileSizeBytes == 1_123_226_835)
        #expect(first.timeUpdated == Date(timeIntervalSince1970: 1_788_435_379))

        let second = page.items[1]
        #expect(second.title == "The Binding of Isaac - DOGMA")
        #expect(second.creatorPersonaName == "brugabrug")
        #expect(second.previewImageURL?.absoluteString
            == "https://images.steamusercontent.com/ugc/11016948313923971054/2D6E802865F37636D9B68499CDA5974F0AC07224/")
        #expect(second.tags == ["Scene", "Game", "Wallpaper", "Video Texture", "Customizable", "3840 x 2160", "Everyone"])

        let third = page.items[2]
        #expect(third.title == "邦多利-朋友的酒")
        #expect(third.creatorPersonaName == "喜多郁代")
        #expect(third.previewImageURL?.absoluteString
            == "https://images.steamusercontent.com/ugc/15750383326586884951/6E8AAC000A6047AFABE1871EC11E2ABAD983EAAA/")
        #expect(third.tags == ["Video", "Anime", "Wallpaper", "3840 x 2160", "Everyone"])
        #expect(third.shortDescription == "")

        // `star_rating` is a 1–5 integer, never the keyed 0–1 score: the page
        // only ever yields `.stars`.
        #expect(!page.items.contains { item in
            if case .score = item.rating {
                return true
            }
            return false
        })
    }

    @Test("Control: a page without the SSR payload falls back to id harvesting")
    func noSSRFallsBackToIDHarvesting() async throws {
        try KeylessPageStub.configure(html: Self.derived(WorkshopBrowseFixture.withoutSSRScript), details: .resolveAll(notFound: []))
        let (source, directory) = Self.makeSource()
        defer { try? FileManager.default.removeItem(at: directory) }

        let page = try await source.fetch(Self.fixtureRequest)

        #expect(page.items.map(\.id) == Self.expectedIDs)
        #expect(KeylessPageStub.browsePageRequests == 1)
        #expect(KeylessPageStub.detailRequests == 1)
        #expect(page.totalAvailable == nil, "the harvest path has no total")
        #expect(page.totalPages == nil)
        #expect(page.sourceItemCount == 30, "anchors harvested, before details")
    }

    @Test("Drop rules apply to SSR results without shrinking the source count")
    func taintedResultsAreDroppedNotCounted() async throws {
        try KeylessPageStub.configure(html: Self.derived(WorkshopBrowseFixture.tainted), details: .resolveAll(notFound: []))
        let (source, directory) = Self.makeSource()
        defer { try? FileManager.default.removeItem(at: directory) }

        let page = try await source.fetch(Self.fixtureRequest)

        #expect(KeylessPageStub.detailRequests == 0)
        #expect(page.sourceItemCount == 30)
        #expect(page.items.count == 28)
        // 1st: preview moved off the CDN allow-list → shown without a preview.
        let first = try #require(page.items.first)
        #expect(first.id == Self.expectedIDs[0])
        #expect(first.previewImageURL == nil)
        // 2nd banned, 3rd non-public → not shown at all.
        #expect(!page.items.contains { $0.id == Self.expectedIDs[1] })
        #expect(!page.items.contains { $0.id == Self.expectedIDs[2] })
        #expect(page.items.map(\.id) == Self.expectedIDs.filter { $0 != Self.expectedIDs[1] && $0 != Self.expectedIDs[2] })
    }

    @Test("A same-host 200 with neither payload nor anchors is a failure, never an empty page")
    func challengePageIsAnErrorNotAnEmptyPage() async throws {
        try KeylessPageStub.configure(html: Self.fixture("challenge_page.html"), details: .resolveAll(notFound: []))
        let (source, directory) = Self.makeSource()
        defer { try? FileManager.default.removeItem(at: directory) }

        await #expect(throws: WorkshopQueryError.responseParseFailure) {
            try await source.fetch(Self.fixtureRequest)
        }
        // Nothing was cached: the second call goes back to the network.
        await #expect(throws: WorkshopQueryError.responseParseFailure) {
            try await source.fetch(Self.fixtureRequest)
        }
        #expect(KeylessPageStub.browsePageRequests == 2)
        #expect(KeylessPageStub.detailRequests == 0)
    }

    /// The anchors on a page that answers another request are that other
    /// page's items; harvesting them would show and cache them under this
    /// page's number.
    @Test("An SSR payload for a different page is an error, not a fallback")
    func mismatchedIdentityIsAnErrorNotAFallback() async throws {
        try KeylessPageStub.configure(html: Self.derived(WorkshopBrowseFixture.keyPage2), details: .resolveAll(notFound: []))
        let (source, directory) = Self.makeSource()
        defer { try? FileManager.default.removeItem(at: directory) }

        await #expect(throws: WorkshopQueryError.responseParseFailure) {
            try await source.fetch(Self.fixtureRequest)
        }
        // Nothing was cached: the second call goes back to the network.
        await #expect(throws: WorkshopQueryError.responseParseFailure) {
            try await source.fetch(Self.fixtureRequest)
        }
        #expect(KeylessPageStub.browsePageRequests == 2)
        #expect(KeylessPageStub.detailRequests == 0, "queryKey says page 2, request says page 1: no harvest either")
    }

    /// The page has no Miscellaneous facet of its own: those tags go out as
    /// `requiredtags[]` and come back in the key's `required_tags`, so the
    /// identity check has to expect them there.
    @Test("A Miscellaneous tag the key echoes is this request's own page")
    func miscellaneousTagIsPartOfTheIdentity() async throws {
        try KeylessPageStub.configure(html: Self.derived(WorkshopBrowseFixture.keyRequiresApproved), details: .resolveAll(notFound: []))
        let (source, directory) = Self.makeSource()
        defer { try? FileManager.default.removeItem(at: directory) }
        let request = WorkshopQueryRequest(
            sort: .mostPopular, page: 1, numPerPage: 30, timeFrame: .oneWeek,
            excludedTags: ["Application", "Asset", "Preset"], miscellaneousTags: ["Approved"]
        )

        let page = try await source.fetch(request)

        #expect(page.items.count == 30)
        #expect(KeylessPageStub.detailRequests == 0)

        // Control: without the tag the same page answers another request.
        try KeylessPageStub.configure(html: Self.derived(WorkshopBrowseFixture.keyRequiresApproved), details: .resolveAll(notFound: []))
        let (plain, plainDirectory) = Self.makeSource()
        defer { try? FileManager.default.removeItem(at: plainDirectory) }
        await #expect(throws: WorkshopQueryError.responseParseFailure) {
            try await plain.fetch(Self.fixtureRequest)
        }
        #expect(KeylessPageStub.detailRequests == 0)
    }

    /// The creator page never carries the SSR payload, so past its last page
    /// (or for a creator with nothing public) the harvest sees no anchors.
    /// Steam's own empty-state container tells that apart from a challenge page.
    @Test("An empty creator page is an empty page with no next cursor")
    func emptyCreatorPageIsAnEmptyPage() async throws {
        let request = WorkshopQueryRequest(sort: .lastUpdated, page: 999, creatorSteamID: "76561199471797274")
        try KeylessPageStub.configure(html: Self.fixture("creator_empty_page.html"), details: .resolveAll(notFound: []))
        let (source, directory) = Self.makeSource()
        defer { try? FileManager.default.removeItem(at: directory) }

        let page = try await source.fetch(request)

        #expect(page.items.isEmpty)
        #expect(page.nextCursor == nil)
        #expect(page.sourceItemCount == 0)
        #expect(page.totalAvailable == nil)
        #expect(KeylessPageStub.detailRequests == 0)

        // Control: the same creator request answered by a challenge page is still a failure.
        try KeylessPageStub.configure(html: Self.fixture("challenge_page.html"), details: .resolveAll(notFound: []))
        let (challenged, challengedDirectory) = Self.makeSource()
        defer { try? FileManager.default.removeItem(at: challengedDirectory) }
        await #expect(throws: WorkshopQueryError.responseParseFailure) {
            try await challenged.fetch(request)
        }
    }

    @Test("A details transport failure fails the whole page and caches nothing")
    func detailsTransportFailureIsNotCached() async throws {
        try KeylessPageStub.configure(html: Self.derived(WorkshopBrowseFixture.withoutSSRScript), details: .transportError)
        let (source, directory) = Self.makeSource()
        defer { try? FileManager.default.removeItem(at: directory) }

        await #expect(throws: WorkshopQueryError.self) { try await source.fetch(Self.fixtureRequest) }
        await #expect(throws: WorkshopQueryError.self) { try await source.fetch(Self.fixtureRequest) }
        #expect(KeylessPageStub.browsePageRequests == 2)
        // Three attempts per fetch: the policy retries a dropped connection.
        #expect(KeylessPageStub.detailRequests == 6)
    }

    /// A page that answers a title-only search under the same text is another
    /// request's page; its anchors are not this page's items either.
    @Test("An SSR payload for another search target is an error, not a fallback")
    func mismatchedSearchTargetIsAnErrorNotAFallback() async throws {
        try KeylessPageStub.configure(html: Self.derived(WorkshopBrowseFixture.keySearchTargetTitleOnly), details: .resolveAll(notFound: []))
        let (source, directory) = Self.makeSource()
        defer { try? FileManager.default.removeItem(at: directory) }

        await #expect(throws: WorkshopQueryError.responseParseFailure) {
            try await source.fetch(Self.fixtureRequest)
        }
        #expect(KeylessPageStub.browsePageRequests == 1)
        #expect(KeylessPageStub.detailRequests == 0, "queryKey says target 1, request says 0: no harvest either")
    }

    /// Result code 2 (generic failure) says nothing about the item's
    /// visibility; a page built without it would be cached as complete.
    @Test("A transient detail failure fails the whole page and caches nothing")
    func transientDetailFailureIsNotCached() async throws {
        let failing = Self.expectedIDs[5]
        try KeylessPageStub.configure(html: Self.derived(WorkshopBrowseFixture.withoutSSRScript), details: .resultCodes([failing: 2]))
        let (source, directory) = Self.makeSource()
        defer { try? FileManager.default.removeItem(at: directory) }

        await #expect(throws: WorkshopQueryError.responseParseFailure) { try await source.fetch(Self.fixtureRequest) }
        await #expect(throws: WorkshopQueryError.responseParseFailure) { try await source.fetch(Self.fixtureRequest) }
        #expect(KeylessPageStub.browsePageRequests == 2)
    }

    /// Thirty anchors whose details all say "not found" are a complete answer
    /// with nothing to show — not a failed lookup.
    @Test("A page whose ids are all permanently invisible is an empty page with its source count")
    func allInvisibleIDsMakeAnEmptyPage() async throws {
        let codes = Dictionary(uniqueKeysWithValues: Self.expectedIDs.map { ($0, 9) })
        try KeylessPageStub.configure(html: Self.derived(WorkshopBrowseFixture.withoutSSRScript), details: .resultCodes(codes))
        let (source, directory) = Self.makeSource()
        defer { try? FileManager.default.removeItem(at: directory) }

        let page = try await source.fetch(Self.fixtureRequest)

        #expect(page.items.isEmpty)
        #expect(page.sourceItemCount == 30)
        #expect(page.nextCursor == "2")
    }

    @Test("A not-found detail is skipped and the remaining page is cached")
    func notFoundDetailIsSkippedAndPageCached() async throws {
        let missing = Self.expectedIDs[5]
        try KeylessPageStub.configure(html: Self.derived(WorkshopBrowseFixture.withoutSSRScript), details: .resolveAll(notFound: [missing]))
        let (source, directory) = Self.makeSource()
        defer { try? FileManager.default.removeItem(at: directory) }

        let page = try await source.fetch(Self.fixtureRequest)
        #expect(page.items.count == 29)
        #expect(!page.items.contains { $0.id == missing })
        #expect(page.items.map(\.id) == Self.expectedIDs.filter { $0 != missing })

        _ = try await source.fetch(Self.fixtureRequest)
        #expect(KeylessPageStub.browsePageRequests == 1, "the 29-item page is a complete answer and is served from cache")
        #expect(page.sourceItemCount == 30)
    }
}

/// The parser on its own: literal extraction, the double-encoded `queryData`,
/// and the identity check against the request.
@Suite("Workshop browse-page SSR payload parsing")
struct WorkshopPublicBrowsePayloadTests {
    private static func html(_ name: String) throws -> String {
        try #require(String(data: WorkshopPublicSearchSSRTests.fixture(name), encoding: .utf8))
    }

    /// Builds the page the way Valve does: render context → JS string literal
    /// (JSON string grammar) → `JSON.parse("…")`.
    private static func ssrHTML(queryData: String) throws -> String {
        let renderContext = try JSONSerialization.data(withJSONObject: ["queryData": queryData])
        let renderContextJSON = try #require(String(data: renderContext, encoding: .utf8))
        let literal = try JSONSerialization.data(withJSONObject: renderContextJSON, options: .fragmentsAllowed)
        let quoted = try #require(String(data: literal, encoding: .utf8))
        return "<script>window.SSR={};window.SSR.renderContext=JSON.parse(\(quoted)); </script>"
    }

    private static let request = WorkshopPublicSearchSSRTests.fixtureRequest
    private static let appID = WorkshopQueryService.wallpaperEngineAppID

    @Test("The verbatim page parses to the same ids as its anchors")
    func verbatimPageParses() throws {
        let html = try Self.html("browse_trend7_p1.html")
        let page = try WorkshopPublicBrowsePayload.page(fromHTML: html, matching: Self.request, appID: Self.appID)

        #expect(page.items.map(\.id) == WorkshopPublicSearchSSRTests.expectedIDs)
        #expect(page.items.map(\.id) == WorkshopPublicIDExtractor.publishedFileIDs(fromHTML: html))
        #expect(page.totalCount == WorkshopPublicSearchSSRTests.expectedTotalCount)
        #expect(page.totalPages == WorkshopPublicSearchSSRTests.expectedTotalPages)
        #expect(page.sourceItemCount == 30)
        #expect(page.items.allSatisfy { $0.creatorPersonaName != nil }, "every creator on this page has link details")
    }

    @Test("Failure reasons: no marker, no anchors either, and a foreign query key")
    func failureReasons() throws {
        #expect(throws: WorkshopPublicBrowsePayload.ParseFailure.markerNotFound) {
            try WorkshopPublicBrowsePayload.page(fromHTML: WorkshopBrowseFixture.withoutSSRScript(), matching: Self.request, appID: Self.appID)
        }
        let challenge = try Self.html("challenge_page.html")
        #expect(throws: WorkshopPublicBrowsePayload.ParseFailure.markerNotFound) {
            try WorkshopPublicBrowsePayload.page(fromHTML: challenge, matching: Self.request, appID: Self.appID)
        }
        #expect(WorkshopPublicIDExtractor.publishedFileIDs(fromHTML: challenge).isEmpty)

        let pageTwo = try WorkshopBrowseFixture.keyPage2()
        #expect(throws: WorkshopPublicBrowsePayload.ParseFailure.identityMismatch) {
            try WorkshopPublicBrowsePayload.page(fromHTML: pageTwo, matching: Self.request, appID: Self.appID)
        }
        // Control: asked for page 2, the same payload is adopted.
        let asPageTwo = WorkshopQueryRequest(
            sort: .mostPopular, page: 2, numPerPage: 30, timeFrame: .oneWeek,
            excludedTags: ["Application", "Asset", "Preset"]
        )
        let page = try WorkshopPublicBrowsePayload.page(fromHTML: pageTwo, matching: asPageTwo, appID: Self.appID)
        #expect(page.items.count == 30)
    }

    @Test("Identity: sort, search text, days, tags and app id each veto adoption")
    func identityParameters() throws {
        let html = try Self.html("browse_trend7_p1.html")
        let mismatches: [WorkshopQueryRequest] = [
            WorkshopQueryRequest(sort: .topRated, page: 1, numPerPage: 30, excludedTags: ["Application", "Asset", "Preset"]),
            WorkshopQueryRequest(sort: .mostPopular, searchText: "cat", page: 1, numPerPage: 30, timeFrame: .oneWeek, excludedTags: ["Application", "Asset", "Preset"]),
            WorkshopQueryRequest(sort: .mostPopular, page: 1, numPerPage: 30, timeFrame: .thirtyDays, excludedTags: ["Application", "Asset", "Preset"]),
            WorkshopQueryRequest(sort: .mostPopular, page: 1, numPerPage: 30, timeFrame: .oneWeek, excludedTags: ["Application", "Asset"]),
            WorkshopQueryRequest(sort: .mostPopular, page: 1, numPerPage: 30, timeFrame: .oneWeek, requiredTags: ["Anime"], excludedTags: ["Application", "Asset", "Preset"]),
        ]
        for request in mismatches {
            #expect(throws: WorkshopPublicBrowsePayload.ParseFailure.identityMismatch, "\(request)") {
                try WorkshopPublicBrowsePayload.page(fromHTML: html, matching: request, appID: Self.appID)
            }
        }
        #expect(throws: WorkshopPublicBrowsePayload.ParseFailure.identityMismatch) {
            try WorkshopPublicBrowsePayload.page(fromHTML: html, matching: Self.request, appID: 440)
        }
    }

    /// The key also states the search target, the child id and the section,
    /// and the data states which page it is; each is part of the identity.
    @Test("Identity: search target, section and the data's current page each veto adoption")
    func searchTargetSectionAndCurrentPageVeto() throws {
        let variants: [(String, () throws -> String)] = [
            ("search_text_target 1", WorkshopBrowseFixture.keySearchTargetTitleOnly),
            ("section collections", WorkshopBrowseFixture.keySectionCollections),
            ("current_page 2", WorkshopBrowseFixture.dataCurrentPage2),
        ]
        for (label, variant) in variants {
            let html = try variant()
            #expect(throws: WorkshopPublicBrowsePayload.ParseFailure.identityMismatch, "\(label)") {
                try WorkshopPublicBrowsePayload.page(fromHTML: html, matching: Self.request, appID: Self.appID)
            }
        }
        // Control: the untouched page is adopted.
        let page = try WorkshopPublicBrowsePayload.page(fromHTML: WorkshopBrowseFixture.base(), matching: Self.request, appID: Self.appID)
        #expect(page.items.count == 30)
    }

    @Test("Identity: the key's child id must match the request's")
    func childIDIsPartOfTheIdentity() throws {
        let withChild = WorkshopQueryRequest(
            sort: .mostPopular, page: 1, numPerPage: 30, timeFrame: .oneWeek,
            excludedTags: ["Application", "Asset", "Preset"], childPublishedFileID: 42
        )
        #expect(throws: WorkshopPublicBrowsePayload.ParseFailure.identityMismatch) {
            try WorkshopPublicBrowsePayload.page(fromHTML: WorkshopBrowseFixture.base(), matching: withChild, appID: Self.appID)
        }
        let childPage = try WorkshopBrowseFixture.keyChild42()
        #expect(throws: WorkshopPublicBrowsePayload.ParseFailure.identityMismatch) {
            try WorkshopPublicBrowsePayload.page(fromHTML: childPage, matching: Self.request, appID: Self.appID)
        }
        // Control: the page that states the child answers the request that asked for it.
        let page = try WorkshopPublicBrowsePayload.page(fromHTML: childPage, matching: withChild, appID: Self.appID)
        #expect(page.items.count == 30)
    }

    /// A failed query is a failure whatever else the data omits; and a missing
    /// `results` is only an empty page when the totals say the page is empty.
    @Test("eresult is checked before the totals; a missing results list needs the totals' evidence")
    func failureAndMissingResults() throws {
        let key = #"{"appid":431960,"browse_sort":"textsearch","page":1,"search_text":"zzzz"}"#
        let request = WorkshopQueryRequest(sort: .search, searchText: "zzzz", page: 1, numPerPage: 30)

        let failed = try Self.ssrHTML(queryData: #"{"queries":[{"queryKey":["workshop_browse",\#(key),1],"state":{"data":{"eresult":2}}}]}"#)
        #expect(throws: WorkshopPublicBrowsePayload.ParseFailure.resultNotOK(2)) {
            try WorkshopPublicBrowsePayload.page(fromHTML: failed, matching: request, appID: 431_960)
        }

        let listless = try Self.ssrHTML(queryData: #"{"queries":[{"queryKey":["workshop_browse",\#(key),1],"state":{"data":{"eresult":1,"total_count":100,"total_pages":4}}}]}"#)
        #expect(throws: WorkshopPublicBrowsePayload.ParseFailure.malformedJSON) {
            try WorkshopPublicBrowsePayload.page(fromHTML: listless, matching: request, appID: 431_960)
        }

        // Controls: nothing at all, and a page past the last one, are empty pages.
        let nothing = try Self.ssrHTML(queryData: #"{"queries":[{"queryKey":["workshop_browse",\#(key),1],"state":{"data":{"eresult":1,"total_count":0,"total_pages":0}}}]}"#)
        let empty = try WorkshopPublicBrowsePayload.page(fromHTML: nothing, matching: request, appID: 431_960)
        #expect(empty.items.isEmpty)
        #expect(empty.sourceItemCount == 0)

        let pageThree = WorkshopQueryRequest(sort: .search, searchText: "zzzz", page: 3, numPerPage: 30)
        let pastTheEnd = try Self.ssrHTML(queryData: #"{"queries":[{"queryKey":["workshop_browse",{"appid":431960,"browse_sort":"textsearch","page":3,"search_text":"zzzz"},1],"state":{"data":{"eresult":1,"total_count":50,"total_pages":2}}}]}"#)
        let past = try WorkshopPublicBrowsePayload.page(fromHTML: pastTheEnd, matching: pageThree, appID: 431_960)
        #expect(past.items.isEmpty)
        #expect(past.totalPages == 2)
    }

    /// `star_rating` is -1 (unrated) or 1…5; anything else is not a rating.
    @Test("star_rating outside -1 and 1…5 is no rating; negative vote counts read as zero")
    func starRatingBounds() throws {
        func result(_ id: Int, stars: Int, votes: Int) -> String {
            #"{"publishedfileid":"\#(id)","consumer_appid":431960,"title":"r\#(id)","star_rating":\#(stars),"total_votes":\#(votes)}"#
        }
        let queryData = #"{"queries":[{"queryKey":["workshop_browse",{"appid":431960,"browse_sort":"toprated","page":1,"search_text":""},1],"state":{"data":{"eresult":1,"total_count":4,"total_pages":1,"results":[\#(result(1, stars: 100, votes: 3)),\#(result(2, stars: -1, votes: -5)),\#(result(3, stars: 5, votes: 7)),\#(result(4, stars: 0, votes: 1))]}}}]}"#
        let html = try Self.ssrHTML(queryData: queryData)
        let request = WorkshopQueryRequest(sort: .topRated, page: 1, numPerPage: 30)

        let page = try WorkshopPublicBrowsePayload.page(fromHTML: html, matching: request, appID: 431_960)
        #expect(page.items.map(\.rating) == [nil, .stars(0, totalVotes: 0), .stars(5, totalVotes: 7), nil])
    }

    /// A literal that closes on `\")` inside a description must not end the
    /// payload early — the walk skips escaped pairs.
    @Test("An escaped quote-paren inside the literal does not truncate it")
    func escapedQuoteInsideLiteral() throws {
        let queryData = #"{"queries":[{"queryKey":["workshop_browse",{"appid":431960,"browse_sort":"toprated","page":1,"search_text":""},1],"state":{"data":{"eresult":1,"total_count":1,"total_pages":1,"results":[{"publishedfileid":"42","consumer_appid":431960,"title":"Say \"hi\")","tags":[]}]}}}]}"#
        let html = try Self.ssrHTML(queryData: queryData)
        let request = WorkshopQueryRequest(sort: .topRated, page: 1, numPerPage: 30)

        let page = try WorkshopPublicBrowsePayload.page(fromHTML: html, matching: request, appID: 431_960)
        #expect(page.items.map(\.title) == ["Say \"hi\")"])
    }

    @Test("A payload with zero results and a zero total is a legitimate empty page")
    func emptyResultSet() throws {
        let queryData = #"{"queries":[{"queryKey":["workshop_browse",{"appid":431960,"browse_sort":"textsearch","page":1,"search_text":"zzzz"},1],"state":{"data":{"eresult":1,"total_count":0,"total_pages":0,"results":[],"creator_player_link_details":[]}}}]}"#
        let html = try Self.ssrHTML(queryData: queryData)
        let request = WorkshopQueryRequest(sort: .search, searchText: "zzzz", page: 1, numPerPage: 30)

        let page = try WorkshopPublicBrowsePayload.page(fromHTML: html, matching: request, appID: 431_960)
        #expect(page.items.isEmpty)
        #expect(page.sourceItemCount == 0)
        #expect(page.totalCount == 0)
        #expect(page.totalPages == 0)
    }
}

/// Serves one configured browse page and answers `GetPublishedFileDetails`
/// for every id in `WorkshopPublicSearchSSRTests.expectedIDs`.
final class KeylessPageStub: URLProtocol, @unchecked Sendable {
    enum DetailsMode {
        case resolveAll(notFound: Set<UInt64>)
        /// Every id resolves except those listed, which answer with that
        /// Steam result code (9 not found, 15 access denied, 2 failure, …).
        case resultCodes([UInt64: Int])
        case transportError
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var browseHTML = Data()
    private nonisolated(unsafe) static var detailsMode: DetailsMode = .resolveAll(notFound: [])
    private nonisolated(unsafe) static var browseCount = 0
    private nonisolated(unsafe) static var detailCount = 0

    static func configure(html: Data, details: DetailsMode) {
        lock.withLock {
            browseHTML = html
            detailsMode = details
            browseCount = 0
            detailCount = 0
        }
    }

    static var browsePageRequests: Int {
        lock.withLock { browseCount }
    }

    static var detailRequests: Int {
        lock.withLock { detailCount }
    }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [KeylessPageStub.self]
        return URLSession(configuration: config)
    }

    private static func detailsJSON(resultCodes: [UInt64: Int]) -> Data {
        let entries = WorkshopPublicSearchSSRTests.expectedIDs.map { id -> String in
            if let code = resultCodes[id] {
                return #"{"publishedfileid":"\#(id)","result":\#(code)}"#
            }
            return #"{"publishedfileid":"\#(id)","result":1,"consumer_app_id":431960,"title":"Item \#(id)","visibility":0,"banned":0,"tags":[{"tag":"Scene"}]}"#
        }
        return Data(#"{"response":{"result":1,"resultcount":\#(entries.count),"publishedfiledetails":[\#(entries.joined(separator: ","))]}}"#.utf8)
    }

    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let url = request.url!
        let isDetails = url.absoluteString.contains("GetPublishedFileDetails")
        let (html, mode) = Self.lock.withLock { () -> (Data, DetailsMode) in
            if isDetails {
                Self.detailCount += 1
            } else {
                Self.browseCount += 1
            }
            return (Self.browseHTML, Self.detailsMode)
        }
        let body: Data
        if isDetails {
            switch mode {
            case .transportError:
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
                return
            case let .resolveAll(notFound):
                body = Self.detailsJSON(resultCodes: Dictionary(uniqueKeysWithValues: notFound.map { ($0, 9) }))
            case let .resultCodes(codes):
                body = Self.detailsJSON(resultCodes: codes)
            }
        } else {
            body = html
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
#endif
