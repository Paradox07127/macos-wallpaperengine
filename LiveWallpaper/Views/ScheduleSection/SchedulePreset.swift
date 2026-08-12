import Foundation
import SwiftUI
import LiveWallpaperCore

/// Time-of-day presets for the Add Slot menu.
enum SchedulePreset: String, Identifiable, CaseIterable {
    case morning
    case midday
    case afternoon
    case evening
    case night

    var id: String { rawValue }

    /// `endHour` exclusive; night wraps midnight (`containsHour` semantics).
    var hours: (start: Int, end: Int) {
        switch self {
        case .morning:   return (6, 12)
        case .midday:    return (11, 14)
        case .afternoon: return (12, 18)
        case .evening:   return (18, 22)
        case .night:     return (22, 6)
        }
    }

    /// English key for `ScheduleSlot.label` (localized at display via `localizedLabel`).
    var labelKey: String {
        switch self {
        case .morning:   return "Morning"
        case .midday:    return "Midday"
        case .afternoon: return "Afternoon"
        case .evening:   return "Evening"
        case .night:     return "Night"
        }
    }

    var localized: String {
        switch self {
        case .morning:
            return String(localized: "Morning", defaultValue: "Morning", comment: "Default schedule slot name.")
        case .midday:
            return String(localized: "Midday", defaultValue: "Midday", comment: "Default schedule slot name.")
        case .afternoon:
            return String(localized: "Afternoon", defaultValue: "Afternoon", comment: "Default schedule slot name.")
        case .evening:
            return String(localized: "Evening", defaultValue: "Evening", comment: "Default schedule slot name.")
        case .night:
            return String(localized: "Night", defaultValue: "Night", comment: "Default schedule slot name.")
        }
    }

    var systemImage: String {
        switch self {
        case .morning:   return "sun.horizon"
        case .midday:    return "sun.max"
        case .afternoon: return "sun.haze"
        case .evening:   return "moon.haze"
        case .night:     return "moon.stars"
        }
    }

    func conflicts(with existing: [ScheduleSlot]) -> Bool {
        let candidate = ScheduleSlot(startHour: hours.start, endHour: hours.end, label: labelKey)
        return !SchedulePolicy.conflicts(slot: candidate, against: existing).isEmpty
    }

    func makeSlot() -> ScheduleSlot {
        ScheduleSlot(startHour: hours.start, endHour: hours.end, label: labelKey)
    }

    static func suggestion(forStartHour hour: Int) -> SchedulePreset {
        switch hour {
        case 5..<11:  return .morning
        case 11..<14: return .midday
        case 14..<18: return .afternoon
        case 18..<22: return .evening
        default:      return .night
        }
    }
}

/// Locale-aware hour formatting for the schedule UI.
enum ScheduleTimeFormatter {
    static func hourLabel(_ hour: Int) -> String {
        let calendar = Calendar.autoupdatingCurrent
        var components = calendar.dateComponents([.year, .month, .day], from: Date())
        components.hour = ((hour % 24) + 24) % 24
        components.minute = 0
        guard let date = calendar.date(from: components) else { return "\(hour)" }
        return date.formatted(.dateTime.hour())
    }

    /// Appends `(next day)` when the range wraps midnight.
    static func rangeLabel(startHour: Int, endHour: Int) -> String {
        let start = hourLabel(startHour)
        let end = hourLabel(endHour)
        if startHour > endHour {
            let nextDay = String(
                localized: "next day",
                defaultValue: "next day",
                comment: "Suffix appended to a schedule end-time when the slot wraps past midnight."
            )
            return "\(start) — \(end) (\(nextDay))"
        }
        return "\(start) — \(end)"
    }

    /// Picker end-hour label; `(next day)` only when end would wrap past `start`.
    static func endHourMenuLabel(end: Int, start: Int) -> String {
        let base = hourLabel(end)
        if end <= start && start > 0 {
            let nextDay = String(
                localized: "next day",
                defaultValue: "next day",
                comment: "Suffix appended to a schedule end-time when the slot wraps past midnight."
            )
            return "\(base) (\(nextDay))"
        }
        return base
    }
}
