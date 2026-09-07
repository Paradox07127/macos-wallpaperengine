#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import Testing

/// The two browse paths rate in different units: keyed `vote_data.score` is
/// 0–1, the keyless page's `star_rating` is already 1–5.
@Suite("WorkshopRating")
struct WorkshopRatingTests {
    @Test("Stars pass through unscaled; scores scale to five and clamp")
    func starsOutOfFive() {
        #expect(WorkshopRating.stars(3, totalVotes: 10).starsOutOfFive == 3)
        #expect(WorkshopRating.score(0.9, votesUp: 9, votesDown: 1).starsOutOfFive == 4.5)
        #expect(WorkshopRating.score(1.2, votesUp: 1, votesDown: 0).starsOutOfFive == 5)
        #expect(WorkshopRating.score(-0.5, votesUp: 0, votesDown: 1).starsOutOfFive == 0)
    }

    @Test("Total votes: up plus down for a score, the page's count for stars")
    func totalVotes() {
        #expect(WorkshopRating.score(0.9, votesUp: 9, votesDown: 1).totalVotes == 10)
        #expect(WorkshopRating.stars(4, totalVotes: 175).totalVotes == 175)
    }

    @Test("A vote sum that overflows saturates instead of trapping")
    func totalVotesSaturates() {
        #expect(WorkshopRating.score(0.5, votesUp: Int.max, votesDown: 1).totalVotes == Int.max)
    }
}

/// `URLComponents.queryItems` leaves `+` bare, and Steam reads a bare `+` in
/// a query string as a space; every Workshop URL has to encode it as `%2B`.
@Suite("Workshop URL encoding")
struct WorkshopURLEncodingTests {
    private static let key = "0123456789abcdef0123456789abcdef"

    @Test("A plus in the search text or a tag reaches Steam as %2B on every URL")
    func plusIsPercentEncodedEverywhere() throws {
        let request = WorkshopQueryRequest(sort: .search, searchText: "C++", requiredTags: ["A+B"])

        let keyed = try WorkshopQueryService.buildQueryFilesURL(for: request, apiKey: Self.key).absoluteString
        #expect(keyed.contains("search_text=C%2B%2B"))
        #expect(keyed.contains("requiredtags%5B0%5D=A%2BB"))
        #expect(!keyed.contains("+"))

        let userFiles = try WorkshopQueryService.buildUserFilesURL(
            for: WorkshopQueryRequest(sort: .lastUpdated, requiredTags: ["A+B"], creatorSteamID: "76561198000000001"),
            steamID: "76561198000000001",
            apiKey: Self.key
        ).absoluteString
        #expect(userFiles.contains("requiredtags%5B0%5D=A%2BB"))
        #expect(!userFiles.contains("+"))

        let browse = WorkshopPublicBrowseURL.url(for: request, appID: 431_960).absoluteString
        #expect(browse.contains("searchtext=C%2B%2B"))
        #expect(browse.contains("requiredtags%5B%5D=A%2BB"))
        #expect(!browse.contains("+"))

        let creator = WorkshopPublicBrowseURL.url(
            for: WorkshopQueryRequest(sort: .lastUpdated, requiredTags: ["A+B"], creatorSteamID: "76561198000000001"),
            appID: 431_960
        ).absoluteString
        #expect(creator.contains("requiredtags%5B%5D=A%2BB"))
        #expect(!creator.contains("+"))
    }

