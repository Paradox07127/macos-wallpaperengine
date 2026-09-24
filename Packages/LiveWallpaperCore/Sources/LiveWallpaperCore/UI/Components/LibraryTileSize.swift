import SwiftUI

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
    /// What every reader of the preference falls back to until the user picks a size.
    public static let defaultSize: LibraryTileSize = .small
}

public extension EnvironmentValues {
    @Entry var libraryTileSize: LibraryTileSize = .defaultSize
}
