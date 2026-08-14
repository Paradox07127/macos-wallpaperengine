import SwiftUI
import AVFoundation
import LiveWallpaperCore

struct AerialThumbnailCacheKey: Hashable {
    private let path: String
    private let fileSize: Int64

    init(asset: AerialAsset) {
        path = asset.url.standardizedFileURL.path
        fileSize = asset.fileSize ?? -1
    }
}

private struct AerialThumbnailCacheEntry {
    let thumbnail: NSImage?
    let formatInfo: VideoFormatInfo?
}

@MainActor
private final class AerialThumbnailCache {
    static let shared = AerialThumbnailCache()

    /// Sized for 4K monitors with large Aerials libraries (200+) where a
    /// smaller window thrashes the decode pipeline on scroll.
    private let capacity = 128
    private var entries: [AerialThumbnailCacheKey: AerialThumbnailCacheEntry] = [:]
    private var recency: [AerialThumbnailCacheKey] = []

    func entry(for key: AerialThumbnailCacheKey) -> AerialThumbnailCacheEntry? {
        guard let entry = entries[key] else { return nil }
        touch(key)
        return entry
    }

    func insert(_ entry: AerialThumbnailCacheEntry, for key: AerialThumbnailCacheKey) {
        entries[key] = entry
        touch(key)
        trim()
    }

    private func touch(_ key: AerialThumbnailCacheKey) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }

    private func trim() {
        while recency.count > capacity {
            entries.removeValue(forKey: recency.removeFirst())
        }
    }
}

/// Aerials are managed by macOS, so there is no rename / delete affordance and
/// tapping the tile is a no-op.
struct AerialThumbnailCard: View {
    let asset: AerialAsset
    let screens: [Screen]
    let onApply: (Screen) -> Void
    let onApplyToAll: () -> Void

    @State private var isHovering = false
    @State private var thumbnail: NSImage?
    @State private var formatInfo: VideoFormatInfo?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            thumbnailTile
            metadata
                .padding(DesignTokens.Spacing.md)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .galleryTileChrome(isHovering: isHovering, reduceMotion: reduceMotion)
        .onHover { hovering in
            guard !screens.isEmpty else { return }
            isHovering = hovering
        }
        .contextMenu { contextMenu }
        .task { await loadThumbnailIfNeeded() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityActions {
            if screens.count == 1, let only = screens.first {
                Button("Apply") { onApply(only) }
            } else if screens.count > 1 {
                ForEach(screens, id: \.id) { screen in
                    Button("Apply to \(screen.name)") { onApply(screen) }
                }
                Button("Apply to All Displays", action: onApplyToAll)
            }
        }
    }

    // MARK: Thumbnail tile

    /// The poster is an `overlay`, not a ZStack sibling: `scaledToFill` reports the
    /// *scaled* size, so as a sibling it made the tile grow to the poster's aspect
    /// ratio and bleed into the neighbouring grid column (posters are only 16:9
    /// when the source video is). An overlay never resizes its base, so the tile
    /// is 16:9 for every asset; `clipped()` then hides the overflowing poster,
    /// which would otherwise paint over the footer.
    private var thumbnailTile: some View {
        tileBackground
            .overlay { tileContent }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .clipped()
            .overlay(alignment: .topTrailing) {
                formatBadgeRow
                    .padding(DesignTokens.Spacing.sm)
            }
    }

    private var tileBackground: some View {
        Rectangle().fill(Color.accentColor.opacity(0.12))
    }

    @ViewBuilder
    private var tileContent: some View {
        if let thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .interpolation(.high)
                .scaledToFill()
        } else {
            Image(systemName: "sparkles.tv")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Color.accentColor.opacity(0.85))
        }
    }

    @ViewBuilder
    private var formatBadgeRow: some View {
        if let badges = formatInfo?.badges, !badges.isEmpty {
            AdaptiveGlassContainer(spacing: DesignTokens.Spacing.xs) {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    ForEach(badges, id: \.self) { badge in
                        ThumbnailBadge(verbatim: badge.displayLabel)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(verbatim: badges.map(\.displayLabel).joined(separator: ", ")))
        }
    }

    // MARK: Metadata

    private var metadata: some View {
        HStack(alignment: .center, spacing: DesignTokens.Spacing.sm) {
            textBlock
            Spacer(minLength: DesignTokens.Spacing.xs)
            applyControl
        }
    }

    private var textBlock: some View {
        VStack(alignment: .leading, spacing: 1) {
            MarqueeText(asset.displayName, lineLimit: 1, isActive: isHovering)
                .font(DesignTokens.Typography.bodyEmphasized)
                .foregroundStyle(.primary)

            // Reserved even when the asset has no category: a row of cards with
            // mixed one- and two-line footers gets vertically centred by
            // LazyVGrid, which knocks the thumbnails out of alignment.
            Text(verbatim: asset.category ?? "")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1, reservesSpace: true)
                .truncationMode(.middle)
        }
    }

    private var applyControl: some View {
        LibraryTileApplyControl(
            screens: screens,
            tint: .accentColor,
            onApply: onApply,
            onApplyToAll: onApplyToAll
        )
    }

    // MARK: Context menu

    @ViewBuilder
    private var contextMenu: some View {
        if !screens.isEmpty {
            ForEach(screens, id: \.id) { screen in
                Button("Apply to \(screen.name)") { onApply(screen) }
            }
            if screens.count > 1 {
                Divider()
                Button("Apply to All Displays", action: onApplyToAll)
            }
        }
    }

    // MARK: Accessibility

    private var accessibilityText: Text {
        if let category = asset.category, !category.isEmpty {
            return Text("Aerial: \(asset.displayName), \(category)", comment: "Aerial thumbnail a11y label. Placeholders are aerial display name and category.")
        }
        return Text("Aerial: \(asset.displayName)", comment: "Aerial thumbnail a11y label. The placeholder is the aerial display name.")
    }

    // MARK: Thumbnail loader

    @MainActor
    private func loadThumbnailIfNeeded() async {
        guard thumbnail == nil else { return }

        let cacheKey = AerialThumbnailCacheKey(asset: asset)
        if let cached = AerialThumbnailCache.shared.entry(for: cacheKey) {
            thumbnail = cached.thumbnail
            formatInfo = cached.formatInfo
            if cached.thumbnail != nil { return }
        }

        let bookmarkData = asset.bookmarkData
        let resolved: URL? = await Task.detached { () -> URL? in
            try? SecurityScopedBookmarkResolver.shared
                .resolve(bookmarkData, target: .transient).get().url
        }.value

        guard let url = resolved else { return }

        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }

        var loadedFormatInfo = formatInfo
        if let info = try? await PlayableVideoLoader.detectFormat(at: url) {
            guard !Task.isCancelled else { return }
            loadedFormatInfo = info
            formatInfo = info
        }

        let avAsset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: avAsset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 270)

        do {
            let image = try await generator.image(at: .zero).image
            guard !Task.isCancelled else { return }
            let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            thumbnail = nsImage
            AerialThumbnailCache.shared.insert(
                AerialThumbnailCacheEntry(thumbnail: nsImage, formatInfo: loadedFormatInfo),
                for: cacheKey
            )
        } catch {
            if loadedFormatInfo != nil {
                AerialThumbnailCache.shared.insert(
                    AerialThumbnailCacheEntry(thumbnail: nil, formatInfo: loadedFormatInfo),
                    for: cacheKey
                )
            }
        }
    }
}
