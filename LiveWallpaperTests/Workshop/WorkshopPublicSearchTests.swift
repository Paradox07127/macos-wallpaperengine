#if !LITE_BUILD
import Foundation
import Testing
@testable import LiveWallpaper

@Suite("Workshop keyless public search")
struct WorkshopPublicSearchTests {

    /// Href samples copied verbatim from a live
    /// `steamcommunity.com/workshop/browse/?appid=431960` response (2026-08-29):
    /// every result contributes two anchors (thumbnail + title) with the same id,
    /// and the desktop layout appends `&searchtext=` to them.
    @Test("Detail-page hrefs collapse to a de-duplicated, order-preserving id list")
    func hrefsCollapseToOrderedUniqueIDs() {
        let hrefs = [
            "https://steamcommunity.com/sharedfiles/filedetails/?id=2489045207",
            "https://steamcommunity.com/sharedfiles/filedetails/?id=2489045207",
            "https://steamcommunity.com/sharedfiles/filedetails/?id=3789134978",
            "https://steamcommunity.com/sharedfiles/filedetails/?id=3789134978",
            "https://steamcommunity.com/sharedfiles/filedetails/?id=3788999995&searchtext=anime",
            // Control: a details link with no numeric id contributes nothing.
            "https://steamcommunity.com/sharedfiles/filedetails/?id=",
            "https://steamcommunity.com/sharedfiles/filedetails/?id=2489045207"
        ]

        #expect(
            WorkshopPublicIDExtractor.publishedFileIDs(fromHrefs: hrefs)
                == [2_489_045_207, 3_789_134_978, 3_788_999_995]
        )
    }

    @Test("Navigation is limited to Valve's community host over https")
    func navigationAllowListRejectsEverythingElse() {
        #expect(WorkshopPublicNavigationPolicy.allows(URL(string: "https://steamcommunity.com/workshop/browse/?appid=431960")))
        #expect(WorkshopPublicNavigationPolicy.allows(URL(string: "https://cdn.steamcommunity.com/x.css")))
        // Controls: wrong scheme, look-alike host, unrelated host.
        #expect(!WorkshopPublicNavigationPolicy.allows(URL(string: "http://steamcommunity.com/workshop/browse/")))
        #expect(!WorkshopPublicNavigationPolicy.allows(URL(string: "https://steamcommunity.com.evil.example/workshop/browse/")))
        #expect(!WorkshopPublicNavigationPolicy.allows(URL(string: "https://example.com/")))
    }

    /// Pins the query parameters verified live on 2026-08-29: `browsesort`,
    /// `p`, `searchtext`, `requiredtags[]`, `excludedtags[]`.
    @Test("Browse URL carries the verified public-page parameters")
    func browseURLUsesVerifiedParameters() throws {
        let request = WorkshopQueryRequest(
            sort: .search,
            searchText: "neon city",
            page: 3,
            requiredTags: ["Scene"],
            excludedTags: ["Video", "Application"]
        )
        let url = WorkshopPublicBrowseURL.url(for: request, appID: 431_960)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))

        #expect(components.host == "steamcommunity.com")
        #expect(components.path == "/workshop/browse/")
        #expect(components.queryItems?.map { "\($0.name)=\($0.value ?? "")" } == [
            "appid=431960",
            "browsesort=textsearch",
            "p=3",
            "searchtext=neon city",
            "requiredtags[]=Scene",
            "excludedtags[]=Application",
            "excludedtags[]=Video"
        ])
    }

    /// The browse page silently ignores `created_by` (verified live), so a
    /// creator scope has to use the profile's workshop-files page — which in
    /// turn defaults to a 9-item preview unless `numperpage` is set.
    @Test("Creator-scoped requests use the profile workshop page")
    func creatorScopeUsesProfilePage() throws {
        let request = WorkshopQueryRequest(
            sort: .lastUpdated,
            page: 2,
            creatorSteamID: "76561199277412040"
        )
        let url = WorkshopPublicBrowseURL.url(for: request, appID: 431_960)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))

        #expect(components.host == "steamcommunity.com")
        #expect(components.path == "/profiles/76561199277412040/myworkshopfiles/")
        #expect(components.queryItems?.map { "\($0.name)=\($0.value ?? "")" } == [
            "appid=431960",
            "numperpage=30",
            "p=2"
        ])
    }

    // MARK: - Mature tag hand-off

    /// Tag shape copied from a live `GetPublishedFileDetails` response
    /// (2026-08-29): `tags` is an array of objects, each with a `tag` string.
    private static func detailsPayload(id: String, tags: [String]) -> Data {
        let encoded = tags.map { "{\"tag\":\"\($0)\"}" }.joined(separator: ",")
        return Data("""
        {"response":{"result":1,"resultcount":1,"publishedfiledetails":[\
        {"publishedfileid":"\(id)","result":1,"consumer_app_id":431960,\
        "title":"Fixture \(id)","short_description":"summary",\
        "time_updated":1720000000,"visibility":0,"banned":0,\
        "tags":[\(encoded)]}]}}
        """.utf8)
    }

    @Test("A Mature tag survives decode and reaches the browse item, so the blur still fires")
    func matureTagReachesQueryItem() throws {
        let results = SteamWorkshopMetadataService.decodeBatch(
            data: Self.detailsPayload(id: "111", tags: ["Scene", "Mature"]),
            requestedIDs: [111]
        )
        let entry = try #require(results[111]).get()
        #expect(entry.tags == ["Scene", "Mature"])
        #expect(WorkshopPublicSearchSource.queryItem(from: entry).isMatureRated)
    }

    @Test("Control: an item without the Mature tag stays unblurred")
    func nonMatureTagsStayUnblurred() throws {
        let results = SteamWorkshopMetadataService.decodeBatch(
            data: Self.detailsPayload(id: "222", tags: ["Scene", "Anime"]),
            requestedIDs: [222]
        )
        let entry = try #require(results[222]).get()
        #expect(entry.tags == ["Scene", "Anime"])
        #expect(!WorkshopPublicSearchSource.queryItem(from: entry).isMatureRated)
    }

    /// Only links on Valve's own host may contribute ids: the browse page also
    /// renders author-supplied markup.
    @Test("Detail links off the community host contribute no ids")
    func offHostDetailLinksAreDropped() {
        let hrefs = [
            // Control: the real thing still counts.
            "https://steamcommunity.com/sharedfiles/filedetails/?id=2489045207",
            "https://evil.example/sharedfiles/filedetails/?id=9999999999",
            "https://steamcommunity.com.evil.example/sharedfiles/filedetails/?id=8888888888"
        ]

        #expect(WorkshopPublicIDExtractor.publishedFileIDs(fromHrefs: hrefs) == [2_489_045_207])
    }

    // MARK: - HTML harvesting

    /// Markup shape copied from a live browse response (2026-08-29): each result
    /// is a preview anchor plus a title anchor carrying the same id, the query
    /// separator arrives HTML-escaped, and the page also renders author-supplied
    /// links. Steam serves all of this without running a single script, which is
    /// why a plain GET replaced the offscreen web view.
    private static let browseHTMLFragment = """
    <div class="workshopBrowseItems">
    <a href="https://steamcommunity.com/sharedfiles/filedetails/?id=2489045207&amp;searchtext=" class="item_link">
    <div class="workshopItemPreviewHolder"></div></a>
    <a href="https://steamcommunity.com/sharedfiles/filedetails/?id=2489045207&amp;searchtext=" class="workshopItemTitle">Neon City</a>
    <a href="https://steamcommunity.com/sharedfiles/filedetails/?id=3789134978&amp;searchtext=" class="workshopItemTitle">Rainy Alley</a>
    <a href="https://evil.example/sharedfiles/filedetails/?id=9999999999">author link</a>
    <a href="https://steamcommunity.com.evil.example/sharedfiles/filedetails/?id=8888888888">look-alike</a>
    <a href="https://steamcommunity.com/workshop/browse/?appid=431960">Back</a>
    </div>
    """

    @Test("Result ids come straight out of the served HTML, de-duplicated and host-filtered")
    func htmlYieldsOrderedUniqueOnHostIDs() {
        #expect(
            WorkshopPublicIDExtractor.publishedFileIDs(fromHTML: Self.browseHTMLFragment)
                == [2_489_045_207, 3_789_134_978]
        )
    }

    // MARK: - Paging

    /// A full page is not always 30 (p=2 returned 29 on 2026-08-29), so counting
    /// ids against `itemsPerPage` ended browsing early. Only an empty page ends it.
    @Test("A short-but-non-empty page still offers the next one")
    func shortPageStillHasANextPage() {
        #expect(WorkshopPublicSearchSource.nextCursor(after: 2, idCount: 29) == "3")
        // Control: nothing on the page means the result set is exhausted.
        #expect(WorkshopPublicSearchSource.nextCursor(after: 7, idCount: 0) == nil)
    }

    // MARK: - Keyless counts

    @Test("Keyless details carry the subscription count through to the browse item")
    func subscriptionCountReachesQueryItem() throws {
        let payload = Data("""
        {"response":{"result":1,"resultcount":1,"publishedfiledetails":[\
        {"publishedfileid":"333","result":1,"consumer_app_id":431960,\
        "title":"Counted","short_description":"summary","visibility":0,"banned":0,\
        "subscriptions":410,"lifetime_subscriptions":95000,"favorited":12,"views":6100}]}}
        """.utf8)
        let entry = try #require(
            SteamWorkshopMetadataService.decodeBatch(data: payload, requestedIDs: [333])[333]
        ).get()

        // Lifetime wins, matching what "Most Subscribed" actually ranks by.
        #expect(entry.subscriptionCount == 95_000)
        #expect(entry.viewCount == 6_100)
        #expect(entry.favoriteCount == 12)
        let item = WorkshopPublicSearchSource.queryItem(from: entry)
        #expect(item.subscriptionCount == 95_000)
        #expect(item.viewCount == 6_100)
        #expect(item.favoriteCount == 12)
    }

    /// Control: the fields are optional on Valve's side, and their absence must
    /// stay `nil` rather than becoming a fabricated zero.
    @Test("Control: details without counts leave the browse item's count unset")
    func missingCountsStayNil() throws {
        let entry = try #require(
            SteamWorkshopMetadataService.decodeBatch(
                data: Self.detailsPayload(id: "444", tags: ["Scene"]),
                requestedIDs: [444]
            )[444]
        ).get()

        #expect(entry.subscriptionCount == nil)
        let item = WorkshopPublicSearchSource.queryItem(from: entry)
        #expect(item.subscriptionCount == nil)
        #expect(item.viewCount == nil)
        #expect(item.favoriteCount == nil)
    }
}
#endif
