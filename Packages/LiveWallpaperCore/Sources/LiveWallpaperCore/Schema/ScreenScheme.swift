import CoreGraphics
import Foundation

/// One display's complete setup — wallpaper configuration plus both overlay
/// layers — archived independently of the monitor it came from.
///
/// Local archive only. The media behind a configuration is reached through
/// security-scoped bookmarks, which are per-machine grants, so a scheme cannot
/// travel to another Mac even though it encodes cleanly.
public struct ScreenScheme: Identifiable, Codable, Equatable, Sendable {
    /// Stored in place of a real display id. 0 is never a live display's
    /// `CGDirectDisplayID`, so an archived scheme can be told apart from a
    /// configuration that belongs to a screen.
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

    public init(
        name: String,
        configuration: ScreenConfiguration,
        overlay: MonitorOverlayConfiguration,
        id: UUID = UUID(),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        sourceDisplayName: String? = nil
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sourceDisplayName = sourceDisplayName
        // Stripping here, not at the capture call site: this is the only
        // memberwise entry point, so no future capture path can archive a live
        // display's identity by forgetting to ask.
        self.configuration = Self.stripped(configuration)
        self.overlay = overlay
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, createdAt, updatedAt, sourceDisplayName, configuration, overlay
    }

    /// Hand-written for one field: `MonitorOverlayConfiguration` fails its decode
    /// when the board it carries is unreadable, which is right for
    /// `GlobalSettings.monitorOverlays` (a lossy dictionary drops that one display)
    /// but wrong here — schemes are decoded as one array, so a synthesised decoder
    /// would let a single corrupt overlay take the whole archive down, and the next
    /// capture would rewrite the file with only the new entry. A scheme is mostly
    /// its wallpaper configuration; the overlay falls back rather than sinking it.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        sourceDisplayName = try c.decodeIfPresent(String.self, forKey: .sourceDisplayName)
        configuration = try c.decode(ScreenConfiguration.self, forKey: .configuration)
        overlay = (try? c.decode(MonitorOverlayConfiguration.self, forKey: .overlay)) ?? .default
    }

    /// Blanks the two display-identity fields with sentinels.
    ///
    /// Sentinels rather than a trimmed `ScreenSchemeConfiguration` type:
    /// `ScreenConfiguration` has hand-written `init(from:)` / `encode(to:)` over
    /// ~25 fields, so a parallel struct would mean a parallel codec that has to
    /// be edited in lockstep. A field added to one and missed in the other fails
    /// silently — the scheme would simply lose that setting with nothing red.
    /// One shape, one codec, two sentinel values.
    ///
    /// `videoDisplayMode` deliberately stays: its only cases are `.perDisplay`
    /// and `.spanAllDisplays`, neither of which names a screen.
    public static func stripped(_ configuration: ScreenConfiguration) -> ScreenConfiguration {
        var copy = configuration
        copy.screenID = unboundScreenID
        copy.displayFingerprint = nil
        return copy
    }

    /// The archived configuration re-stamped for a live display.
    public func rebound(to screenID: CGDirectDisplayID, fingerprint: String?) -> ScreenConfiguration {
        configuration.reboundToDisplay(screenID, fingerprint: fingerprint)
    }
}

public extension ScreenConfiguration {
    /// Re-stamps both identity fields so this configuration describes `screenID`.
    ///
    /// Both fields move together on purpose: keeping the source row's
    /// fingerprint would leave the copy unreachable by fingerprint after a
    /// display-ID reshuffle. Shared by apply-to-all-displays and scheme apply so
    /// the two cannot drift apart.
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
