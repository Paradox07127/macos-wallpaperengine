import Foundation
import SwiftUI

/// Top-level automation mode chosen by the user per screen; `playlist` is the default.
public enum WallpaperMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case playlist
    case schedule

    public var id: String { rawValue }

    /// Tolerant decoder: a persisted `single` mode decodes to `.playlist`, a one-entry
    /// playlist.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = WallpaperMode(rawValue: rawValue) ?? .playlist
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var labelKey: LocalizedStringKey {
        switch self {
        case .playlist: return "Playlist"
        case .schedule: return "Schedule"
        }
    }
}
