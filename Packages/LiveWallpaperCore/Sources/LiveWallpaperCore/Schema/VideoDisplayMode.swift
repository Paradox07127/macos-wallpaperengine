import SwiftUI

public enum VideoDisplayMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case perDisplay = "Per Display"
    case spanAllDisplays = "Span All Displays"

    /// Tolerant decoder: an unknown display mode (future build's addition, rolled back)
    /// decodes to `.perDisplay` instead of failing the whole `ScreenConfiguration` parse.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        if let mode = VideoDisplayMode(rawValue: rawValue) {
            self = mode
        } else {
            Logger.warning("VideoDisplayMode: unknown rawValue \"\(rawValue)\", defaulting to perDisplay", category: .settings)
            self = .perDisplay
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var id: String { rawValue }
}
