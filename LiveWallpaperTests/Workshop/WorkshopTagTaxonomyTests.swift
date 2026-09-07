#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import Testing

/// Steam's own facet groups for Wallpaper Engine tags, as the detail page
/// lists them (`workshopTagsTitle`, measured 2026-09-07 on 3737237256).
@Suite("Workshop tag taxonomy")
struct WorkshopTagTaxonomyTests {
    @Test("Known tags land in Steam's facet group; unknown ones in Other")
    func groupForTag() {
        #expect(WorkshopTagTaxonomy.group(for: "Anime") == .genre)
        #expect(WorkshopTagTaxonomy.group(for: "Ultrawide 3440 x 1440") == .resolution)
        #expect(WorkshopTagTaxonomy.group(for: "Approved") == .miscellaneous)
        #expect(WorkshopTagTaxonomy.group(for: "Preset") == .category)
        #expect(WorkshopTagTaxonomy.group(for: "Scene") == .type)
        #expect(WorkshopTagTaxonomy.group(for: "Everyone") == .ageRating)
        #expect(WorkshopTagTaxonomy.group(for: "Foo") == .other)
        // Asset-only facets (Asset Type / Asset Genre / Script Type) are not
        // wallpaper facets and fold into Other.
        #expect(WorkshopTagTaxonomy.group(for: "Particle") == .other)
    }

    @Test("Every filter tag the ribbon knows is classified, so none falls into Other")
    func filterTagsAreClassified() {
        for tag in WorkshopGenre.allTags {
            #expect(WorkshopTagTaxonomy.group(for: tag) == .genre, Comment(rawValue: tag))
        }
        for tag in WorkshopResolutionFilter.allCases.flatMap(\.tags) {
            #expect(WorkshopTagTaxonomy.group(for: tag) == .resolution, Comment(rawValue: tag))
        }
        #expect(WorkshopResolutionFilter.allCases.flatMap(\.tags).count == 25)
    }

    @Test("Grouping keeps Steam's group order and the item's tag order, dropping empty groups")
    func groupedKeepsFixedOrder() {
        // Wire order on a real item: Approved, Video, Everyone, Nature, 3840 x 2160, Wallpaper.
        let grouped = WorkshopTagTaxonomy.grouped(
            tags: ["Approved", "Video", "Everyone", "Nature", "Anime", "3840 x 2160", "Wallpaper", "Foo"]
        )
        #expect(grouped.map(\.group) == [.type, .ageRating, .genre, .resolution, .category, .miscellaneous, .other])
        #expect(grouped.map(\.tags) == [["Video"], ["Everyone"], ["Nature", "Anime"], ["3840 x 2160"], ["Wallpaper"], ["Approved"], ["Foo"]])

        let sparse = WorkshopTagTaxonomy.grouped(tags: ["Anime", "Scene"])
        #expect(sparse.map(\.group) == [.type, .genre])
        #expect(WorkshopTagTaxonomy.grouped(tags: []).isEmpty)
    }

    @Test("Group names exist in all five languages")
    func groupNamesAreLocalized() throws {
        let strings = try Self.catalogStrings()
        for key in ["Type", "Age Rating", "Genre", "Resolution", "Category", "Miscellaneous", "Other"] {
            for locale in ["en", "zh-Hans", "zh-Hant", "ja", "es"] {
                let value = Self.value(strings, key: key, locale: locale) ?? ""
                #expect(!value.isEmpty, "\(key) [\(locale)]")
            }
        }
    }

    static func catalogStrings() throws -> [String: Any] {
        let data = try RepositoryRoot.data("LiveWallpaper/Resources/Localizable.xcstrings")
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(root["strings"] as? [String: Any])
    }

    /// Xcode omits the `en` entry when the key is the English text itself
    /// (same rule as `scripts/check_localization_drift.py`).
    static func value(_ strings: [String: Any], key: String, locale: String) -> String? {
        guard let entry = strings[key] as? [String: Any] else { return nil }
        let localizations = entry["localizations"] as? [String: Any]
        let unit = (localizations?[locale] as? [String: Any])?["stringUnit"] as? [String: Any]
        if let value = unit?["value"] as? String {
            return value
        }
        return locale == "en" ? key : nil
    }
}
#endif