    /// Control: without a `+` the four URLs are byte-identical to what
    /// `URLComponents.queryItems` produced (spaces `%20`, brackets `%5B%5D`).
    @Test("Control: URLs without a plus are unchanged")
    func urlsWithoutPlusAreUnchanged() throws {
        let request = WorkshopQueryRequest(
            sort: .mostPopular, searchText: "neon city", requiredTags: ["3840 x 2160"], excludedTags: ["Application", "Asset"]
        )
        #expect(
            try WorkshopQueryService.buildQueryFilesURL(for: request, apiKey: Self.key).absoluteString
                == "https://api.steampowered.com/IPublishedFileService/QueryFiles/v1/?key=\(Self.key)&appid=431960&numperpage=50&query_type=3&page=1&return_previews=true&return_tags=true&return_metadata=true&return_short_description=true&return_vote_data=true&return_children=true&search_text=neon%20city&days=7&requiredtags%5B0%5D=3840%20x%202160&match_all_tags=true&excludedtags%5B0%5D=Application&excludedtags%5B1%5D=Asset"
        )
        #expect(
            WorkshopPublicBrowseURL.url(for: request, appID: 431_960).absoluteString
                == "https://steamcommunity.com/workshop/browse/?appid=431960&browsesort=trend&p=1&searchtext=neon%20city&days=7&requiredtags%5B%5D=3840%20x%202160&excludedtags%5B%5D=Application&excludedtags%5B%5D=Asset"
        )

        let creatorRequest = WorkshopQueryRequest(
            sort: .lastUpdated, requiredTags: ["3840 x 2160"], excludedTags: ["Application"], creatorSteamID: "76561198000000001"
        )
        #expect(
            try WorkshopQueryService.buildUserFilesURL(for: creatorRequest, steamID: "76561198000000001", apiKey: Self.key).absoluteString
                == "https://api.steampowered.com/IPublishedFileService/GetUserFiles/v1/?key=\(Self.key)&steamid=76561198000000001&appid=431960&sortmethod=lastupdated&numperpage=50&page=1&return_previews=true&return_tags=true&return_metadata=true&return_short_description=true&return_vote_data=true&return_children=true&requiredtags%5B0%5D=3840%20x%202160&excludedtags%5B0%5D=Application"
        )
        #expect(
            WorkshopPublicBrowseURL.url(for: creatorRequest, appID: 431_960).absoluteString
                == "https://steamcommunity.com/profiles/76561198000000001/myworkshopfiles/?appid=431960&numperpage=30&p=1&requiredtags%5B%5D=3840%20x%202160"
        )
    }
}

@Suite("WorkshopQueryItem fields")
struct WorkshopQueryItemFieldsTests {
    private static let validKey = String(repeating: "a1b2c3d4", count: 4)

    /// First entry of the captured `QueryFiles` page (`q_preset_children.json`,
    /// 2026-09-07): a Preset whose single child is the wallpaper it restyles.
    @Test("Keyed items carry vote data, creation time, comment count and children")
    func keyedItemFields() async throws {
        let service = Self.makeService()
        let page = try await service.fetch(WorkshopQueryRequest(sort: .mostPopular, searchText: "fields"))

        let preset = try #require(page.items.first { $0.id == 1_858_166_341 })
        #expect(preset.rating == .score(0.9151081442832947, votesUp: 6213, votesDown: 531))
        #expect(preset.timeCreated == Date(timeIntervalSince1970: 1_567_982_967))
        #expect(preset.timeUpdated == Date(timeIntervalSince1970: 1_751_752_983))
        #expect(preset.commentCount == 108)
        #expect(preset.requiredItemIDs == [1_081_733_658])

        // Control: an entry Steam returned without vote data or children.
        let plain = try #require(page.items.first { $0.id == 222 })
        #expect(plain.rating == nil)
        #expect(plain.timeCreated == nil)
        #expect(plain.commentCount == nil)
        #expect(plain.requiredItemIDs == [])

        // Children are ordered by `sortorder`, not by wire order.
        let twoChildren = try #require(page.items.first { $0.id == 333 })
        #expect(twoChildren.requiredItemIDs == [42, 1_081_733_658])
    }

    @Test("QueryFiles and GetUserFiles ask for children, never for details")
    func requestsAskForChildren() throws {
        let request = WorkshopQueryRequest(sort: .mostPopular)
        let query = Dictionary(
            uniqueKeysWithValues: request.apiQueryItems(apiKey: "FAKEKEY", appID: WorkshopQueryService.wallpaperEngineAppID)
                .map { ($0.name, $0.value ?? "") }
        )
        #expect(query["return_children"] == "true")
        // `return_details=true` drops `vote_data` and `short_description` from the response (verified 2026-09-07).
        #expect(query["return_details"] == nil)
        #expect(query["return_vote_data"] == "true")

        let userFiles = try WorkshopQueryService.buildUserFilesURL(
            for: WorkshopQueryRequest(sort: .lastUpdated, creatorSteamID: "76561198000000001"),
            steamID: "76561198000000001",
            apiKey: "0123456789abcdef0123456789abcdef"
        )
        let userQuery = Dictionary(
            uniqueKeysWithValues: (URLComponents(url: userFiles, resolvingAgainstBaseURL: false)?.queryItems ?? [])
                .map { ($0.name, $0.value ?? "") }
        )
        #expect(userQuery["return_children"] == "true")
        #expect(userQuery["return_details"] == nil)
    }

