#if !LITE_BUILD
import AppKit
import LiveWallpaperCore
import SwiftUI

/// `Equatable` so unrelated parent state cannot re-run this body — the parent
/// hands every card a fresh `onSelect` each pass and a closure never compares
/// equal. Ignoring them in `==` is safe: they read `@State` through its box.
struct BrowseCard: View, Equatable {
    nonisolated static func == (lhs: BrowseCard, rhs: BrowseCard) -> Bool {
        lhs.item == rhs.item
            && lhs.isInLibrary == rhs.isInLibrary
            && lhs.hasUpdate == rhs.hasUpdate
            && lhs.inUseBadge == rhs.inUseBadge
            && lhs.isSelected == rhs.isSelected
            && lhs.cardPreferences == rhs.cardPreferences
            && lhs.reduceMotion == rhs.reduceMotion
            && lhs.canDownload == rhs.canDownload
            && lhs.isRevealed == rhs.isRevealed
            && lhs.isBookmarked == rhs.isBookmarked
    }

    let item: WorkshopQueryItem
    var isInLibrary: Bool = false
    /// Installed, and Steam's copy changed after it was imported.
    var hasUpdate: Bool = false
    /// The displays the installed project is set on; nil when none.
    var inUseBadge: NowPlayingBadge?
    var isSelected: Bool = false
    /// Read once per pane and handed down, not six `@AppStorage` per tile — see `GalleryCardPreferences`.
    /// Passed in, not read from the environment: `EquatableView` short-circuits `body`,
    /// so an environment value read inside it would go stale.
    let cardPreferences: GalleryCardPreferences
    let reduceMotion: Bool
    /// SteamCMD readiness, resolved once per pane pass. Deliberately a plain `Bool`,
    /// not a read of `WorkshopDownloadCoordinator`: observing it here would tie every
    /// visible card to the progress ticks of whichever download is running.
    var canDownload: Bool = false
    /// Whether the host's `MatureRevealState` has uncovered this item.
    var isRevealed: Bool = false
    /// nil keeps the reveal in this card's own `@State`.
    var onReveal: (() -> Void)?
    /// Liked, in `WorkshopBookmarkStore`.
    var isBookmarked: Bool = false
    /// nil hides every like affordance.
    var onBookmark: (() -> Void)?
    var onSelect: () -> Void = {}
    var onDownload: () -> Void = {}

    @State private var isHovered = false
    /// Ephemeral by design — recreated tiles (paging, filter change, relaunch) blur again.
    @State private var matureRevealed = false
    @State private var showingAgeConfirm = false
    @Environment(\.openURL) private var openURL

    private var shouldBlur: Bool {
        cardPreferences.blursMatureThumbnails && item.isMatureRated && !matureRevealed && !isRevealed
    }

    private var showsInUseBadge: Bool {
        inUseBadge != nil && cardPreferences.showsInUse && !shouldBlur
    }

    private var showsUpdateBadge: Bool {
        hasUpdate && cardPreferences.showsUpdate && !shouldBlur
    }

    private var showsEditDeskInLibraryCheck: Bool {
        isInLibrary && cardPreferences.showsInLibrary && !shouldBlur && !showsUpdateBadge
    }

