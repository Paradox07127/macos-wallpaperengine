import LiveWallpaperCore
import SwiftUI

enum SavedLibrarySortOrder: String, CaseIterable, Identifiable {
    case recent
    case name
    case type

    static let preferencesKey = "loomscreen.savedLibrary.sortOrder.v1"

    var id: Self {
        self
    }

    var title: String {
        switch self {
        case .recent: String(localized: "Recent", bundle: .appLanguage, comment: "Saved library sort order: most recent first.")
        case .name: String(localized: "Name", bundle: .appLanguage, comment: "Saved library sort order: alphabetical.")
        case .type: String(localized: "Type", bundle: .appLanguage, comment: "Saved library sort order: grouped by wallpaper type.")
        }
    }
}

struct SavedLibrarySortPicker: View {
    @Binding var selection: SavedLibrarySortOrder

    var body: some View {
        Picker("Sort", selection: $selection) {
            ForEach(SavedLibrarySortOrder.allCases) { order in
                Text(verbatim: order.title).tag(order)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .controlSize(.small)
        .fixedSize()
        .help(Text("Sort the library"))
    }
}

extension SavedLibrarySortOrder {
    /// `date` is whatever "recent" means for the entry kind — creation for a bookmark, last capture for a scheme.
    func sorted<Element>(
        _ elements: [Element],
        name: (Element) -> String,
        date: (Element) -> Date,
        type: (Element) -> WallpaperType
    ) -> [Element] {
        switch self {
        case .recent:
            elements.sorted { date($0) > date($1) }
        case .name:
            elements.sorted { name($0).localizedStandardCompare(name($1)) == .orderedAscending }
        case .type:
            elements.sorted { lhs, rhs in
                let lhsType = type(lhs), rhsType = type(rhs)
                if lhsType != rhsType {
                    return lhsType.rawValue < rhsType.rawValue
                }
                return name(lhs).localizedStandardCompare(name(rhs)) == .orderedAscending
            }
        }
    }
}
