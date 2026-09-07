#if !LITE_BUILD
import Foundation

/// Steam's facet groups for Wallpaper Engine tags, as the Workshop detail page
/// lists them (`workshopTagsTitle`, measured 2026-09-07). Steam sends items a
/// flat tag list; the grouping is ours, from the browse page's facet table.
enum WorkshopTagTaxonomy {
    /// Declaration order is the page's display order.
    enum Group: CaseIterable, Equatable {
        case type
        case ageRating
        case genre
        case resolution
        case category
        case miscellaneous
        /// Not a wallpaper facet: Asset Type / Asset Genre / Script Type tags,
        /// and anything Steam adds later.
        case other

        var displayName: String {
            switch self {
            case .type:
                String(localized: "Type", bundle: .appLanguage, comment: "Workshop tag group: Scene / Video / Web.")
            case .ageRating:
                String(localized: "Age Rating", bundle: .appLanguage, comment: "Workshop tag group: Everyone / Questionable / Mature.")
            case .genre:
                String(localized: "Genre", bundle: .appLanguage, comment: "Workshop tag group.")
            case .resolution:
                String(localized: "Resolution", bundle: .appLanguage, comment: "Workshop tag group.")
            case .category:
                String(localized: "Category", bundle: .appLanguage, comment: "Workshop tag group: Wallpaper / Preset / Asset.")
            case .miscellaneous:
                String(localized: "Miscellaneous", bundle: .appLanguage, comment: "Workshop tag group: feature tags such as Approved or Audio responsive.")
            case .other:
                String(localized: "Other", bundle: .appLanguage, comment: "Workshop tag group for tags outside Steam's wallpaper facets.")
            }
        }
    }

    struct GroupedTags: Equatable {
        let group: Group
        let tags: [String]
    }

    private static let table: [String: Group] = {
        var map: [String: Group] = [:]
        func add(_ tags: [String], _ group: Group) {
            for tag in tags {
                map[tag.lowercased()] = group
            }
        }
        add(["Scene", "Video", "Application", "Web"], .type)
        add(["Everyone", "Questionable", "Mature"], .ageRating)
        add(WorkshopGenre.allTags, .genre)
        add(WorkshopResolutionFilter.allCases.flatMap(\.tags), .resolution)
        add(["Wallpaper", "Preset", "Asset"], .category)
        add([
            "Approved", "Audio responsive", "3D", "Customizable", "Puppet Warp", "HDR",
            "Media Integration", "User Shortcut", "Video Texture", "Asset Pack",
        ], .miscellaneous)
        return map
    }()

    static func group(for tag: String) -> Group {
        table[tag.lowercased()] ?? .other
    }

    /// Groups in `Group` order, tags in the item's own order, empty groups omitted.
    static func grouped(tags: [String]) -> [GroupedTags] {
        Group.allCases.compactMap { group in
            let matching = tags.filter { self.group(for: $0) == group }
            return matching.isEmpty ? nil : GroupedTags(group: group, tags: matching)
        }
    }
}
#endif
