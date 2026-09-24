import Foundation
import LiveWallpaperCore

enum SchedulePolicy {
    enum Decision: Equatable {
        case none
        case applyWallpaper(WallpaperQueueEntry)
        case applySlot(slot: ScheduleSlot, bookmarkData: Data)
        case restorePrimary(bookmarkData: Data)
    }

    static func activeSlot(in slots: [ScheduleSlot], hour: Int) -> ScheduleSlot? {
        let normalizedHour = ((hour % 24) + 24) % 24
        return slots.first { $0.containsHour(normalizedHour) }
    }

    static func decision(for configuration: ScreenConfiguration, hour: Int) -> Decision {
        guard configuration.wallpaperMode == .schedule,
              let slots = configuration.scheduleSlots, !slots.isEmpty else {
            return .none
        }

        if usesEntries(configuration) {
            guard let entry = plannedEntry(for: configuration, hour: hour) else { return .none }
            let proposed = configuration.applyingAutomationEntry(entry)
            return proposed.activeWallpaper == configuration.activeWallpaper && proposed.wpeOrigin == configuration.wpeOrigin
                ? .none : .applyWallpaper(entry)
        }

        let activeBookmark = configuration.activeWallpaper.activeVideoBookmarkData

        if let slot = activeSlot(in: slots, hour: hour),
           let bookmark = slot.videoBookmarkData {
            if activeBookmark == bookmark {
                return .none
            }
            return .applySlot(slot: slot, bookmarkData: bookmark)
        }

        if let activeBookmark,
           slots.contains(where: { $0.videoBookmarkData == activeBookmark }),
           let primary = configuration.savedVideoBookmarkData,
           activeBookmark != primary {
            return .restorePrimary(bookmarkData: primary)
        }

        return .none
    }

    /// The entry the plan wants on screen at `hour`; nil when the plan leaves that hour alone.
    static func plannedEntry(for configuration: ScreenConfiguration, hour: Int) -> WallpaperQueueEntry? {
        guard let slots = configuration.scheduleSlots else { return nil }
        let active = activeSlot(in: slots, hour: hour)
        let slotVideo = active?.videoBookmarkData.map {
            WallpaperQueueEntry(title: active?.label ?? "", content: .video(bookmarkData: $0))
        }
        guard usesEntries(configuration) else { return slotVideo }
        return active?.wallpaper ?? slotVideo ?? configuration.scheduleFallback
    }

    private static func usesEntries(_ configuration: ScreenConfiguration) -> Bool {
        configuration.scheduleSlots?.contains { $0.wallpaper != nil } == true || configuration.scheduleFallback != nil
    }

    static func initialFallback(for configuration: ScreenConfiguration, current: WallpaperQueueEntry) -> WallpaperQueueEntry {
        let legacyPrimary = configuration.wallpaperMode == .schedule && configuration.wallpaperQueue == nil
            ? configuration.savedVideoBookmarkData : nil
        return legacyPrimary.map {
            WallpaperQueueEntry(title: "", content: .video(bookmarkData: $0, packageEntryName: configuration.savedVideoPackageEntryName))
        } ?? current
    }

    // MARK: - Manual override

    /// Next hour at which the planned content can change: any slot edge, or midnight when no slot has a length.
    static func nextBoundary(after now: Date, slots: [ScheduleSlot], calendar: Calendar) -> Date {
        var hours = Set(slots.filter { !hourRanges(for: $0).isEmpty }.flatMap { [clampHour($0.startHour), clampHour($0.endHour)] })
        if hours.isEmpty {
            hours = [0]
        }
        return hours.compactMap {
            calendar.nextDate(after: now, matching: DateComponents(hour: $0, minute: 0, second: 0), matchingPolicy: .nextTime)
        }.min() ?? now.addingTimeInterval(24 * 60 * 60)
    }

    static func isSameContent(_ lhs: WallpaperContent, _ rhs: WallpaperContent) -> Bool {
        switch (lhs, rhs) {
        case let (.video(lhsData, lhsEntry), .video(rhsData, rhsEntry)):
            lhsData == rhsData && lhsEntry == rhsEntry
        case let (.html(lhsSource, _), .html(rhsSource, _)):
            lhsSource == rhsSource
        case let (.scene(lhsScene), .scene(rhsScene)):
            lhsScene.isSameScene(as: rhsScene)
        default:
            false
        }
    }

    /// When the plan takes the display back; nil while it shows what the plan wants, or no plan applies.
    static func pausedUntil(for configuration: ScreenConfiguration, now: Date, calendar: Calendar) -> Date? {
        guard configuration.wallpaperMode == .schedule,
              let until = configuration.scheduleSettledUntil, now < until,
              let entry = plannedEntry(for: configuration, hour: calendar.component(.hour, from: now)),
              !isSameContent(entry.content, configuration.activeWallpaper) else { return nil }
        return until
    }

