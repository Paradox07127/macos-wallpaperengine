#if !LITE_BUILD
import LiveWallpaperCore
import SwiftUI

/// The online inspector's masthead: title, author, rating, and the facts about
/// the file.
///
/// The column is resizable from `Inspector.minWidth` and the sheet insets it by
/// `Spacing.lg` on each side, so every row here has 236pt at its narrowest.
/// That budget, not the Workshop page's, decides the layout: rating and author
/// shared a row until they needed 380pt (409pt in Japanese) and truncated each
/// other, and the popularity counts spelled out their nouns until Spanish and
/// Japanese ran past the edge. Rows are one fact deep now, the counts are icons
/// that wrap, and what got cut is on the tooltip rather than gone.
/// `WorkshopInspectorHeaderFitTests` measures all five languages against 236pt.
struct WorkshopDetailIdentityHeader: View {
    let item: WorkshopQueryItem
    /// The keyless creator page ignores the browse filters and states no page
    /// count, so without a key the author link is Steam's to show, not ours.
    let isKeyless: Bool
    /// nil disables the author link (plain author text).
    var onBrowseCreator: ((String, String?) -> Void)?

    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                Text(item.title)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                authorLine
            }
            ratingRow
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                factsRow
                dateLine
            }
            .font(DesignTokens.Typography.caption)
            .foregroundStyle(.secondary)
            statusBadge
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Author

    @ViewBuilder
    private var authorLine: some View {
        if let author = item.creatorPersonaName, !author.isEmpty {
            if let creatorID = item.creatorID, isKeyless {
                authorButton(author, trailingSymbol: "arrow.up.right.square") {
                    openURL(WorkshopCommunityURL.creatorWorkshop(steamID: creatorID))
                }
                .help(Text("Open \(author)’s Workshop on Steam"))
                .accessibilityLabel(Text("Open \(author)’s Workshop on Steam"))
            } else if let creatorID = item.creatorID, let onBrowseCreator {
                authorButton(author, trailingSymbol: "chevron.right") {
                    onBrowseCreator(creatorID, author)
                }
                .help(Text("Show more wallpapers from \(author)"))
                .accessibilityLabel(Text("Show more wallpapers from \(author)"))
            } else {
                Text("by \(author)", comment: "Workshop item author line. Placeholder is the creator's Steam persona name.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func authorButton(
        _ author: String,
        trailingSymbol: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text("by \(author)", comment: "Workshop item author line. Placeholder is the creator's Steam persona name.")
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: trailingSymbol)
                    .font(DesignTokens.Typography.captionEmphasized)
            }
            .font(.subheadline)
            .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Rating

    /// Stars when rated, always the vote count (the page's `numRatings`). The
    /// up/down split is a tooltip: it costs 100pt of a 236pt row to say what
    /// the stars and the count already say.
    private var ratingRow: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            if let stars = item.rating?.starsOutOfFive, stars > 0 {
                HStack(spacing: 1) {
                    ForEach(0 ..< 5, id: \.self) { index in
                        Image(systemName: Self.starSymbol(for: index, rating: stars))
                            .foregroundStyle(DesignTokens.Colors.rating)
                            .font(.system(size: 12))
                    }
                }
                .accessibilityLabel(Text("\(stars.formatted(.number.precision(.fractionLength(1)))) stars"))
                Text(verbatim: stars.formatted(.number.precision(.fractionLength(1))))
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(.secondary)
            }
            Text(verbatim: ratingCountText)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .modifier(OptionalHelp(text: voteSplitText))
    }

    /// The up/down split, where the keyed path supplies it.
    private var voteSplitText: Text? {
        guard case let .score(_, up, down) = item.rating else { return nil }
        return Text("\(up.formatted()) up, \(down.formatted()) down")
    }

    /// What the rating line says about votes. The key-free details endpoint
    /// carries no vote data at all; that is not an item nobody has rated.
    enum RatingCountLabel: Equatable {
        case unavailable
        case none
        case count(Int)
    }

    nonisolated static func ratingCountLabel(_ rating: WorkshopRating?) -> RatingCountLabel {
        guard let rating else { return .unavailable }
        return rating.totalVotes > 0 ? .count(rating.totalVotes) : .none
    }

    private var ratingCountText: String {
        switch Self.ratingCountLabel(item.rating) {
        case .unavailable:
            String(localized: "Rating unavailable", bundle: .appLanguage, comment: "Workshop detail rating line when the source carries no vote data at all (key-free details endpoint).")
        case .none:
            String(localized: "No ratings yet", bundle: .appLanguage, comment: "Workshop detail rating line when the item has no votes.")
        case let .count(votes):
            String(localized: "\(votes.formatted()) ratings", bundle: .appLanguage, comment: "Workshop detail rating count. Placeholder is a formatted number such as 3,094.")
        }
    }

    private static func starSymbol(for index: Int, rating: Double) -> String {
        let position = Double(index)
        if rating >= position + 1 {
            return "star.fill"
        }
        if rating >= position + 0.5 {
            return "star.leadinghalf.filled"
        }
        return "star"
    }

    // MARK: - Facts

    /// Size first: it is the one number that can stop a download, and it used
    /// to trail a date line long enough to truncate it. Each fact is an atom
    /// the flow can move to the next line whole, and the noun that a wider
    /// column would spell out lives on the tooltip.
    @ViewBuilder
    private var factsRow: some View {
        let visible = facts
        if !visible.isEmpty {
            WorkshopChipFlow(spacing: DesignTokens.Spacing.sm, lineSpacing: 2) {
                ForEach(visible, id: \.symbol) { fact in
                    HStack(spacing: 3) {
                        Image(systemName: fact.symbol)
                            .font(.system(size: 10))
                        Text(verbatim: fact.value)
                    }
                    .fixedSize()
                    .help(Text(verbatim: fact.spelledOut))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: fact.spelledOut))
                }
            }
        }
    }

    private struct Fact {
        let symbol: String
        let value: String
        /// Spoken and hovered: the value with the noun the row drops. Not
        /// `description` — `i18n_guard` reads that name as an interpolated
        /// `CustomStringConvertible` leaking into accessibility copy.
        let spelledOut: String
    }

    /// `heart`, not `star`, for favorites: the rating row directly above is
    /// already a line of stars.
    private var facts: [Fact] {
        var facts: [Fact] = []
        if let size = item.fileSizeBytes, size > 0 {
            let value = WorkshopByteFormatter.megabytesAndUp.string(fromByteCount: Int64(clamping: size))
            facts.append(Fact(
                symbol: "internaldrive",
                value: value,
                spelledOut: String(localized: "Download size: \(value)", bundle: .appLanguage, comment: "Workshop detail size tooltip and VoiceOver label. Placeholder is a formatted file size such as 168 MB.")
            ))
        }
        if let subs = item.subscriptionCount, subs > 0 {
            facts.append(Fact(symbol: "person.2", value: WorkshopCountFormatter.compact(subs), spelledOut: formatSubs(subs)))
        }
        if let favorites = item.favoriteCount, favorites > 0 {
            facts.append(Fact(
                symbol: "heart",
                value: WorkshopCountFormatter.compact(favorites),
                spelledOut: String(localized: "\(WorkshopCountFormatter.compact(favorites)) favorites", bundle: .appLanguage, comment: "Workshop item favorite count. Placeholder is a compact number such as 6.1K.")
            ))
        }
        if let views = item.viewCount, views > 0 {
            facts.append(Fact(
                symbol: "eye",
                value: WorkshopCountFormatter.compact(views),
                spelledOut: String(localized: "\(WorkshopCountFormatter.compact(views)) views", bundle: .appLanguage, comment: "Workshop item view count. Placeholder is a compact number such as 6.1K.")
            ))
        }
        return facts
    }

    // MARK: - Dates

    /// One line, not two: when a wallpaper was last touched is what anyone
    /// reads here, and the other date is on the tooltip.
    @ViewBuilder
    private var dateLine: some View {
        if let updated = item.timeUpdated {
            Text("Updated \(Self.dateFormatter.string(from: updated)) (\(WorkshopRelativeDateFormatter.string(updated)))")
                .lineLimit(1)
                .modifier(OptionalHelp(text: postedText))
        } else if let posted = postedText {
            posted.lineLimit(1)
        }
    }

    private var postedText: Text? {
        guard let posted = item.timeCreated else { return nil }
        return Text("Posted \(Self.dateFormatter.string(from: posted)) (\(WorkshopRelativeDateFormatter.string(posted)))")
    }

    @ViewBuilder
    private var statusBadge: some View {
        if item.isBanned {
            Label("Unavailable — removed or hidden on Steam", systemImage: "xmark.octagon.fill")
                .font(DesignTokens.Typography.captionEmphasized)
                .foregroundStyle(DesignTokens.Colors.Status.danger)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Helpers

    private func formatSubs(_ count: Int) -> String {
        // The magnitude suffix is formatted first so the catalog key stays a plain
        // "%@M subs" — a %.1f inside a localized key would fight per-locale decimals.
        if count >= 1_000_000 {
            let scaled = String(format: "%.1f", locale: .current, Double(count) / 1_000_000.0)
            return String(localized: "\(scaled)M subs", bundle: .appLanguage, comment: "Workshop item subscriber count, millions.")
        }
        if count >= 1000 {
            let scaled = String(format: "%.1f", locale: .current, Double(count) / 1000.0)
            return String(localized: "\(scaled)K subs", bundle: .appLanguage, comment: "Workshop item subscriber count, thousands.")
        }
        return String(localized: "\(count) subs", bundle: .appLanguage, comment: "Workshop item subscriber count.")
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}

/// `.help(_:)` takes a `Text`, not an optional; this keeps the tooltip off the
/// view entirely when there is nothing to say.
private struct OptionalHelp: ViewModifier {
    let text: Text?

    func body(content: Content) -> some View {
        if let text {
            content.help(text)
        } else {
            content
        }
    }
}
#endif
