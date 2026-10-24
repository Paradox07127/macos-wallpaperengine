#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import Testing

@Suite("Workshop detail page links")
struct WorkshopCommunityURLTests {
    @Test("The item link is the detail page's own address")
    func itemLink() {
        #expect(WorkshopCommunityURL.item(itemID: 3_737_237_256).absoluteString
            == "https://steamcommunity.com/sharedfiles/filedetails/?id=3737237256")
    }

    @Test("The creator link is the page's own author anchor")
    func creatorLink() {
        #expect(WorkshopCommunityURL.creatorWorkshop(steamID: "76561198314933366").absoluteString
            == "https://steamcommunity.com/profiles/76561198314933366/myworkshopfiles/?appid=431960")
    }
}

@Suite("Workshop detail inspector copy")
struct WorkshopDetailCopyTests {
    private static let keys = [
        "%lld ratings",
        "%@ up, %@ down",
        "Required items",
        "Set your Steam Web API key in Settings to list presets here.",
        "%lld more presets are only on Steam",
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
}
#endif
