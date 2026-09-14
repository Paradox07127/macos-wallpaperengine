import Foundation

// MARK: - Monitor overlay configuration

/// Overlay window z-order (not a wallpaper type; per-screen on `monitorOverlay`).
public enum MonitorOverlayLevel: String, Codable, Sendable, CaseIterable {
    /// Below app windows; click-through so desktop icons stay usable.
    case desktop
    case front
}

public struct MonitorOverlayConfiguration: Codable, Equatable, Sendable {
    /// Opt-in per display (default off). Governs the Monitor board only —
    /// the Now Playing layer has its own switch so either can run alone.
    public var enabled: Bool
    public var level: MonitorOverlayLevel
    public var music: MusicOverlayConfiguration
    public var clock: ClockOverlayConfiguration
    /// Monitor widgets only.
    public var board: MonitorBoardConfiguration

    public static let `default` = MonitorOverlayConfiguration()

    public init(
        enabled: Bool = false,
        level: MonitorOverlayLevel = .desktop,
        music: MusicOverlayConfiguration = .default,
        clock: ClockOverlayConfiguration? = nil,
        board: MonitorBoardConfiguration = .default
    ) {
        self.enabled = enabled
        self.level = level
        self.music = music
        self.board = board
        self.clock = clock ?? board.widgets.first(where: { $0.kind == .nixieClock }).map {
            ClockOverlayConfiguration(enabled: enabled, level: level, x: $0.x, y: $0.y, width: 356)
        } ?? .default
        self.board.widgets.removeAll { $0.kind == .nixieClock }
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, level, music, clock, board
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        level = (try? c.decodeIfPresent(MonitorOverlayLevel.self, forKey: .level)) ?? .desktop
        music = ((try? c.decodeIfPresent(MusicOverlayConfiguration.self, forKey: .music)) ?? nil) ?? .default
        // Strict on purpose: substituting a default for an unreadable board would resurrect the
        // display wearing a layout the user never chose. Absent or null → default board.
        board = try c.decodeIfPresent(MonitorBoardConfiguration.self, forKey: .board) ?? .default
        let legacy = board.widgets.first(where: { $0.kind == .nixieClock })
        let migrated: ClockOverlayConfiguration = if let legacy {
            ClockOverlayConfiguration(enabled: enabled, level: level, x: legacy.x, y: legacy.y, width: 356)
        } else {
            .default
        }
        // Lenient unlike `board`: a clock nobody can read is one missing decoration, while
        // throwing here would drop the display's whole entry.
        clock = ((try? c.decodeIfPresent(ClockOverlayConfiguration.self, forKey: .clock)) ?? nil) ?? migrated
        board.widgets.removeAll { $0.kind == .nixieClock }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(level, forKey: .level)
        try c.encode(music, forKey: .music)
        try c.encode(clock.normalized, forKey: .clock)
        try c.encode(board, forKey: .board)
    }
}
