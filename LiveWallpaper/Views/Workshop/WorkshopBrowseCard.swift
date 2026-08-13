#if !LITE_BUILD
import AppKit
import LiveWallpaperCore
import SwiftUI

/// Grid card for the online browse view.
struct WorkshopBrowseCard: View {
    let item: WorkshopQueryItem
    var isInLibrary: Bool = false
    var isSelected: Bool = false
    var onSelect: () -> Void = {}

    @State private var isHovered = false
    /// Ephemeral by design — recreated tiles (paging, filter change, relaunch) blur again.
    @State private var matureRevealed = false
    @State private var showingAgeConfirm = false
    @AppStorage("loomscreen.workshop.blurMatureThumbnails.v1", store: .appScoped()) private var blurMatureThumbnails = true
    /// One-time 18+ confirmation, shared with the detail inspector via `@AppStorage`.
    @AppStorage("loomscreen.workshop.matureContentConfirmed.v1", store: .appScoped()) private var matureConfirmed = false
    @AppStorage(CardBadgeSettings.showsRating, store: .appScoped()) private var showsRatingBadge = true
    @AppStorage(CardBadgeSettings.showsType, store: .appScoped()) private var showsTypeBadge = true
    @AppStorage(CardBadgeSettings.showsResolution, store: .appScoped()) private var showsResolutionBadge = true
    @AppStorage(CardBadgeSettings.showsInLibrary, store: .appScoped()) private var showsInLibraryBadge = true
    @AppStorage(CardBadgeSettings.typeStyle, store: .appScoped()) private var typeBadgeStyle: CardTypeBadgeStyle = .icon
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shouldBlur: Bool {
        blurMatureThumbnails && item.isMatureRated && !matureRevealed
    }

    var body: some View {
        Button(action: { if shouldBlur { requestReveal() } else { onSelect() } }) {
            VStack(alignment: .leading, spacing: 0) {
                thumbnailArea
                textInfo
                    .padding(DesignTokens.Spacing.md)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .galleryTileChrome(isHovering: isHovered, isSelected: isSelected, cornerRadius: DesignTokens.Corner.lg, reduceMotion: reduceMotion)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .onHover { isHovered = $0 }
        .help(item.title)
        .contextMenu { contextMenuItems }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityLabelText))
        .accessibilityHint(shouldBlur
            ? Text("Mature content hidden. Activate to reveal.")
            : Text("Show details"))
        .accessibilityAction(named: Text("Open in Steam")) {
            guard !item.isBanned else { return }
            openURL(item.steamCommunityURL)
        }
        .accessibilityAction(named: Text("Copy link")) { copy(item.steamCommunityURL.absoluteString) }
        .accessibilityAction(named: Text("Copy ID")) { copy(String(item.id)) }
        .alert("Show mature content?", isPresented: $showingAgeConfirm) {
            Button(role: .cancel) {} label: { Text("Cancel") }
            Button(role: .destructive) {
                matureConfirmed = true
                matureRevealed = true
            } label: {
                Text("I am 18 or older")
            }
        } message: {
            Text("This wallpaper is tagged Mature and may contain explicit adult content. By revealing it you confirm you are at least 18 years old, or of legal age in your region.")
        }
    }

    /// Gated by a one-time 18+ confirmation (remembered across the app once accepted).
    private func requestReveal() {
        if matureConfirmed {
            matureRevealed = true
        } else {
            showingAgeConfirm = true
        }
    }

    // MARK: - Thumbnail