    /// Expected values computed from the fixture's SSR payload
    /// (`results[0]`: star_rating 5, total_votes 175, num_comments_public 23,
    /// time_created 1788435379, children []).
    @Test("Keyless items map star_rating/total_votes to stars plus the same fields")
    func keylessItemFields() throws {
        let page = try WorkshopPublicBrowsePayload.page(
            fromHTML: WorkshopBrowseFixture.base(),
            matching: WorkshopPublicSearchSSRTests.fixtureRequest,
            appID: WorkshopQueryService.wallpaperEngineAppID
        )
        let first = try #require(page.items.first)
        #expect(first.id == 3_794_937_077)
        #expect(first.rating == .stars(5, totalVotes: 175))
        #expect(first.commentCount == 23)
        #expect(first.timeCreated == Date(timeIntervalSince1970: 1_788_435_379))
        #expect(first.requiredItemIDs == [])
        // The page carries star_rating -1 for unrated items: they become zero
        // stars ("no ratings yet"), never a negative count or a missing rating.
        let stars = page.items.compactMap { item -> Int? in
            guard case let .stars(value, _)? = item.rating else { return nil }
            return value
        }
        #expect(stars.count == page.items.count)
        #expect(stars.allSatisfy { $0 >= 0 })
        #expect(stars.contains(0))
    }

    /// No item on the captured page has children, so the first result is
    /// given two, out of `sortorder`.
    @Test("Keyless children are read and ordered by sortorder")
    func keylessChildrenOrdered() throws {
        let html = try WorkshopBrowseFixture.replacing(
            #"\\\"num_children\\\":0,\\\"children\\\":[],\\\"previews\\\":[],\\\"time_created\\\":1788435379,"#,
            with: #"\\\"num_children\\\":2,\\\"children\\\":[{\\\"publishedfileid\\\":\\\"1081733658\\\",\\\"sortorder\\\":2,\\\"file_type\\\":0},{\\\"publishedfileid\\\":\\\"42\\\",\\\"sortorder\\\":1,\\\"file_type\\\":0}],\\\"previews\\\":[],\\\"time_created\\\":1788435379,"#,
            in: WorkshopBrowseFixture.base()
        )
        let page = try WorkshopPublicBrowsePayload.page(
            fromHTML: html,
            matching: WorkshopPublicSearchSSRTests.fixtureRequest,
            appID: WorkshopQueryService.wallpaperEngineAppID
        )
        let first = try #require(page.items.first)
        #expect(first.id == 3_794_937_077)
        #expect(first.requiredItemIDs == [42, 1_081_733_658])
        // Control: the rest of the page is untouched.
        #expect(page.items.dropFirst().flatMap(\.requiredItemIDs).isEmpty)
    }

    private static func makeService() -> WorkshopQueryService {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("workshop-query-fields-\(UUID().uuidString)", isDirectory: true)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [WorkshopQueryFieldsStub.self]
        return WorkshopQueryService(
            keychain: WorkshopKeychainStore(directory: directory, slot: WorkshopKeychainSlotSpy(stored: Self.validKey).slot()),
            cache: WorkshopQueryCache(directoryURL: directory.appendingPathComponent("cache")),
            session: URLSession(configuration: config)
        )
    }
}

private final class WorkshopQueryFieldsStub: URLProtocol, @unchecked Sendable {
    private static let body = Data("""
    {"response":{"total":3,"publishedfiledetails":[\
    {"result":1,"publishedfileid":"1858166341","creator":"76561198172313010","title":"Anime beat collection 16:9",\
    "short_description":"Collection with the best images of Wacho 16:9",\
    "preview_url":"https://images.steamusercontent.com/ugc/9356512157826750130/DE7E0D22306572671C64DDB73827616EAD60744D/",\
    "file_size":"129435918","time_created":1567982967,"time_updated":1751752983,"visibility":0,"banned":false,\
    "subscriptions":177101,"lifetime_subscriptions":1324838,"favorited":24952,"lifetime_favorited":34664,"views":74050,\
    "num_comments_public":108,"num_children":1,\
    "tags":[{"tag":"Web","display_name":"Web"},{"tag":"Anime","display_name":"Anime"},{"tag":"Preset","display_name":"Preset"}],\
    "children":[{"publishedfileid":"1081733658","sortorder":1,"file_type":0}],\
    "vote_data":{"score":0.9151081442832947,"votes_up":6213,"votes_down":531}},\
    {"result":1,"publishedfileid":"222","title":"Plain","visibility":0,"banned":false,"time_updated":1},\
    {"result":1,"publishedfileid":"333","title":"Two children","visibility":0,"banned":false,"num_children":2,\
    "children":[{"publishedfileid":"1081733658","sortorder":2,"file_type":0},{"publishedfileid":"42","sortorder":1,"file_type":0}]}]}}
    """.utf8)

    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
#endif
