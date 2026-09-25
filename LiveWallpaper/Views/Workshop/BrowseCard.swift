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
            && lhs.presentation == rhs.presentation
            && lhs.isRevealed == rhs.isRevealed
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
    var presentation: BrowsePresentation = .legacy
    /// Whether the host's `MatureRevealState` has uncovered this item.
    var isRevealed: Bool = false
    /// nil keeps the reveal in this card's own `@State`.
    var onReveal: (() -> Void)?
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

    private var showsTypePill: Bool {
        contentType != nil && cardPreferences.showsType
    }

    private var showsRatingPill: Bool {
        ratingValue != nil && cardPreferences.showsRating
    }

    private var showsInUseBadge: Bool {
        presentation == .editDesk && inUseBadge != nil && cardPreferences.showsInUse && !shouldBlur
    }

    private var showsUpdateBadge: Bool {
        presentation == .editDesk && hasUpdate && cardPreferences.showsUpdate && !shouldBlur
    }

    private var showsEditDeskInLibraryCheck: Bool {
        presentation == .editDesk && isInLibrary && cardPreferences.showsInLibrary && !shouldBlur && !showsUpdateBadge
    }

    var body: some View {
        Button(action: { if shouldBlur { requestReveal() } else { onSelect() } }) {
            thumbnailArea
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .galleryTileChrome(isHovering: isHovered, isSelected: isSelected, cornerRadius: cardCornerRadius, reduceMotion: reduceMotion)
        .overlay { editDeskBorder }
        .shadow(color: editDeskRingShadow?.color ?? .clear, radius: editDeskRingShadow?.radius ?? 0, y: editDeskRingShadow?.y ?? 0)
        .shadow(color: editDeskRestShadow?.color ?? .clear, radius: editDeskRestShadow?.radius ?? 0, y: editDeskRestShadow?.y ?? 0)
        .shadow(color: editDeskShadow?.color ?? .clear, radius: editDeskShadow?.radius ?? 0, y: editDeskShadow?.y ?? 0)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .settledHover { isHovered = $0 }
        .settledHelp(Text(verbatim: item.title), isHovering: isHovered)
        .contextMenu { contextMenuItems }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityLabelText))
        .accessibilityHint(shouldBlur
            ? Text("Mature content hidden. Activate to reveal.")
            : Text("Show details"))
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

    private var cardCornerRadius: CGFloat {
        presentation == .editDesk ? DesignTokens.EditDesk.Corner.panel : DesignTokens.Corner.lg
    }

    @ViewBuilder
    private var editDeskBorder: some View {
        if presentation == .editDesk {
            RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                .strokeBorder(DesignTokens.EditDesk.Colors.strokeRegular, lineWidth: 1)
                .allowsHitTesting(false)
        }
    }

    /// SCREENS S8's card shadow is two layers: a 1px ring against the page and the drop below it.
    private var editDeskRingShadow: DesignTokens.EditDesk.Shadow? {
        presentation == .editDesk ? .workshopCardRing : nil
    }

    private var editDeskRestShadow: DesignTokens.EditDesk.Shadow? {
        presentation == .editDesk ? .workshopCard : nil
    }

    private var editDeskShadow: DesignTokens.EditDesk.Shadow? {
        guard presentation == .editDesk, isHovered else { return nil }
        return .hoverCard
    }

    // MARK: - Thumbnail

    /// Every badge is an `overlay`, never a ZStack sibling: `ThumbnailTypeBadge`
    /// ends in `fixedSize()`, so as a sibling it would set an intrinsic width that
    /// `aspectRatio(1, .fit)` cannot shrink, and the tile would stretch out of square.
    private var thumbnailArea: some View {
        AnimatedGIFThumbnail(
            url: item.previewImageURL,
            playbackMode: .hoverToPlay,
            showsPlayingBadge: false,
            isBlurred: shouldBlur,
            isHovered: $isHovered
        )
        // Gated on the pills, not just the blur: inside the `if`s every card would still
        // build the glass container, its `HStack` and the padding around an empty stack.
        .overlay(alignment: .topLeading) {
            if presentation == .editDesk {
                if !shouldBlur, isHovered || showsInUseBadge {
                    HStack(spacing: DesignTokens.Spacing.xs) {
                        if let inUseBadge, showsInUseBadge {
                            // The pane rebuilds these on configuration changes only, so it cannot tell playing from paused.
                            NowPlayingCapsule(badge: inUseBadge, animates: false)
                        }
                        if isHovered {
                            ThumbnailBadge(verbatim: "GIF", systemImage: "play.fill")
                        }
                    }
                    .padding(DesignTokens.Spacing.sm)
                }
            } else if !shouldBlur, showsTypePill || showsRatingPill {
                AdaptiveGlassContainer(spacing: DesignTokens.Spacing.xs) {
                    HStack(spacing: DesignTokens.Spacing.xs) {
                        if let contentType, showsTypePill {
                            typePill(contentType)
                        }
                        if let rating = ratingValue, showsRatingPill {
                            ratingPill(rating)
                        }
                    }
                }
                .padding(DesignTokens.Spacing.sm)
            }
        }
        .overlay(alignment: .topTrailing) {
            if presentation == .editDesk {
                if showsUpdateBadge {
                    ThumbnailBadge("Needs Update", systemImage: "arrow.down.circle", tint: DesignTokens.Colors.Status.warning, opacity: 0.9)
                        .padding(DesignTokens.Spacing.sm)
                } else if showsEditDeskInLibraryCheck {
                    ThumbnailPresenceCheck(
                        tint: DesignTokens.EditDesk.Colors.inLibraryBadgeFill,
                        appearance: .solid(glyph: DesignTokens.EditDesk.Colors.inLibraryBadgeGlyph)
                    )
                    .padding(DesignTokens.Spacing.sm)
                }
            } else if let resolutionLabel, !shouldBlur, cardPreferences.showsResolution {
                ThumbnailBadge(verbatim: resolutionLabel)
                    .padding(DesignTokens.Spacing.sm)
            }
        }
        .overlay(alignment: .bottom) {
            if !shouldBlur {
                if presentation == .editDesk {
                    editDeskInfoBand
                } else {
                    titleBand
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func typePill(_ type: WorkshopContentTypeFilter) -> some View {
        ThumbnailTypeBadge(
            systemImage: Self.typeSymbol(for: type),
            title: type.displayName,
            style: cardPreferences.typeStyle
        )
    }

    private func ratingPill(_ rating: Double) -> some View {
        ThumbnailBadge(
            verbatim: rating.formatted(.number.precision(.fractionLength(1))),
            systemImage: "star.fill"
        )
    }

    private static let inLibraryGreen = DesignTokens.Colors.badgeActive

    // MARK: - Footer

    private var titleBand: some View {
        ThumbnailTitleBand(title: item.title, isHovering: isHovered) {
            if let status = statusInfo {
                Image(systemName: status.symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(status.tint)
                    .accessibilityHidden(true)
            }
        } trailing: {
            if isInLibrary, cardPreferences.showsInLibrary {
                ThumbnailPresenceCheck(tint: Self.inLibraryGreen)
            }
        }
    }

    /// SCREENS S8: title over one monospaced meta line, on a gradient that fades into the picture.
    private var editDeskInfoBand: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
            Text(verbatim: item.title)
                .font(DesignTokens.EditDesk.Typography.workshopCardTitle)
                .foregroundStyle(DesignTokens.Colors.overlayForeground)
                .lineLimit(1)
            if let editDeskMetaLine {
                Text(verbatim: editDeskMetaLine)
                    .font(DesignTokens.EditDesk.Typography.badgeMono)
                    .foregroundStyle(DesignTokens.Colors.overlayForeground.opacity(DesignTokens.Opacity.dimmedIcon))
                    .lineLimit(1)
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

    private var editDeskMetaLine: String? {
        Self.editDeskMetaLine(
            rating: ratingValue, resolution: resolutionLabel, subscribers: subscriberText, size: formattedSize,
            preferences: cardPreferences
        )
    }

    static func editDeskMetaLine(
        rating: Double?, resolution: String?, subscribers: String?, size: String?, preferences: GalleryCardPreferences
    ) -> String? {
        var parts: [String] = []
        if let rating, preferences.showsRating {
            parts.append("★ " + rating.formatted(.number.precision(.fractionLength(1))))
        }
        if let resolution, preferences.showsResolution {
            parts.append(resolution)
        }
        if let subscribers {
            parts.append(subscribers)
        }
        if let size {
            parts.append(size)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func typeSymbol(for type: WorkshopContentTypeFilter) -> String {
        switch type {
        case .scene: return "cube.transparent.fill"
        case .video: return "play.rectangle.fill"
        case .web: return "globe"
        }
    }

    // MARK: - Context menu

    @ViewBuilder
    private var contextMenuItems: some View {
        Button(action: onDownload) {
            Label("Download", systemImage: "arrow.down.circle")
        }
        .disabled(!canDownload || item.isBanned)

        Divider()

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

    private var contentType: WorkshopContentTypeFilter? {
        let lowered = Set(item.tags.map { $0.lowercased() })
        if lowered.contains("scene") { return .scene }
        if lowered.contains("video") { return .video }
        if lowered.contains("web") { return .web }
        return nil
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
        return String(localized: "\(WorkshopCountFormatter.compact(subs)) subscribers", bundle: .appLanguage, comment: "Workshop card VoiceOver subscriber count.")
    }

    private var formattedSize: String? {
        guard let bytes = item.fileSizeBytes else { return nil }
        // `fileSizeBytes` is `UInt64`; clamp before the `Int64` formatter to
        // avoid a trap on a pathological value.
        return WorkshopByteFormatter.megabytesAndUp.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))))
    }

    private var statusInfo: (text: String, tint: Color, symbol: String)? {
        if item.isBanned {
            return (String(localized: "Unavailable", bundle: .appLanguage, comment: "Workshop item removed or hidden on Steam."), DesignTokens.Colors.Status.danger, "xmark.octagon.fill")
        }
        switch item.visibility {
        case .friendsOnly:
            return (String(localized: "Friends-only", bundle: .appLanguage, comment: "Workshop item visibility."), DesignTokens.Colors.Status.warning, "exclamationmark.triangle.fill")
        case .private:
            return (String(localized: "Private", bundle: .appLanguage, comment: "Workshop item visibility."), DesignTokens.Colors.Status.warning, "exclamationmark.triangle.fill")
        case .public, .unknown:
            return nil
        @unknown default:
            return (String(localized: "Restricted", bundle: .appLanguage, comment: "Workshop item visibility."), DesignTokens.Colors.Status.warning, "exclamationmark.triangle.fill")
        }
    }

    var accessibilityLabelText: String {
        var parts: [String] = [item.title]
        // The Edit Desk card reads what `editDeskInfoBand` draws, and a blurred card draws no band.
        let showsMeta = presentation != .editDesk || !shouldBlur
        if let rating = ratingValue, showsMeta, presentation != .editDesk || cardPreferences.showsRating {
            parts.append(String(localized: "\(rating.formatted(.number.precision(.fractionLength(1)))) stars", bundle: .appLanguage, comment: "Workshop card VoiceOver rating. Placeholder is a number 0–5."))
        }
        if let type = contentType, presentation != .editDesk {
            parts.append(type.displayName)
        }
        if let resolutionLabel, showsMeta, presentation != .editDesk || cardPreferences.showsResolution {
            parts.append(resolutionLabel)
        }
        if let subscriberText, showsMeta {
            parts.append(subscriberText)
        }
        if let size = formattedSize, showsMeta {
            parts.append(size)
        }
        if presentation == .editDesk ? showsEditDeskInLibraryCheck : isInLibrary {
            parts.append(String(localized: "In Library", bundle: .appLanguage, comment: "Workshop card VoiceOver: item is already downloaded to the local library."))
        }
        if showsInUseBadge {
            parts.append(String(localized: "Currently in use", bundle: .appLanguage, comment: "A11y: this wallpaper is the active one."))
        }
        if showsUpdateBadge {
            parts.append(String(localized: "Update available", bundle: .appLanguage, comment: "A11y: the installed item has a newer version on Steam."))
        }
        if let status = statusInfo {
            parts.append(status.text)
        }
        return parts.joined(separator: ", ")
    }

    private func copy(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }
}
#endif
