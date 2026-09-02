import AppKit
import LiveWallpaperCore
import SwiftUI

/// Something the user could hand to macOS: a bookmarked video, or a video-type
/// Workshop import. Both sources produce the same tile, so the sheet does not
/// have to know which list a row came from.
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

    /// Throws rather than swallowing: the sheet publishes several at once, and a
    /// later success clears `lastError`, so a failure that is not collected here
    /// vanishes with no message. `publish(fileURLs:)` learned this already.
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

    /// Poster frame, when the source can produce one. Workshop entries reuse the
    /// preview the import already stored; bookmarks decode a frame the same way
    /// the Bookmarks grid does, through the shared cache.
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
            guard case let .success(resolved) = SecurityScopedBookmarkResolver.shared.resolve(
                data,
                target: .transient
            ) else { return nil }
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
        Button(action: onToggle) {
            VStack(spacing: 0) {
                poster
                ThumbnailTitleBand(title: candidate.title, isHovering: isHovering) { EmptyView() }
            }
        }
        .buttonStyle(.plain)
        .galleryTileChrome(isHovering: isHovering, isSelected: isSelected, reduceMotion: reduceMotion)
        .settledHover { isHovering = $0 }
        .task(id: candidate.id) { thumbnail = await candidate.thumbnail() }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityLabel(Text(verbatim: candidate.title))
    }

    private var poster: some View {
        ZStack {
            Rectangle().fill(Color.accentColor.opacity(0.12))
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
        .aspectRatio(16 / 9, contentMode: .fill)
        .clipped()
        .overlay(alignment: .topTrailing) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isSelected ? Color.accentColor : DesignTokens.Colors.overlayForeground)
                .padding(6)
                .floatingGlyphGlass(hovered: isHovering, opacity: 0.72)
                .padding(8)
                .accessibilityHidden(true)
        }
    }
}