    var body: some View {
        Button(action: { if shouldBlur { requestReveal() } else { onSelect() } }) {
            thumbnailArea
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .galleryTileChrome(isHovering: isHovered, isSelected: isSelected, cornerRadius: DesignTokens.EditDesk.Corner.panel, reduceMotion: reduceMotion)
        .overlay { editDeskBorder }
        .shadow(color: Self.ringShadow.color, radius: Self.ringShadow.radius, y: Self.ringShadow.y)
        .shadow(color: Self.restShadow.color, radius: Self.restShadow.radius, y: Self.restShadow.y)
        .shadow(color: editDeskShadow?.color ?? .clear, radius: editDeskShadow?.radius ?? 0, y: editDeskShadow?.y ?? 0)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .settledHover { isHovered = $0 }
        .settledHelp(Text(verbatim: item.title), isHovering: isHovered)
        .wpeTranslateWallpaperName(item.title)
        .contextMenu { contextMenuItems }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityLabelText))
        .accessibilityHint(shouldBlur
            ? Text("Mature content hidden. Activate to reveal.")
            : Text("Show details"))
        .accessibilityActions {
            if let onBookmark {
                Button(isBookmarked ? "Unlike" : "Like") {
                    guard isBookmarked || !item.isBanned else { return }
                    onBookmark()
                }
            }
        }
        .accessibilityAction(named: Text("Download")) {
            guard canDownload, !item.isBanned else { return }
            onDownload()
        }
        .accessibilityAction(named: Text("Open in Steam")) {
            guard !item.isBanned else { return }
            openURL(item.steamCommunityURL)
        }
        .accessibilityAction(named: Text("Copy link")) { copy(item.steamCommunityURL.absoluteString) }
        .accessibilityAction(named: Text("Copy ID")) { copy(String(item.id)) }
        .alert("Show mature content?", isPresented: $showingAgeConfirm) {
            Button(role: .cancel) {} label: { Text("Cancel") }
            Button(role: .destructive) {
                MatureContentSettings.confirm()
                markRevealed()
            } label: {
                Text("I am 18 or older")
            }
        } message: {
            Text("This wallpaper is tagged Mature and may contain explicit adult content. By revealing it you confirm you are at least 18 years old, or of legal age in your region.")
        }
    }

    private func requestReveal() {
        if MatureContentSettings.isConfirmed {
            markRevealed()
        } else {
            showingAgeConfirm = true
        }
    }

    private func markRevealed() {
        if let onReveal {
            onReveal()
        } else {
            matureRevealed = true
        }
    }

    // MARK: - S8 chrome

    private var editDeskBorder: some View {
        RoundedRectangle(cornerRadius: DesignTokens.EditDesk.Corner.panel, style: .continuous)
            .strokeBorder(DesignTokens.EditDesk.Colors.strokeRegular, lineWidth: 1)
            .allowsHitTesting(false)
    }

    /// SCREENS S8's card shadow is two layers: a 1px ring against the page and the drop below it.
    private static let ringShadow = DesignTokens.EditDesk.Shadow.workshopCardRing
    private static let restShadow = DesignTokens.EditDesk.Shadow.workshopCard

    private var editDeskShadow: DesignTokens.EditDesk.Shadow? {
        isHovered ? .hoverCard : nil
    }

    // MARK: - Thumbnail

    /// Every badge is an `overlay`, never a ZStack sibling: a badge ending in `fixedSize()`
    /// would set an intrinsic width that `aspectRatio(1, .fit)` cannot shrink, and the tile would stretch out of square.
    private var thumbnailArea: some View {
        WorkshopCardPreview {
            AnimatedGIFThumbnail(
                url: item.previewImageURL,
                playbackMode: .hoverToPlay,
                showsPlayingBadge: false,
                isBlurred: shouldBlur,
                isHovered: $isHovered
            )
        }
        .overlay(alignment: .topLeading) {
            topBadgeRow
        }
        .overlay(alignment: .bottom) {
            if !shouldBlur {
                editDeskInfoBand
            }
        }
        .thumbnailBadgeSurface(.opaque)
    }

    // MARK: - Footer

    /// SCREENS S8: the title over subscribers and size, on a gradient that fades into the picture.
    private var editDeskInfoBand: some View {
        let subscribers = subscriberText
        let size = formattedSize
        return VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
            // One line at rest; hover opens a second and scrolls whatever still overflows.
            MarqueeText(item.title.translatedWallpaperName, lineLimit: isHovered ? 2 : 1, isActive: isHovered)
                .font(DesignTokens.EditDesk.Typography.workshopCardTitle)
                .foregroundStyle(DesignTokens.Colors.overlayForeground)
            if subscribers != nil || size != nil {
                EditDeskStatsRow(subscribers: subscribers, size: size)
            }
        }
        .padding(.horizontal, DesignTokens.EditDesk.Spacing.workshopCardBandInset)
        .padding(.bottom, DesignTokens.EditDesk.Spacing.workshopCardBandInset)
        .padding(.top, DesignTokens.EditDesk.Spacing.workshopCardBandTop)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .bottom) {
            LinearGradient(
                colors: [.clear, DesignTokens.EditDesk.Colors.gradientWorkshopCardBottom],
                startPoint: .top, endPoint: .bottom
            )
        }
        .allowsHitTesting(false)
    }

    private var editDeskMarks: (rating: String?, resolution: String?) {
        Self.editDeskMarks(
            rating: ratingValue,
            resolution: cardPreferences.showsResolution ? resolutionLabel : nil,
            preferences: cardPreferences
        )
    }

    /// The rating and the resolution the top row badges; nil where there is none or its switch is off.
    nonisolated static func editDeskMarks(
        rating: Double?, resolution: String?, preferences: GalleryCardPreferences
    ) -> (rating: String?, resolution: String?) {
        (
            rating.flatMap { preferences.showsRating ? "★ " + $0.formatted(.number.precision(.fractionLength(1))) : nil },
            preferences.showsResolution ? resolution : nil
        )
    }

    private var editDeskStatus: EditDeskTopRow.Status? {
        if showsUpdateBadge {
            return .needsUpdate
        }
        if showsEditDeskInLibraryCheck {
            return .inLibrary
        }
        return nil
    }

    /// The heart stays up on a blurred card too. Derive the visible row once,
    /// so testing for its presence does not repeat tag parsing and formatting.
    @ViewBuilder
    private var topBadgeRow: some View {
        let marks: (rating: String?, resolution: String?) = shouldBlur ? (nil, nil) : editDeskMarks
        let inUse = showsInUseBadge ? inUseBadge : nil
        let status = editDeskStatus
        let like = likeMark
        if like != nil || inUse != nil || marks.rating != nil || marks.resolution != nil || status != nil {
            EditDeskTopRow(inUseBadge: inUse, rating: marks.rating, resolution: marks.resolution, status: status, like: like)
                .padding(DesignTokens.Spacing.sm)
        }
    }

    /// Always up once liked; offered on hover otherwise, except on a banned item, which cannot be liked.
    private var likeMark: EditDeskTopRow.Like? {
        guard let onBookmark, isBookmarked || (isHovered && !item.isBanned) else { return nil }
        return EditDeskTopRow.Like(isLiked: isBookmarked, toggle: onBookmark)
    }

    fileprivate static func editDeskMetaText(_ text: String) -> some View {
        Text(verbatim: text)
            .font(DesignTokens.EditDesk.Typography.badgeMono)
            .foregroundStyle(DesignTokens.Colors.overlayForeground.opacity(DesignTokens.Opacity.dimmedIcon))
            .lineLimit(1)
    }

    // MARK: - Context menu

    @ViewBuilder
    private var contextMenuItems: some View {
        if let onBookmark {
            Button(action: onBookmark) {
                Label(isBookmarked ? "Unlike" : "Like",
                      systemImage: isBookmarked ? "heart.fill" : "heart")
            }
            .disabled(item.isBanned && !isBookmarked)

        }

        Button(action: onDownload) {
            Label("Download", systemImage: "arrow.down.circle")
        }
        .disabled(!canDownload || item.isBanned)


        Button {
            openURL(item.steamCommunityURL)
        } label: {
            Label("Open in Steam", systemImage: "arrow.up.forward.app")
        }
        .disabled(item.isBanned)
    }

    // MARK: - Derived values

    private var ratingValue: Double? {
        guard let stars = item.rating?.starsOutOfFive, stars > 0 else { return nil }
        return stars
    }

    private var resolutionLabel: String? {
        Self.resolutionShortLabel(for: item.tags)
    }

    static func resolutionShortLabel(for tags: [String]) -> String? {
        for tag in tags {
            if let mapped = knownResolutionLabels[tag] { return mapped }
        }
        for tag in tags {
            if let derived = deriveResolutionLabel(from: tag) { return derived }
        }
        return nil
    }

    /// Keyed by Steam's real Resolution tags. Layout buckets name their badge;
    /// single-screen buckets derive it from the numbers; Other/Dynamic has none.
    static let knownResolutionLabels: [String: String] = {
        var labels: [String: String] = [:]
        for filter in WorkshopResolutionFilter.allCases {
            for tag in filter.tags {
                switch filter {
                case .any, .other: break
                case .standardDefinition: labels[tag] = "SD"
                case .ultrawide: labels[tag] = "UW"
                case .dual: labels[tag] = "Dual"
                case .triple: labels[tag] = "Triple"
                case .portrait: labels[tag] = "Portrait"
                case .hd, .quadHD1440, .ultraHD4K: labels[tag] = deriveResolutionLabel(from: tag)
                }
            }
        }
        return labels
    }()

    /// Covers prefixes like "Dual 3840 x 1080".
    private static func deriveResolutionLabel(from tag: String) -> String? {
        guard tag.range(of: #"\d+\s*[xX×]\s*\d+"#, options: .regularExpression) != nil else { return nil }
        let nums = tag.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard nums.count >= 2 else { return nil }
        return VideoFormatInfo.resolutionShortLabel(
            width: nums[nums.count - 2],
            height: nums[nums.count - 1]
        )
    }

    private var subscriberText: String? {
        guard let subs = item.subscriptionCount, subs > 0 else { return nil }
        return subs < WorkshopCountFormatter.compactFloor
            ? String(localized: "\(subs) subs", bundle: .appLanguage, locale: AppLanguagePreference.current.locale, comment: "Workshop item subscriber count.")
            : String(localized: "\(WorkshopCountFormatter.compact(subs)) subs", bundle: .appLanguage, locale: AppLanguagePreference.current.locale, comment: "Workshop card subscriber count. Placeholder is an abbreviated number such as 1.2K.")
    }

    private var formattedSize: String? {
        guard let bytes = item.fileSizeBytes else { return nil }
        // `fileSizeBytes` is `UInt64`; clamp before the `Int64` formatter to
        // avoid a trap on a pathological value.
        return WorkshopByteFormatter.megabytesAndUp.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))))
    }

    private var statusText: String? {
        if item.isBanned {
            return String(localized: "Unavailable", bundle: .appLanguage, comment: "Workshop item removed or hidden on Steam.")
        }
        switch item.visibility {
        case .friendsOnly:
            return String(localized: "Friends-only", bundle: .appLanguage, comment: "Workshop item visibility.")
        case .private:
            return String(localized: "Private", bundle: .appLanguage, comment: "Workshop item visibility.")
        case .public, .unknown:
            return nil
        @unknown default:
            return String(localized: "Restricted", bundle: .appLanguage, comment: "Workshop item visibility.")
        }
    }

    var accessibilityLabelText: String {
        var parts: [String] = [item.title.translatedWallpaperName]
        if let type = item.tags.first(where: { ["scene", "video", "web", "preset"].contains($0.lowercased()) }) {
            parts.append(WorkshopTagLocalization.displayName(type))
        }
        // The card reads what its band and top row draw, and a blurred card draws neither.
        let showsMeta = !shouldBlur
        if let rating = ratingValue, showsMeta, cardPreferences.showsRating {
            parts.append(String(localized: "\(rating.formatted(.number.precision(.fractionLength(1)))) stars", bundle: .appLanguage, comment: "Workshop card VoiceOver rating. Placeholder is a number 0–5."))
        }
        if let resolutionLabel, showsMeta, cardPreferences.showsResolution {
            parts.append(resolutionLabel)
        }
        if let subscriberText, showsMeta {
            parts.append(subscriberText)
        }
        if let size = formattedSize, showsMeta {
            parts.append(size)
        }
        if isBookmarked {
            parts.append(String(localized: "Liked", bundle: .appLanguage, comment: "Workshop card VoiceOver: the item is liked."))
        }
        if showsEditDeskInLibraryCheck {
            parts.append(String(localized: "In Library", bundle: .appLanguage, comment: "Workshop card VoiceOver: item is already downloaded to the local library."))
        }
        if showsInUseBadge {
            parts.append(String(localized: "Currently in use", bundle: .appLanguage, comment: "A11y: this wallpaper is the active one."))
        }
        if showsUpdateBadge {
            parts.append(String(localized: "Update available", bundle: .appLanguage, comment: "A11y: the installed item has a newer version on Steam."))
        }
        if let statusText {
            parts.append(statusText)
        }
        return parts.joined(separator: ", ")
    }

    private func copy(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }
}

