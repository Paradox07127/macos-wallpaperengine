import SwiftUI

/// How large library grid tiles are drawn. One global preference, read by every
/// library page, so the five grids never disagree about tile size.
public enum LibraryTileSize: String, CaseIterable, Identifiable, Sendable {
    case small
    case medium
    case large

    public var id: String {
        rawValue
    }

    public var title: LocalizedStringKey {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        }
    }

    public static let preferencesKey = "loomscreen.library.tileSize.v1"
}

public extension EnvironmentValues {
    /// Set once at the app root from the stored preference; library grids read
    /// it rather than each reaching for `@AppStorage` and drifting.
    @Entry var libraryTileSize: LibraryTileSize = .medium
}
