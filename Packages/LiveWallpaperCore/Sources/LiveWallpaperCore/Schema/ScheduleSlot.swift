import Foundation

public struct ScheduleSlot: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    /// Minute of the day the slot starts, 0..<1440.
    public var startMinute: Int
    /// Exclusive end minute; 0 and 1440 both mean the slot ends at midnight.
    public var endMinute: Int
    public var videoBookmarkData: Data?
    public var label: String
    public var wallpaper: WallpaperQueueEntry?

    public init(
        id: UUID = UUID(),
        startMinute: Int,
        endMinute: Int,
        videoBookmarkData: Data? = nil,
        label: String,
        wallpaper: WallpaperQueueEntry? = nil
    ) {
        self.id = id
        self.startMinute = startMinute
        self.endMinute = endMinute
        self.videoBookmarkData = videoBookmarkData
        self.label = label
        self.wallpaper = wallpaper
    }

    public init(
        id: UUID = UUID(),
        startHour: Int,
        endHour: Int,
        videoBookmarkData: Data? = nil,
        label: String,
        wallpaper: WallpaperQueueEntry? = nil
    ) {
        self.init(id: id, startMinute: startHour * 60, endMinute: endHour * 60, videoBookmarkData: videoBookmarkData, label: label, wallpaper: wallpaper)
    }

    private enum CodingKeys: String, CodingKey {
        case id, startMinute, endMinute, startHour, endHour, videoBookmarkData, label, wallpaper
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        startMinute = try Self.decodeMinute(container, minuteKey: .startMinute, hourKey: .startHour)
        endMinute = try Self.decodeMinute(container, minuteKey: .endMinute, hourKey: .endHour)
        videoBookmarkData = try container.decodeIfPresent(Data.self, forKey: .videoBookmarkData)
        label = try container.decode(String.self, forKey: .label)
        wallpaper = try container.decodeIfPresent(WallpaperQueueEntry.self, forKey: .wallpaper)
    }

    private static func decodeMinute(_ container: KeyedDecodingContainer<CodingKeys>, minuteKey: CodingKeys, hourKey: CodingKeys) throws -> Int {
        if let minute = try container.decodeIfPresent(Int.self, forKey: minuteKey) {
            return minute
        }
        if let hour = try container.decodeIfPresent(Int.self, forKey: hourKey) {
            return hour * 60
        }
        return try container.decode(Int.self, forKey: minuteKey)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(startMinute, forKey: .startMinute)
        try container.encode(endMinute, forKey: .endMinute)
        // Older app versions require both hour keys to decode a slot at all.
        try container.encode(startMinute / 60, forKey: .startHour)
        try container.encode(endMinute / 60, forKey: .endHour)
        try container.encodeIfPresent(videoBookmarkData, forKey: .videoBookmarkData)
        try container.encode(label, forKey: .label)
        try container.encodeIfPresent(wallpaper, forKey: .wallpaper)
    }

    /// Must stay computed: a `static let` would freeze the four UUIDs, so two displays
    /// would share slot IDs and per-row `@State` would leak across screen swaps.
    public static var defaultSlots: [ScheduleSlot] {
        [
            ScheduleSlot(startHour: 6, endHour: 12, label: "Morning"),
            ScheduleSlot(startHour: 12, endHour: 18, label: "Afternoon"),
            ScheduleSlot(startHour: 18, endHour: 22, label: "Evening"),
            ScheduleSlot(startHour: 22, endHour: 6, label: "Night"),
        ]
    }

    public func containsMinute(_ minute: Int) -> Bool {
        if startMinute <= endMinute {
            minute >= startMinute && minute < endMinute
        } else {
            minute >= startMinute || minute < endMinute
        }
    }

    /// `HH:mm`; 1440 reads as `24:00`.
    public static func clockText(minute: Int) -> String {
        String(format: "%02d:%02d", minute / 60, minute % 60)
    }

    /// `compact` drops `:00` only when both ends are on the hour.
    public func rangeText(compact: Bool = false) -> String {
        let end = endMinute == 0 ? 1440 : endMinute
        if compact, startMinute % 60 == 0, end % 60 == 0 {
            return String(format: "%02d–%02d", startMinute / 60, end / 60)
        }
        return "\(Self.clockText(minute: startMinute))–\(Self.clockText(minute: end))"
    }

    public var localizedLabel: String {
        switch label {
        case "Morning":
            return String(localized: "Morning", defaultValue: "Morning", bundle: .appLanguage, comment: "Default schedule slot name.")
        case "Midday":
            return String(localized: "Midday", defaultValue: "Midday", bundle: .appLanguage, comment: "Default schedule slot name.")
        case "Afternoon":
            return String(localized: "Afternoon", defaultValue: "Afternoon", bundle: .appLanguage, comment: "Default schedule slot name.")
        case "Evening":
            return String(localized: "Evening", defaultValue: "Evening", bundle: .appLanguage, comment: "Default schedule slot name.")
        case "Night":
            return String(localized: "Night", defaultValue: "Night", bundle: .appLanguage, comment: "Default schedule slot name.")
        default:
            return label
        }
    }
}
