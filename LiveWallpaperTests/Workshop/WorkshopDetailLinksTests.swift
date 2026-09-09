#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import Testing

/// URL shapes captured from the detail page's own anchors
/// (`curl https://steamcommunity.com/sharedfiles/filedetails/?id=3737237256`, 2026-09-07):
///
///     href="https://steamcommunity.com/sharedfiles/filedetails/changelog/3737237256"
///     href="https://steamcommunity.com/sharedfiles/filedetails/comments/3737237256"
///     href="https://steamcommunity.com/sharedfiles/filedetails/discussions/3737237256"
///     href="https://steamcommunity.com/workshop/browse/?browsesort=toprated&section=collections&appid=431960&childpublishedfileid=3737237256"
///     href="https://steamcommunity.com/profiles/76561198314933366/myworkshopfiles/?appid=431960"
@Suite("Workshop detail page links")
struct WorkshopCommunityURLTests {
    @Test("Item links match the detail page's anchors verbatim")
    func itemLinks() {
        #expect(WorkshopCommunityURL.changeNotes(itemID: 3_737_237_256).absoluteString
            == "https://steamcommunity.com/sharedfiles/filedetails/changelog/3737237256")
        #expect(WorkshopCommunityURL.comments(itemID: 3_737_237_256).absoluteString
            == "https://steamcommunity.com/sharedfiles/filedetails/comments/3737237256")
        #expect(WorkshopCommunityURL.collections(itemID: 3_737_237_256).absoluteString
            == "https://steamcommunity.com/workshop/browse/?browsesort=toprated&section=collections&appid=431960&childpublishedfileid=3737237256")
    }

    @Test("The creator link is the page's own author anchor")
    func creatorLink() {
        #expect(WorkshopCommunityURL.creatorWorkshop(steamID: "76561198314933366").absoluteString
            == "https://steamcommunity.com/profiles/76561198314933366/myworkshopfiles/?appid=431960")
    }
}

/// New inspector copy has to exist in every shipped language: a missing entry
/// silently falls back to English for that language.
@Suite("Workshop detail inspector copy")
struct WorkshopDetailCopyTests {
    private static let keys = [
        "Posted %@ (%@)",
        "Updated %@ (%@)",
        "%@ ratings",
        "No ratings yet",
        "Rating unavailable",
        "Download size: %@",
        "%@ up, %@ down",
        "%@ comments",
        "Comments",
        "Change Notes",
        "Collections",
        "Required items",
        "View presets on Steam",
        "Open %@’s Workshop on Steam",
        "Couldn’t load page %lld.",
        "Loading item…",
    ]

    @Test("Every new key is present in all five languages")
    func keysExistInFiveLanguages() throws {
        let strings = try WorkshopTagTaxonomyTests.catalogStrings()
        for key in Self.keys {
            for locale in ["en", "zh-Hans", "zh-Hant", "ja", "es"] {
                let value = WorkshopTagTaxonomyTests.value(strings, key: key, locale: locale) ?? ""
                #expect(!value.isEmpty, "\(key) [\(locale)]")
            }
        }
    }

    /// The key-free details endpoint carries no vote data at all; that is not
    /// an item nobody has rated.
    @Test("A missing rating reads as unavailable, zero votes as none")
    func ratingCountLabel() {
        #expect(WorkshopDetailIdentityHeader.ratingCountLabel(nil) == .unavailable)
        #expect(WorkshopDetailIdentityHeader.ratingCountLabel(.stars(4, totalVotes: 0)) == .none)
        #expect(WorkshopDetailIdentityHeader.ratingCountLabel(.score(0, votesUp: 0, votesDown: 0)) == .none)
        #expect(WorkshopDetailIdentityHeader.ratingCountLabel(.stars(4, totalVotes: 7)) == .count(7))
        #expect(WorkshopDetailIdentityHeader.ratingCountLabel(.score(0.9, votesUp: 9, votesDown: 1)) == .count(10))
    }
}
#endif
