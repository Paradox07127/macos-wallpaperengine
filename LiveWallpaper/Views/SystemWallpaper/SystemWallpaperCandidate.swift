import AppKit
import LiveWallpaperCore
import SwiftUI

@available(macOS 26.0, *)
struct SystemWallpaperCandidate: Identifiable {
    enum Source {
        case bookmark(WallpaperBookmark)
        #if !LITE_BUILD
        case workshop(WPEHistoryEntry)
        #endif
    }

    let id: String
    let title: String
    let source: Source

    /// Already-published entries are dropped rather than shown disabled: this is
    /// a list of things you can add, not a status display.
    @MainActor
    static func all(bookmarks: [WallpaperBookmark], service: WallpaperExportService) -> [SystemWallpaperCandidate] {
        var result: [SystemWallpaperCandidate] = bookmarks.compactMap { bookmark in
            guard case .video = bookmark.content, !service.isPublished(bookmarkID: bookmark.id) else { return nil }
            return SystemWallpaperCandidate(
                id: "bookmark::\(bookmark.id.uuidString)",
                title: bookmark.label,
                source: .bookmark(bookmark)
            )
        }
        #if !LITE_BUILD
        result += SettingsManager.shared.loadGlobalSettings().recentWPEImports.compactMap { entry in
            guard entry.origin.originalType == .video,
                  !((entry.origin.entryFile ?? "").isEmpty) else { return nil }
            let id = workshopItemID(workshopID: entry.origin.workshopID)
            guard !service.isPublished(itemID: id) else { return nil }
            return SystemWallpaperCandidate(id: id, title: entry.origin.title, source: .workshop(entry))
        }
        #endif
        return result
    }

    #if !LITE_BUILD
    /// Stable across sessions so `isPublished` can recognise an entry it already
    /// handed over. Namespaced so it can never collide with a bookmark's UUID.
    static func workshopItemID(workshopID: String) -> String {
        "workshop::\(workshopID)"
    }
    #endif

    @MainActor
    func publish(using service: WallpaperExportService) async throws {
        switch source {
        case let .bookmark(bookmark):
            try await service.publish(bookmark: bookmark)
        #if !LITE_BUILD
        case let .workshop(entry):
            guard let content = WPECachedContentResolver().content(for: entry.origin) else {
                throw WallpaperExportService.ServiceError.unsupportedContent
            }
            try await service.publish(content: content, title: entry.origin.title, id: id)
        #endif
        }
    }

    /// Poster frame when the source can produce one; Workshop entries have none yet and
    /// fall back to the tile's placeholder.
    @MainActor
    func thumbnail() async -> NSImage? {
        switch source {
        case let .bookmark(bookmark):
            guard case let .video(data, packageEntryName) = bookmark.content,
                  packageEntryName == nil else { return nil }
            let key = "bookmark::video::\(bookmark.id.uuidString)"
            if let cached = WallpaperThumbnailService.shared.cachedThumbnail(forKey: key) {
                return cached
            }
            guard let resolved = await LibraryContentLocator.resolvePreviewBookmark(data),
                  !Task.isCancelled else { return nil }
            return await WallpaperThumbnailService.shared.videoPosterImage(for: resolved.url, cacheKey: key)
        #if !LITE_BUILD
        case .workshop:
            return nil
        #endif
        }
    }
}

@available(macOS 26.0, *)
struct SystemWallpaperCandidateTile: View {
    let candidate: SystemWallpaperCandidate
    let isSelected: Bool
    let onToggle: () -> Void

    @State private var isHovering = false
    @State private var thumbnail: NSImage?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: onToggle) { poster }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .galleryTileChrome(isHovering: isHovering, isSelected: isSelected, reduceMotion: reduceMotion)
            .settledHover { isHovering = $0 }
            .task(id: candidate.id) {
                thumbnail = nil
                let loaded = await candidate.thumbnail()
                guard !Task.isCancelled else { return }
                thumbnail = loaded
            }
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityLabel(Text(verbatim: candidate.title))
    }

    /// Artwork must stay an `overlay`: as a sibling, `scaledToFill` reports the scaled
    /// size and the tile grows out of its grid column.
    private var poster: some View {
        Rectangle()
            .fill(Color.accentColor.opacity(0.12))
            .overlay { artwork }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .clipped()
            .overlay(alignment: .topTrailing) {
                selectionMark
                    .padding(DesignTokens.Spacing.sm)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottom) {
                ThumbnailTitleBand(title: candidate.title, isHovering: isHovering) { EmptyView() }
            }
    }

    @ViewBuilder
    private var artwork: some View {
        if let thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .interpolation(.high)
                .scaledToFill()
        } else {
            Image(systemName: "film")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Color.accentColor.opacity(0.85))
        }
    }

    private var selectionMark: some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(isSelected ? Color.accentColor : DesignTokens.Colors.overlayForeground)
            .frame(width: 22, height: 22)
            .floatingGlyphGlass(hovered: isHovering, opacity: 0.72)
            .accessibilityHidden(true)
    }
}
