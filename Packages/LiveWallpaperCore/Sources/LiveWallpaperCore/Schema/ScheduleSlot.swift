import Foundation

public struct ScheduleSlot: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var startHour: Int
    public var endHour: Int
    public var videoBookmarkData: Data?
    public var label: String
    public var wallpaper: WallpaperQueueEntry?

    public init(
        id: UUID = UUID(),
        startHour: Int,
        endHour: Int,
        videoBookmarkData: Data? = nil,
        label: String,
        wallpaper: WallpaperQueueEntry? = nil
    ) {
        self.id = id
        self.startHour = startHour
        self.endHour = endHour
        self.videoBookmarkData = videoBookmarkData
        self.label = label
        self.wallpaper = wallpaper
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

    public func containsHour(_ hour: Int) -> Bool {
        if startHour <= endHour {
            return hour >= startHour && hour < endHour
        } else {
            return hour >= startHour || hour < endHour
        }
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
