import Foundation

/// Top-level automation mode chosen by the user per screen; `playlist` is the default.
public enum WallpaperMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case playlist
    case schedule
    case libraryShuffle
    case single

    public var id: String { rawValue }

    /// Tolerant decoder: an unknown persisted mode decodes to `.playlist`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = WallpaperMode(rawValue: rawValue) ?? .playlist
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
