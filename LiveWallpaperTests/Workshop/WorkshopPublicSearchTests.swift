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

    /// `BrowseViewModel.reload()` fires a second search while the first page is
    /// still loading; the first waiter has to be settled, exactly once.
    @Test("A superseded page load ends as .cancelled, once")
    @MainActor
    func supersededLoadIsCancelledExactlyOnce() {
        let slot = WorkshopPublicLoadSlot()
        var first: [WorkshopQueryError?] = []
        var second: [WorkshopQueryError?] = []

        let firstToken = slot.begin { first.append(Self.failure(of: $0)) }
        #expect(first.isEmpty)

        let secondToken = slot.begin { second.append(Self.failure(of: $0)) }
        #expect(first == [.cancelled])

        // A late callback from the superseded load (timeout, didFinish) is inert.
        slot.finish(token: firstToken, .failure(WorkshopQueryError.timeout))
        #expect(first == [.cancelled])
        #expect(!slot.isCurrent(firstToken))

        // Control: the live load still settles, and also only once.
        #expect(slot.isCurrent(secondToken))
        slot.finish(token: secondToken, .success(()))
        slot.finish(token: secondToken, .failure(WorkshopQueryError.timeout))
        #expect(second == [nil])
    }

    private static func failure(of result: Result<Void, Error>) -> WorkshopQueryError? {
        guard case .failure(let error) = result else { return nil }
        return error as? WorkshopQueryError
    }
}
#endif