/// The grid chooses a square before proposing any size to the image. A tall
/// source or a wide GIF frame cannot enlarge the card's layout bounds.
struct WorkshopCardPreview<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                GeometryReader { geometry in
                    content
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                }
            }
    }
}

/// The Edit Desk card's top edge as one row, so its two ends see each other: the status marks keep the outer
/// ends, and the resolution badge, then the update badge's caption, then the rating, give way before two badges overlap.
private struct EditDeskTopRow: View {
    enum Status {
        case needsUpdate, inLibrary
    }

    struct Like {
        let isLiked: Bool
        let toggle: () -> Void
    }

    let inUseBadge: NowPlayingBadge?
    let rating: String?
    let resolution: String?
    let status: Status?
    /// nil draws no heart.
    let like: Like?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(showsResolution: true, updateCaption: true, showsRating: true)
            row(showsResolution: false, updateCaption: true, showsRating: true)
            row(showsResolution: false, updateCaption: false, showsRating: true)
            // Taken even when too wide: the capsule then truncates its display names rather than slide under a badge.
            row(showsResolution: false, updateCaption: false, showsRating: false)
        }
    }

    private func row(showsResolution: Bool, updateCaption: Bool, showsRating: Bool) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: DesignTokens.Spacing.xs) {
                if let inUseBadge {
                    // The pane rebuilds these on configuration changes only, so it cannot tell playing from paused.
                    NowPlayingCapsule(badge: inUseBadge, animates: false)
                }
                if showsRating, let rating {
                    ThumbnailBadge(verbatim: rating)
                }
            }
            Spacer(minLength: DesignTokens.Spacing.xs)
            HStack(spacing: DesignTokens.Spacing.xs) {
                if showsResolution, let resolution {
                    ThumbnailBadge(verbatim: resolution)
                }
                switch status {
                case .needsUpdate:
                    if updateCaption {
                        ThumbnailBadge("Needs Update", systemImage: "arrow.down.circle", tint: DesignTokens.Colors.Status.warning, opacity: 0.9)
                    } else {
                        ThumbnailBadge(systemImage: "arrow.down.circle", tint: DesignTokens.Colors.Status.warning, opacity: 0.9)
                    }
                case .inLibrary:
                    ThumbnailPresenceCheck(
                        tint: DesignTokens.EditDesk.Colors.inLibraryBadgeFill,
                        appearance: .solid(glyph: DesignTokens.EditDesk.Colors.inLibraryBadgeGlyph)
                    )
                case nil:
                    EmptyView()
                }
                if let like {
                    TileMarkBadge(mark: .like, isOn: like.isLiked, action: like.toggle)
                }
            }
        }
    }
}

/// The band's second row: subscribers at the leading end, size at the trailing end. The size gives way when
/// both do not fit, so the count is never the part cut short.
private struct EditDeskStatsRow: View {
    let subscribers: String?
    let size: String?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                if let subscribers {
                    BrowseCard.editDeskMetaText(subscribers)
                }
                Spacer(minLength: DesignTokens.Spacing.sm)
                if let size {
                    BrowseCard.editDeskMetaText(size)
                }
            }
            if let subscribers {
                BrowseCard.editDeskMetaText(subscribers)
            }
        }
    }
}
#endif
