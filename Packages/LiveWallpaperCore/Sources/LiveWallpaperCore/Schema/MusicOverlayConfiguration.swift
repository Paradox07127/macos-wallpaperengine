import Foundation

/// How large the Now Playing layer draws. The three steps match the widget
/// sizes it used to borrow, so a layer keeps its footprint across the split.
public enum MusicOverlaySize: String, Codable, Sendable, CaseIterable {
    case small = "s"
    case medium = "m"
    case large = "l"
}

/// The Now Playing layer's own per-display configuration. It is deliberately not a Monitor widget:
/// there is exactly one per display, it has its own switch and its own window, and it never sits on
/// the board's grid. Modelling it as a widget meant one array held two modules' contents, so every
/// reader filtered it in half and every writer had to merge it back — and a missed merge silently
/// deleted the other module's widgets.
public struct MusicOverlayConfiguration: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var level: MonitorOverlayLevel
    public var size: MusicOverlaySize
    /// Normalized top-left on the display, 0…1.
    public var x: Double
    public var y: Double
    /// Appearance and behaviour keys, read through `NowPlayingOptions`.
    public var options: [String: MonitorWidgetOptionValue]

    public static let `default` = MusicOverlayConfiguration()

    public init(
        enabled: Bool = false,
        level: MonitorOverlayLevel = .desktop,
        size: MusicOverlaySize = .medium,
        x: Double = 0,
        y: Double = 0,
        options: [String: MonitorWidgetOptionValue] = [:]
    ) {
        self.enabled = enabled
        self.level = level
        self.size = size
        self.x = Self.clamped(x)
        self.y = Self.clamped(y)
        self.options = options
    }

    private static func clamped(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), 1) : 0
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, level, size, x, y, options
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        // Unknown future level/size → the default rather than failing the whole decode.
        let level = ((try? c.decodeIfPresent(MonitorOverlayLevel.self, forKey: .level)) ?? nil) ?? .desktop
        let size = ((try? c.decodeIfPresent(MusicOverlaySize.self, forKey: .size)) ?? nil) ?? .medium
        self.init(
            enabled: enabled,
            level: level,
            size: size,
            x: try c.decodeIfPresent(Double.self, forKey: .x) ?? 0,
            y: try c.decodeIfPresent(Double.self, forKey: .y) ?? 0,
            options: try c.decodeIfPresent([String: MonitorWidgetOptionValue].self, forKey: .options) ?? [:]
        )
    }
}
