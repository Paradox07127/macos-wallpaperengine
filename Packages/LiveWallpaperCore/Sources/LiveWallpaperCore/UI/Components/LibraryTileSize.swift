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
}

public extension EnvironmentValues {
    @Entry var libraryTileSize: LibraryTileSize = .medium
}
