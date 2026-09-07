#if !LITE_BUILD
import Foundation

/// Steam Community pages the detail inspector links out to. Shapes are the
/// detail page's own anchors (captured 2026-09-07 from
/// `sharedfiles/filedetails/?id=3737237256`), pinned by `WorkshopCommunityURLTests`.
enum WorkshopCommunityURL {
    private static let host = "steamcommunity.com"

    static func item(itemID: UInt64) -> URL {
        URL(string: "https://\(host)/sharedfiles/filedetails/?id=\(itemID)")!
    }

    static func changeNotes(itemID: UInt64) -> URL {
        URL(string: "https://\(host)/sharedfiles/filedetails/changelog/\(itemID)")!
    }

    static func comments(itemID: UInt64) -> URL {
        URL(string: "https://\(host)/sharedfiles/filedetails/comments/\(itemID)")!
    }

    static func collections(itemID: UInt64) -> URL {
        URL(string: "https://\(host)/workshop/browse/?browsesort=toprated&section=collections&appid=\(WorkshopQueryService.wallpaperEngineAppID)&childpublishedfileid=\(itemID)")!
    }

    /// `steamID` is a SteamID64 from Steam's own payload; it goes through
    /// `URLComponents` so a malformed value cannot break out of the path.
    static func creatorWorkshop(steamID: String) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/profiles/\(steamID)/myworkshopfiles/"
        components.queryItems = [URLQueryItem(name: "appid", value: String(WorkshopQueryService.wallpaperEngineAppID))]
        return components.url!
    }
}
#endif