    /// Every badge is an `overlay`, never a ZStack sibling: `ThumbnailTypeBadge`
    /// ends in `fixedSize()`, so as a sibling the "Icon and name" style plus a
    /// rating pill would set an intrinsic width that `aspectRatio(1, .fit)`
    /// cannot shrink, and the tile would stretch out of square.
    private var thumbnailArea: some View {
        AnimatedGIFThumbnail(
            url: item.previewImageURL,
            playbackMode: .hoverToPlay,
            isBlurred: shouldBlur,
            isHovered: $isHovered
        )
        .overlay(alignment: .topLeading) {
            if !shouldBlur {
                AdaptiveGlassContainer(spacing: DesignTokens.Spacing.xs) {
                    HStack(spacing: DesignTokens.Spacing.xs) {
                        if let contentType, showsTypeBadge {
                            typePill(contentType)
                        }
                        if let rating = ratingValue, showsRatingBadge {
                            ratingPill(rating)
                        }
                    }
                }
                .padding(DesignTokens.Spacing.sm)
            }
        }
        .overlay(alignment: .topTrailing) {
            if let resolutionLabel, !shouldBlur, showsResolutionBadge {
                resolutionPill(resolutionLabel)
                    .padding(DesignTokens.Spacing.sm)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if isInLibrary, showsInLibraryBadge {
                inLibraryBadge
                    .padding(DesignTokens.Spacing.sm)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func resolutionPill(_ label: String) -> some View {
        ThumbnailBadge(verbatim: label)
    }

    private var inLibraryBadge: some View {
        ThumbnailBadge(
            "In Library",
            systemImage: "checkmark.circle.fill",
            tint: Self.inLibraryGreen,
            opacity: 0.85
        )
    }

    private func typePill(_ type: WorkshopContentTypeFilter) -> some View {
        ThumbnailTypeBadge(
            systemImage: Self.typeSymbol(for: type),
            title: type.displayName,
            style: typeBadgeStyle
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

    /// Title, plus the status badge on the rare restricted item. Type moved onto
    /// the thumbnail and the subscriber count is a detail-sheet fact, so the row
    /// that held them bought a line of card height for something nobody scans a
    /// grid for.
    private var textInfo: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            MarqueeText(item.title, isActive: isHovered)
                .font(DesignTokens.Typography.bodyEmphasized)
                .foregroundStyle(.primary)

            statusBadge
        }
    }

    /// Leading type glyph, matching the app's existing drag-preview iconography (`WorkshopInstalledView.dragIconName`) so Scene/Video/Web read the same everywhere.
    private static func typeSymbol(for type: WorkshopContentTypeFilter) -> String {
        switch type {
        case .scene: return "cube.transparent.fill"
        case .video: return "play.rectangle.fill"
        case .web: return "globe"
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        if let status = statusInfo {
            StatusChip(verbatim: status.text, tint: status.tint, systemImage: status.symbol)
        }
    }

    // MARK: - Context menu

    @ViewBuilder
    private var contextMenuItems: some View {
        Button {
            openURL(item.steamCommunityURL)
        } label: {
            Label("Open in Steam", systemImage: "arrow.up.forward.app")
        }
        .disabled(item.isBanned)

        Divider()

        Button {
            copy(item.steamCommunityURL.absoluteString)
        } label: {
            Label("Copy link", systemImage: "link")
        }
        Button {
            copy(String(item.id))
        } label: {
            Label("Copy ID", systemImage: "doc.on.doc")
        }
    }

    // MARK: - Derived values

    /// `voteScore` is 0...1; map to a 0...5 star value.
    private var ratingValue: Double? {
        guard let score = item.voteScore, score > 0 else { return nil }
        return min(max(score * 5, 0), 5)
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

    private static let knownResolutionLabels: [String: String] = [
        "Standard Definition": "SD",
        "1280 x 720": "720p",
        "1920 x 1080": "1080p",
        "2560 x 1440": "1440p",
        "3840 x 2160": "4K",
        "2560 x 1080": "UW",
        "3440 x 1440": "UW",
        "Dual 3840 x 1080": "Dual",
        "5120 x 1440": "Dual",
        "7680 x 2160": "Dual",
        "1080 x 1920": "Portrait",
        "720 x 1280": "Portrait",
        "1440 x 2560": "Portrait",
        "2160 x 3840": "Portrait"
    ]

    /// Derive a label from any embedded "W x H" tag (covers prefixes like "Dual 3840 x 1080").
    private static func deriveResolutionLabel(from tag: String) -> String? {
        guard tag.range(of: #"\d+\s*[xX×]\s*\d+"#, options: .regularExpression) != nil else { return nil }
        let nums = tag.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard nums.count >= 2 else { return nil }
        return VideoFormatInfo.resolutionShortLabel(
            width: nums[nums.count - 2],
            height: nums[nums.count - 1]
        )
    }

    private var formattedSize: String? {
        guard let bytes = item.fileSizeBytes else { return nil }
        // `fileSizeBytes` is `UInt64`; clamp before the `Int64` formatter to
        // avoid a trap on a pathological value.
        return Self.byteFormatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))))
    }

    /// Single source for the restricted/banned badge, reused by VoiceOver.
    private var statusInfo: (text: String, tint: Color, symbol: String)? {
        if item.isBanned {
            return (String(localized: "Unavailable", comment: "Workshop item removed or hidden on Steam."), DesignTokens.Colors.Status.danger, "xmark.octagon.fill")
        }
        switch item.visibility {
        case .friendsOnly:
            return (String(localized: "Friends-only", comment: "Workshop item visibility."), DesignTokens.Colors.Status.warning, "exclamationmark.triangle.fill")
        case .private:
            return (String(localized: "Private", comment: "Workshop item visibility."), DesignTokens.Colors.Status.warning, "exclamationmark.triangle.fill")
        case .public, .unknown:
            return nil
        @unknown default:
            return (String(localized: "Restricted", comment: "Workshop item visibility."), DesignTokens.Colors.Status.warning, "exclamationmark.triangle.fill")
        }
    }

    private var accessibilityLabelText: String {
        var parts: [String] = [item.title]
        if let rating = ratingValue {
            parts.append(String(localized: "\(rating.formatted(.number.precision(.fractionLength(1)))) stars", comment: "Workshop card VoiceOver rating. Placeholder is a number 0–5."))
        }
        if let type = contentType {
            parts.append(type.displayName)
        }
        if let resolutionLabel {
            parts.append(resolutionLabel)
        }
        if let subs = item.subscriptionCount, subs > 0 {
            parts.append(String(localized: "\(formatSubs(subs)) subscribers", comment: "Workshop card VoiceOver subscriber count."))
        }
        if let size = formattedSize {
            parts.append(size)
        }
        if isInLibrary {
            parts.append(String(localized: "In Library", comment: "Workshop card VoiceOver: item is already downloaded to the local library."))
        }
        if let status = statusInfo {
            parts.append(status.text)
        }
        return parts.joined(separator: ", ")
    }

    private func formatSubs(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", locale: .current, Double(count) / 1_000_000.0)
        }
        if count >= 1_000 {
            return String(format: "%.1fK", locale: .current, Double(count) / 1_000.0)
        }
        return count.formatted()
    }

    private func copy(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString(value, forType: .string)
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter
    }()
}
#endif
