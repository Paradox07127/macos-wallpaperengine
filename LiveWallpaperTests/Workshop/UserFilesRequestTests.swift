#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import Testing

@Suite("Workshop GetUserFiles request")
struct UserFilesRequestTests {
    @Test("creator-scoped URL states sortmethod and steamid explicitly")
    func userFilesURLCarriesSortMethodAndSteamID() throws {
        let request = WorkshopQueryRequest(
            sort: .lastUpdated,
            page: 2,
            creatorSteamID: "76561198000000001"
        )
        let steamID = try #require(request.creatorSteamID)
        let url = try WorkshopQueryService.buildUserFilesURL(
            for: request,
            steamID: steamID,
            apiKey: "0123456789abcdef0123456789abcdef"
        )
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = try #require(components.queryItems)
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }

        #expect(url.absoluteString.contains("IPublishedFileService/GetUserFiles"))
        #expect(value("sortmethod") == "lastupdated")
        #expect(value("steamid") == "76561198000000001")
        #expect(value("appid") == String(WorkshopQueryService.wallpaperEngineAppID))
        #expect(value("page") == "2")
        // GetUserFiles has no text-search field; asserting its absence keeps
        // the request honest if someone later routes searchText through here.
        #expect(value("search_text") == nil)
    }
}
#endif
