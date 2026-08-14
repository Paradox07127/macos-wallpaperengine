import Foundation

// MARK: - Monitor overlay configuration

/// Overlay window z-order (not a wallpaper type; per-screen on `monitorOverlay`).
public enum MonitorOverlayLevel: String, Codable, Sendable, CaseIterable {
    /// Below app windows; click-through so desktop icons stay usable.
    case desktop
    /// Always-on-top dashboard.
    case front
}

public struct MonitorOverlayConfiguration: Codable, Equatable, Sendable {
    /// Opt-in per display (default off).
    public var enabled: Bool
    public var level: MonitorOverlayLevel
    public var board: MonitorBoardConfiguration

    public static let `default` = MonitorOverlayConfiguration()

    public init(
        enabled: Bool = false,
        level: MonitorOverlayLevel = .desktop,
        board: MonitorBoardConfiguration = .default
    ) {
        self.enabled = enabled
        self.level = level
        self.board = board
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, level, board
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        // Unknown future level → desktop rather than failing overlay decode.
        level = (try? c.decodeIfPresent(MonitorOverlayLevel.self, forKey: .level)) ?? .desktop
        board = try c.decodeIfPresent(MonitorBoardConfiguration.self, forKey: .board) ?? .default
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(level, forKey: .level)
        try c.encode(board, forKey: .board)
    }

    /// Absent or corrupt key → nil (caller keeps default).
}
