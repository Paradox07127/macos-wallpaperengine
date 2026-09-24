import AppKit
import AVFoundation
import LiveWallpaperCore
import SwiftUI

struct AerialThumbnailCacheKey: Hashable {
    private let path: String
    private let fileSize: Int64

    var previewKey: String {
        "aerial::\(path)::\(fileSize)"
    }

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

struct ThumbnailCard: View {
    let asset: AerialAsset
    let screens: [Screen]
    let onApply: (Screen) -> Void
    let onApplyToAll: () -> Void

    @State private var isHovering = false
    @State private var thumbnail: NSImage?
    @State private var formatInfo: VideoFormatInfo?
    @State private var location = LibraryContentLocation.unknown
    @State private var showingTargets = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        thumbnailTile
            .frame(maxWidth: .infinity, alignment: .leading)
            .galleryTileChrome(isHovering: isHovering, reduceMotion: reduceMotion)
            .settledHover { hovering in
                guard !screens.isEmpty else { return }
                isHovering = hovering
            }
            .appLanguagePopover(isPresented: $showingTargets, arrowEdge: .bottom) {
                LibraryApplyTargetList(
                    screens: screens,
                    onApply: onApply,
                    onApplyToAll: onApplyToAll,
                    dismiss: { showingTargets = false }
                )
            }
            .help(location.isAvailable ? Text("Apply") : Text("This wallpaper's file is missing"))
            .contextMenu { contextMenu }
            .tileTask(id: AerialThumbnailCacheKey(asset: asset)) {
                thumbnail = nil
                formatInfo = nil
                await loadTileContent()
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityText)
            .accessibilityActions {
                // Same gate as the tap and the context menu.
                if !location.isAvailable {
                    EmptyView()
                } else if screens.count == 1, let only = screens.first {
                    Button("Apply") { onApply(only) }
                } else if screens.count > 1 {
                    ForEach(screens, id: \.id) { screen in
                        Button("Apply to \(screen.name)") { onApply(screen) }
                    }
                    Button("Apply to All Displays", action: onApplyToAll)
                }
            }
    }

    private func applyFromCard() {
        guard location.isAvailable else { return }
        if screens.count == 1, let only = screens.first {
            onApply(only)
        } else if screens.count > 1 {
            showingTargets = true
        }
    }

    // MARK: Thumbnail tile

    /// Must stay an `overlay`, not a ZStack sibling: `scaledToFill` reports the scaled
    /// size, so as a sibling it would grow the tile past 16:9 into the next grid column.
    private var thumbnailTile: some View {
        tileBackground
            .overlay { tileContent }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .clipped()
            .contentShape(Rectangle())
            .onTapGesture { applyFromCard() }
            .overlay {
                if !location.isAvailable {
                    LibraryTileUnavailableVeil()
                }
            }
            .overlay(alignment: .topTrailing) {
                formatBadgeRow
                    .padding(DesignTokens.Spacing.sm)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottom) {
                ThumbnailTitleBand(title: asset.displayName, isHovering: isHovering) {
                    overflowButton
                }
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

    /// Only appears when there is something to offer: an aerial has no rename or
    /// delete, so a grant that no longer resolves leaves the menu empty.
    @ViewBuilder
    private var overflowButton: some View {
        if let revealURL = location.revealURL {
            LibraryTileOverflowButton { dismiss in
                Button("Show in Finder") {
                    dismiss()
                    NSWorkspace.shared.activateFileViewerSelecting([revealURL])
                }
            }
        }
    }

    // MARK: Context menu

    @ViewBuilder
    private var contextMenu: some View {
        if !screens.isEmpty, location.isAvailable {
            ForEach(screens, id: \.id) { screen in
                Button("Apply to \(screen.name)") { onApply(screen) }
            }
            if screens.count > 1 {
                Divider()
                Button("Apply to All Displays", action: onApplyToAll)
            }
        }
        if let revealURL = location.revealURL {
            Divider()
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([revealURL])
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
    private func loadTileContent() async {
        // Resolved before the artwork: Show in Finder and the unavailable veil
        // both read it, and neither should wait on a decode.
        let resolvedLocation = await LibraryContentLocator.locate(
            content: .video(bookmarkData: asset.bookmarkData),
            wpeOrigin: nil
        )
        guard !Task.isCancelled else { return }
        location = resolvedLocation
        await loadThumbnailIfNeeded()
    }

    @MainActor
    private func loadThumbnailIfNeeded() async {
        guard thumbnail == nil else { return }

        let cacheKey = AerialThumbnailCacheKey(asset: asset)
        if let cached = AerialThumbnailCache.shared.entry(for: cacheKey) {
            thumbnail = cached.thumbnail
            formatInfo = cached.formatInfo
            if cached.thumbnail != nil {
                return
            }
        }

        guard let resolved = await LibraryContentLocator.resolvePreviewBookmark(asset.bookmarkData),
              !Task.isCancelled else { return }
        let url = resolved.url

        let didStart = url.startAccessingSecurityScopedResource()
        defer {
            if didStart {
                url.stopAccessingSecurityScopedResource()
            }
        }

        var loadedFormatInfo = formatInfo
        if let info = await WallpaperThumbnailService.shared.videoFormatInfo(for: url, cacheKey: cacheKey.previewKey) {
            guard !Task.isCancelled else { return }
            loadedFormatInfo = info
            formatInfo = info
        }

        guard !Task.isCancelled else { return }
        let image = await WallpaperThumbnailService.shared.videoPosterImage(
            for: url, cacheKey: cacheKey.previewKey,
            tolerance: (.positiveInfinity, .positiveInfinity)
        )
        guard !Task.isCancelled else { return }
        thumbnail = image
        if image != nil || loadedFormatInfo != nil {
            AerialThumbnailCache.shared.insert(
                AerialThumbnailCacheEntry(thumbnail: image, formatInfo: loadedFormatInfo),
                for: cacheKey
            )
        }
    }
}
