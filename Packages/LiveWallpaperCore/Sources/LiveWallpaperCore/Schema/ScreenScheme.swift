import CoreGraphics
import Foundation

/// Local archive only: the media is reached through per-machine security-scoped
/// bookmarks, so a scheme cannot travel to another Mac even though it encodes cleanly.
public struct ScreenScheme: Identifiable, Codable, Equatable, Sendable {
    /// Sentinel display id for an archived scheme: 0 is never a live display's
    /// `CGDirectDisplayID`.
    public static let unboundScreenID: CGDirectDisplayID = 0

    public let id: UUID
    public var name: String
    public let createdAt: Date
    public var updatedAt: Date
    /// Screen this was captured from; display only, never used to match a target.
    public var sourceDisplayName: String?
    /// Identity-stripped on the way in (see `stripped`), re-bound on the way out.
    public var configuration: ScreenConfiguration
    public var overlay: MonitorOverlayConfiguration
    /// File name of the still captured when this was saved, in the app's cover directory;
    /// not carried by an exported bundle, so an imported scheme falls back to the thumbnail.
    public var coverFileName: String?

    public init(
        name: String,
        configuration: ScreenConfiguration,
        overlay: MonitorOverlayConfiguration,
        id: UUID = UUID(),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        sourceDisplayName: String? = nil,
        coverFileName: String? = nil
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sourceDisplayName = sourceDisplayName
        // Strip here, not at the call site: this is the only memberwise entry point, so no
        // future capture path can archive a live display's identity by forgetting to ask.
        self.configuration = Self.stripped(configuration)
        self.overlay = overlay
        self.coverFileName = coverFileName
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, createdAt, updatedAt, sourceDisplayName, configuration, overlay, coverFileName
    }

    /// Hand-written for `overlay` alone: schemes decode as one array, so a synthesised
    /// decoder would let one corrupt overlay take the whole archive down.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        sourceDisplayName = try c.decodeIfPresent(String.self, forKey: .sourceDisplayName)
        configuration = try c.decode(ScreenConfiguration.self, forKey: .configuration)
        overlay = (try? c.decode(MonitorOverlayConfiguration.self, forKey: .overlay)) ?? .default
        coverFileName = try c.decodeIfPresent(String.self, forKey: .coverFileName)
    }

    /// Blanks the two display-identity fields with sentinels. `videoDisplayMode`
    /// deliberately stays — neither of its cases names a screen.
    public static func stripped(_ configuration: ScreenConfiguration) -> ScreenConfiguration {
        var copy = configuration
        copy.screenID = unboundScreenID
        copy.displayFingerprint = nil
        return copy
    }

    public func rebound(to screenID: CGDirectDisplayID, fingerprint: String?) -> ScreenConfiguration {
        configuration.reboundToDisplay(screenID, fingerprint: fingerprint)
    }
}

public extension ScreenConfiguration {
    /// Both identity fields move together: keeping the source row's fingerprint would
    /// leave the copy unreachable by fingerprint after a display-ID reshuffle.
    func reboundToDisplay(
        _ screenID: CGDirectDisplayID,
        fingerprint: String?
    ) -> ScreenConfiguration {
        var copy = self
        copy.screenID = screenID
        copy.displayFingerprint = fingerprint
        return copy
    }
}
