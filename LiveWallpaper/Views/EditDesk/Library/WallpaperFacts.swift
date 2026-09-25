import CoreGraphics
import Foundation
import LiveWallpaperCore

/// Builds the detail modal's rows. Pure: the item, the clock and the locale come in, sorted
/// localized rows go out, so the library and the Workshop modal list the same things the same way.
@MainActor
enum WallpaperFacts {
    /// The rows the library knows about `item` itself. `typeName` overrides the kind's own name;
    /// `sizeBytes` is its size on disk, nil when unknown.
    static func library(
        _ item: LibraryItem, typeName: String? = nil, sizeBytes: Int64?, now: Date, locale: Locale
    ) -> [WallpaperFact] {
        var facts = [WallpaperFact(kind: .type, value: typeName ?? item.kind.localizedName)]
        if let sizeBytes, sizeBytes > 0 {
            facts.append(WallpaperFact(kind: .size, value: WorkshopByteFormatter.kilobytesAndUp.string(fromByteCount: sizeBytes)))
        }
        if case let .video(video)? = item.metadata {
            if let size = video.resolution {
                facts.append(WallpaperFact(kind: .resolution, value: resolutionText(size, isHDR: video.isHDR)))
            }
            if let duration = video.duration, duration > 0 {
                facts.append(WallpaperFact(kind: .duration, value: durationText(duration)))
            }
        }
        // An aerial's type already says where it comes from.
        if item.kind != .aerial {
            let source = item.isSteam
                ? String(localized: "Steam Workshop", bundle: .appLanguage, comment: "Installed library origin filter: items with a real Steam Workshop ID.")
                : String(localized: "Local", bundle: .appLanguage)
            facts.append(WallpaperFact(kind: .source, value: source))
        }
        // `.distantPast` is the library's "never recorded", which an aerial always is.
        if item.createdAt != .distantPast {
            facts.append(WallpaperFact(
                kind: .imported, value: dateText(item.createdAt, locale: locale),
                help: relativeText(item.createdAt, now: now, locale: locale)
            ))
        }
        if let lastUsed = item.lastUsedAt {
            facts.append(WallpaperFact(
                kind: .lastUsed, value: relativeText(lastUsed, now: now, locale: locale),
                help: dateText(lastUsed, locale: locale)
            ))
        }
        return facts.sorted { $0.kind < $1.kind }
    }

    /// Each kind once: `primary`'s row wins, then the first of `secondary`'s for the kinds `primary` lacks.
    static func merged(_ primary: [WallpaperFact], _ secondary: [WallpaperFact]) -> [WallpaperFact] {
        var present = Set(primary.map(\.kind))
        var facts = primary
        for fact in secondary where present.insert(fact.kind).inserted {
            facts.append(fact)
        }
        return facts.sorted { $0.kind < $1.kind }
    }

