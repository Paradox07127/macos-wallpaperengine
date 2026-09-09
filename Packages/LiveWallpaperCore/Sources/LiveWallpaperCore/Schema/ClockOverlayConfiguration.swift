import Foundation

/// One decorative clock per display, independent of the widget grid.
public struct ClockOverlayConfiguration: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var level: MonitorOverlayLevel
    public var x: Double
    public var y: Double
    /// Width in display points; height follows the rendered object's aspect ratio.
    public var width: Double
    public var uses24HourTime: Bool
    public var padsHour: Bool
    public var blinksSeparators: Bool
    public var opacity: Double

    public static let widthRange = 180.0 ... 1600.0
    public static let aspectRatio = 1256.0 / 460.0
    public static let `default` = ClockOverlayConfiguration()

    public init(
        enabled: Bool = false, level: MonitorOverlayLevel = .desktop,
        x: Double = 0.35, y: Double = 0.66, width: Double = 480,
        uses24HourTime: Bool = true, padsHour: Bool = true,
        blinksSeparators: Bool = false, opacity: Double = 1
    ) {
        self.enabled = enabled
        self.level = level
        self.x = Self.clamp(x, to: 0 ... 1, fallback: 0.35)
        self.y = Self.clamp(y, to: 0 ... 1, fallback: 0.66)
        self.width = Self.clamp(width, to: Self.widthRange, fallback: 480)
        self.uses24HourTime = uses24HourTime
        self.padsHour = padsHour
        self.blinksSeparators = blinksSeparators
        self.opacity = Self.clamp(opacity, to: 0.2 ... 1, fallback: 1)
    }

    public var normalized: Self {
        Self(enabled: enabled, level: level, x: x, y: y, width: width,
             uses24HourTime: uses24HourTime, padsHour: padsHour,
             blinksSeparators: blinksSeparators, opacity: opacity)
    }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>, fallback: Double) -> Double {
        value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : fallback
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, level, x, y, width, uses24HourTime, padsHour, blinksSeparators, opacity
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            enabled: c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false,
            level: (try? c.decodeIfPresent(MonitorOverlayLevel.self, forKey: .level)) ?? .desktop,
            x: c.decodeIfPresent(Double.self, forKey: .x) ?? 0.35,
            y: c.decodeIfPresent(Double.self, forKey: .y) ?? 0.66,
            width: c.decodeIfPresent(Double.self, forKey: .width) ?? 480,
            uses24HourTime: c.decodeIfPresent(Bool.self, forKey: .uses24HourTime) ?? true,
            padsHour: c.decodeIfPresent(Bool.self, forKey: .padsHour) ?? true,
            blinksSeparators: c.decodeIfPresent(Bool.self, forKey: .blinksSeparators) ?? false,
            opacity: c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
        )
    }
}