    /// Copies an edit of the showing wallpaper into the plan entry it came from, so the next run of that slot keeps it.
    static func writingBack(
        _ edited: WallpaperContent,
        into configuration: ScreenConfiguration,
        now: Date,
        calendar: Calendar
    ) -> ScreenConfiguration {
        let hour = calendar.component(.hour, from: now)
        guard configuration.wallpaperMode == .schedule,
              var slots = configuration.scheduleSlots,
              let entry = plannedEntry(for: configuration, hour: hour),
              isSameContent(entry.content, edited),
              entry.content != edited else { return configuration }
        var result = configuration
        if let index = slots.firstIndex(where: { $0.containsHour(hour) }), slots[index].wallpaper != nil {
            slots[index].wallpaper?.content = edited
            result.scheduleSlots = slots
        } else {
            result.scheduleFallback?.content = edited
        }
        return result
    }

    /// Run on every save: a content change claims a slot the scheduler has not settled yet; a stale same-content copy cannot reopen a settled one.
    static func holdingManualChange(
        _ configuration: ScreenConfiguration,
        previous: ScreenConfiguration?,
        now: Date,
        calendar: Calendar
    ) -> ScreenConfiguration {
        guard configuration.wallpaperMode == .schedule,
              let slots = configuration.scheduleSlots, !slots.isEmpty,
              (configuration.scheduleSettledUntil ?? .distantPast) <= now else { return configuration }
        var held = configuration
        if let previous, isSameContent(previous.activeWallpaper, configuration.activeWallpaper) {
            // A committed web or scene candidate is saved again with only a refreshed bookmark, still carrying the pre-claim stamp.
            if let settled = previous.scheduleSettledUntil, settled > now {
                held.scheduleSettledUntil = settled
            }
        } else {
            held.scheduleSettledUntil = nextBoundary(after: now, slots: slots, calendar: calendar)
        }
        return held
    }

    // MARK: - Conflict Detection

    enum SlotProblem: Equatable {
        case noLength(UUID)
        case overlap(UUID, UUID)
    }

    static func firstProblem(in slots: [ScheduleSlot]) -> SlotProblem? {
        for slot in slots {
            if hourRanges(for: slot).isEmpty {
                return .noLength(slot.id)
            }
            let overlapping = conflicts(slot: slot, against: slots)
            if let other = slots.first(where: { overlapping.contains($0.id) }) {
                return .overlap(slot.id, other.id)
            }
        }
        return nil
    }

    static func conflicts(slot: ScheduleSlot, against others: [ScheduleSlot]) -> Set<UUID> {
        let ours = hourRanges(for: slot)
        guard !ours.isEmpty else { return [] }

        var conflicting: Set<UUID> = []
        for other in others where other.id != slot.id {
            let theirs = hourRanges(for: other)
            outer: for ourRange in ours {
                for theirRange in theirs where ourRange.overlaps(theirRange) {
                    conflicting.insert(other.id)
                    break outer
                }
            }
        }
        return conflicting
    }

    /// Decompose a slot into `[start, end)` half-open ranges within 0-24.
    static func hourRanges(for slot: ScheduleSlot) -> [Range<Int>] {
        let s = clampHour(slot.startHour)
        let e = slot.endHour == 24 ? 24 : clampHour(slot.endHour)
        if s == e {
            return []
        }
        if s < e {
            return [s ..< e]
        }
        return [s ..< 24, 0 ..< e]
    }

    /// Finds the longest free range; an end above 24 represents a midnight wrap.
    static func findFreeRange(in slots: [ScheduleSlot], minHours: Int = 2) -> (start: Int, end: Int)? {
        var occupied = Array(repeating: false, count: 24)
        for slot in slots {
            for range in hourRanges(for: slot) {
                for h in range where h >= 0 && h < 24 {
                    occupied[h] = true
                }
            }
        }

        if !occupied.contains(true) {
            return minHours <= 24 ? (0, 24) : nil
        }
        if !occupied.contains(false) {
            return nil
        }

        var runs: [(start: Int, end: Int)] = []
        var index = 0
        while index < 24 {
            guard !occupied[index] else { index += 1; continue }
            let runStart = index
            while index < 24, !occupied[index] { index += 1 }
            runs.append((runStart, index))
        }

        // Stitch a leading 0-anchored run with a trailing 24-anchored run into a
        // single wrap-around range so the gap `23 → 1` is discoverable.
        if runs.count >= 2,
           let first = runs.first, first.start == 0,
           let last = runs.last, last.end == 24 {
            let leadingLength = first.end - first.start
            let trailingLength = last.end - last.start
            let wrap = (start: last.start, end: last.start + trailingLength + leadingLength)
            runs.removeFirst()
            runs.removeLast()
            runs.append(wrap)
        }

        var best: (start: Int, end: Int)?
        for run in runs {
            let length = run.end - run.start
            if length < minHours { continue }
            if let currentBest = best {
                if length > (currentBest.end - currentBest.start) {
                    best = run
                }
            } else {
                best = run
            }
        }
        return best
    }

    private static func clampHour(_ hour: Int) -> Int {
        ((hour % 24) + 24) % 24
    }
}