    static func dateText(_ date: Date, locale: Locale) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(locale))
    }

    /// "Just now" under a minute, where the formatter would say "in 0 seconds".
    static func relativeText(_ date: Date, now: Date, locale: Locale) -> String {
        guard now.timeIntervalSince(date) >= 60 else {
            return String(localized: "Just now", bundle: .appLanguage)
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// `0:32`, `1:02:05`: digits only, the same in every language.
    static func durationText(_ seconds: TimeInterval) -> String {
        let duration = Duration.seconds(seconds.rounded())
        return seconds >= 3600
            ? duration.formatted(.time(pattern: .hourMinuteSecond))
            : duration.formatted(.time(pattern: .minuteSecond))
    }

    /// `3840 × 2160`, with ` · HDR` for an HDR video; verbatim, like the format badges.
    static func resolutionText(_ size: CGSize, isHDR: Bool) -> String {
        let text = "\(Int(size.width)) × \(Int(size.height))"
        return isHDR ? text + " · HDR" : text
    }
}

#if !LITE_BUILD
extension WallpaperFacts {
    /// The rows Steam knows about a Workshop item. Its type, age rating and resolution tags are rows here;
    /// `chips(_:)` takes the rest.
    static func steam(_ item: WorkshopQueryItem, now: Date, locale: Locale) -> [WallpaperFact] {
        var facts = tagFacts(item.tags)
        if let author = item.creatorPersonaName, !author.isEmpty {
            facts.append(WallpaperFact(kind: .author, value: author))
        }
        if let rating = item.rating, rating.starsOutOfFive > 0, rating.totalVotes > 0 {
            let score = rating.starsOutOfFive.formatted(.number.precision(.fractionLength(1)).locale(locale))
            let votes = String(
                localized: "\(rating.totalVotes) ratings", bundle: .appLanguage, locale: AppLanguagePreference.current.locale,
                comment: "Workshop detail rating count. Placeholder is the number of ratings."
            )
            facts.append(WallpaperFact(kind: .rating, value: "\(score) · \(votes)", help: voteSplitText(rating)))
        }
        if let size = item.fileSizeBytes, size > 0 {
            facts.append(WallpaperFact(
                kind: .size, value: WorkshopByteFormatter.kilobytesAndUp.string(fromByteCount: Int64(clamping: size))
            ))
        }
        let stats = statsText(item)
        if !stats.isEmpty {
            facts.append(WallpaperFact(kind: .stats, value: stats))
        }
        if let posted = item.timeCreated {
            facts.append(WallpaperFact(
                kind: .posted, value: dateText(posted, locale: locale), help: relativeText(posted, now: now, locale: locale)
            ))
        }
        if let updated = item.timeUpdated, item.timeCreated.map({ !Calendar.current.isDate($0, inSameDayAs: updated) }) ?? true {
            facts.append(WallpaperFact(
                kind: .updated, value: dateText(updated, locale: locale), help: relativeText(updated, now: now, locale: locale)
            ))
        }
        return facts.sorted { $0.kind < $1.kind }
    }

    /// The type, age rating and resolution rows a tag list implies; the other tags are `chips(_:)`.
    static func tagFacts(_ tags: [String]) -> [WallpaperFact] {
        var facts: [WallpaperFact] = []
        for grouped in WorkshopTagTaxonomy.grouped(tags: tags) {
            switch grouped.group {
            case .type:
                facts.append(WallpaperFact(kind: .type, value: grouped.tags.map(WorkshopTagLocalization.displayName).joined(separator: " / ")))
            case .ageRating:
                facts.append(WallpaperFact(kind: .ageRating, value: grouped.tags.map(WorkshopTagLocalization.displayName).joined(separator: " / ")))
            case .resolution:
                facts.append(WallpaperFact(kind: .resolution, value: grouped.tags.map(resolutionTagText).joined(separator: " / ")))
            case .genre, .category, .miscellaneous, .other:
                break
            }
        }
        return facts
    }

    /// Genre, then miscellaneous, other and a category other than Wallpaper, each label once.
    static func chips(_ tags: [String]) -> [WallpaperTagChip] {
        let groups = WorkshopTagTaxonomy.grouped(tags: tags)
        var chips: [WallpaperTagChip] = []
        for group in [WorkshopTagTaxonomy.Group.genre, .miscellaneous, .other, .category] {
            let members = groups.first { $0.group == group }?.tags ?? []
            for tag in members where group != .category || tag.caseInsensitiveCompare("Wallpaper") != .orderedSame {
                let label = WorkshopTagLocalization.displayName(tag)
                if !chips.contains(where: { $0.label == label }) {
                    chips.append(WallpaperTagChip(raw: tag, label: label))
                }
            }
        }
        return chips
    }

    /// The up and down votes behind a score; a star rating carries none.
    private static func voteSplitText(_ rating: WorkshopRating) -> String? {
        guard case let .score(_, up, down) = rating else { return nil }
        return String(localized: "\(up.formatted()) up, \(down.formatted()) down", bundle: .appLanguage)
    }

    /// Steam's resolution tags spell the size `3840 x 2160`; the modal writes it the way its own rows do.
    private static func resolutionTagText(_ tag: String) -> String {
        WorkshopTagLocalization.displayName(tag).replacingOccurrences(of: " x ", with: " × ")
    }

    private static func statsText(_ item: WorkshopQueryItem) -> String {
        var parts: [String] = []
        if let subscribers = item.subscriptionCount, subscribers > 0 {
            parts.append(subscribersText(subscribers))
        }
        if let favorites = item.favoriteCount, favorites > 0 {
            parts.append(favorites < WorkshopCountFormatter.compactFloor
                ? String(localized: "\(favorites) favorites", bundle: .appLanguage, locale: AppLanguagePreference.current.locale, comment: "Workshop item favorite count below 1,000.")
                : String(localized: "\(WorkshopCountFormatter.compact(favorites)) favorites", bundle: .appLanguage, locale: AppLanguagePreference.current.locale, comment: "Workshop item favorite count. Placeholder is a compact number such as 6.1K."))
        }
        if let views = item.viewCount, views > 0 {
            parts.append(views < WorkshopCountFormatter.compactFloor
                ? String(localized: "\(views) views", bundle: .appLanguage, locale: AppLanguagePreference.current.locale, comment: "Workshop item view count below 1,000.")
                : String(localized: "\(WorkshopCountFormatter.compact(views)) views", bundle: .appLanguage, locale: AppLanguagePreference.current.locale, comment: "Workshop item view count. Placeholder is a compact number such as 6.1K."))
        }
        return parts.joined(separator: " · ")
    }

    private static func subscribersText(_ count: Int) -> String {
        if count >= WorkshopCountFormatter.compactFloor {
            return String(
                localized: "\(WorkshopCountFormatter.compact(count)) subs", bundle: .appLanguage,
                locale: AppLanguagePreference.current.locale,
                comment: "Workshop card subscriber count. Placeholder is an abbreviated number such as 1.2K."
            )
        }
        return String(localized: "\(count) subs", bundle: .appLanguage, locale: AppLanguagePreference.current.locale, comment: "Workshop item subscriber count.")
    }
}

extension WallpaperModalContent {
    /// Steam fills the rows the library cannot know. The library keeps what describes this copy:
    /// its type, size, duration, source and dates. Steam's tags replace the manifest's when it has any.
    @MainActor
    mutating func mergeSteam(_ item: WorkshopQueryItem, now: Date, locale: Locale) {
        let localFirst: Set<WallpaperFact.Kind> = [.type, .size, .duration, .source, .imported, .lastUsed]
        let steam = WallpaperFacts.steam(item, now: now, locale: locale)
        let local = facts.filter { localFirst.contains($0.kind) }
        let steamFirst = steam.filter { !localFirst.contains($0.kind) }
        facts = WallpaperFacts.merged(WallpaperFacts.merged(local, steamFirst), facts + steam)
        let chips = WallpaperFacts.chips(item.tags)
        if !chips.isEmpty {
            tags = chips
        }
    }
}
#endif
