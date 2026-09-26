#if !LITE_BUILD
import LiveWallpaperCore
import SwiftUI

extension WorkshopBookmark {
    var wallpaperType: WallpaperType? {
        let lowered = Set(tags.map { $0.lowercased() })
        if lowered.contains("scene") {
            return .scene
        }
        if lowered.contains("video") {
            return .video
        }
        if lowered.contains("web") {
            return .html
        }
        return nil
    }

    var displayTitle: String {
        WorkshopQueryItem.displayTitle(rawTitle, id: id)
    }

    /// Rebuilt from what was saved: `isBanned` is not known until a live lookup, so callers keep Download off until then.
    var queryItem: WorkshopQueryItem {
        WorkshopQueryItem(
            id: id, rawTitle: rawTitle, shortDescription: "", creatorID: nil,
            previewImageURL: previewImageURL, fileSizeBytes: nil, timeUpdated: nil,
            subscriptionCount: nil, rating: nil, tags: tags, visibility: .unknown,
            isBanned: false, steamCommunityURL: WorkshopCommunityURL.item(itemID: id)
        )
    }
}

struct WorkshopBookmarkGallery: View {
    let bookmarks: [WorkshopBookmark]
    @Environment(\.libraryTileSize) private var tileSize
    @Environment(\.galleryCardPreferences) private var cardPreferences
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedBookmark: WorkshopBookmark?

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Text("Workshop Bookmarks")
                .font(DesignTokens.Typography.sectionTitle)
            Text("Saved for later. Open a wallpaper to download or apply it.")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(.secondary)
            LibraryGalleryGrid(size: tileSize, aspect: .square) {
                ForEach(bookmarks) { bookmark in
                    BrowseCard(
                        item: bookmark.queryItem,
                        cardPreferences: cardPreferences,
                        reduceMotion: reduceMotion,
                        isBookmarked: true,
                        onBookmark: { WorkshopBookmarkActions.toggle(bookmark.queryItem) },
                        onSelect: { selectedBookmark = bookmark }
                    )
                }
            }
        }
        .libraryGridPadding()
        .sheet(item: $selectedBookmark) { bookmark in
            AppLanguageScope(defaults: .appScoped()) {
                WorkshopBookmarkDetail(bookmark: bookmark)
            }
        }
    }
}

private struct WorkshopBookmarkDetail: View {
    let bookmark: WorkshopBookmark
    @Environment(\.dismiss) private var dismiss
    @Environment(SteamCMDDoctorService.self) private var doctor
    @Environment(WorkshopServices.self) private var services
    @State private var currentItem: WorkshopQueryItem?
    @State private var lookupFailed = false

    var body: some View {
        VStack(spacing: 0) {
            SteamSheetHeader(icon: "bookmark", title: "Workshop Bookmarks")
                .padding(DesignTokens.Spacing.lg)
            if lookupFailed {
                Text("Live details are unavailable. Showing the saved wallpaper.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, DesignTokens.Spacing.lg)
            }
            WorkshopInspectorContent(
                item: currentItem ?? bookmark.queryItem, doctor: doctor, allowsDownload: currentItem != nil
            )
            SheetFooterBar(primaryTitle: "Done", primaryAction: { dismiss() })
        }
        .frame(width: SteamSheetWidth.dense, height: DesignTokens.LibraryPage.minHeight)
        .task(id: bookmark.id) {
            await doctor.autoConfirmDownloadReadinessIfNeeded()
            let result = await services.itemDetails.load(ids: [bookmark.id])
            guard !Task.isCancelled else { return }
            currentItem = result.items.first
            lookupFailed = currentItem == nil
        }
    }
}
#endif
