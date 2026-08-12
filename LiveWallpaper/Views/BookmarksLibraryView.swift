import SwiftUI
import LiveWallpaperCore

struct BookmarksLibraryView: View {
    @Environment(ScreenManager.self) private var screenManager
    @State private var store = BookmarkStore.shared
    @State private var renamingID: UUID?
    @State private var renameDraft: String = ""
    @State private var searchText: String = ""
    @State private var typeFilter: BookmarkTypeFilter = .all
    @State private var pendingDestructive: PendingDestructive?


    var body: some View {
        DetailPageScaffold(
            header: { header },
            content: { content }
        )
        .confirmDestructive($pendingDestructive)
    }

    // MARK: - Header

    private var header: some View {
        DetailHeaderBar(
            systemImage: "bookmark.fill",
            title: { Text("Bookmarks") },
            metadata: {
                Text("\(store.bookmarks.count) saved wallpapers")
            },
            actions: { EmptyView() }
        )
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if store.bookmarks.isEmpty {
            emptyState
        } else {
            VStack(spacing: 0) {
                filterBar
                gallery
            }
        }
    }

    @ViewBuilder
    private var filterBar: some View {
        if showsTypeChips {
            LibraryFilterBar(
                searchText: $searchText,
                searchPrompt: "Search bookmarks",
                resultCount: filteredBookmarks.count,
                totalCount: store.bookmarks.count
            ) {
                typeChipRow
            }
        } else {
            LibraryFilterBar(
                searchText: $searchText,
                searchPrompt: "Search bookmarks",
                resultCount: filteredBookmarks.count,
                totalCount: store.bookmarks.count
            )
        }
    }

    @ViewBuilder
    private var gallery: some View {
        if filteredBookmarks.isEmpty {
            IllustratedEmptyState(
                symbol: "magnifyingglass",
                title: "No bookmarks match your search",
                message: "Try a different keyword, or clear the search field to see every saved wallpaper."
            )
        } else {
            ScrollView {
                LazyVGrid(columns: DesignTokens.LibraryGrid.columns, spacing: DesignTokens.LibraryGrid.spacing) {
                    ForEach(filteredBookmarks) { bookmark in
                        BookmarkTile(
                            bookmark: bookmark,
                            screens: screenManager.screens,
                            isRenaming: renamingID == bookmark.id,
                            renameDraft: $renameDraft,
                            onApply: { screen in screenManager.applyBookmark(bookmark, to: screen) },
                            onApplyToAll: { applyToAll(bookmark) },
                            onStartRename: {
                                renamingID = bookmark.id
                                renameDraft = bookmark.label
                            },
                            onCommitRename: {
                                store.rename(bookmark.id, to: renameDraft)
                                renamingID = nil
                            },
                            onCancelRename: { renamingID = nil },
                            onDelete: {
                                pendingDestructive = PendingDestructive(
                                    .deleteBookmark(bookmarkName: bookmark.label)
                                ) { store.remove(bookmark.id) }
                            }
                        )
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }
        }
    }

    private var typeChipRow: some View {
        HStack(spacing: 6) {
            FilterChip(title: Text("All"),
                       isSelected: typeFilter == .all,
                       action: { typeFilter = .all })

            ForEach(WallpaperType.allCases) { type in
                if availableTypes.contains(type) {
                    FilterChip(title: Text(type.titleKey),
                               isSelected: typeFilter == .type(type),
                               action: { typeFilter = .type(type) })
                }
            }
        }
    }

    private var emptyState: some View {
        IllustratedEmptyState(
            symbol: "bookmark",
            title: "No bookmarks yet",
            message: "Open any display, configure a video / website / scene, then click the bookmark icon in the inspector header to save it here."
        )
    }

    // MARK: - Filtering

    private var showsTypeChips: Bool {
        availableTypes.count > 1
    }

    private var availableTypes: Set<WallpaperType> {
        Set(store.bookmarks.map(\.wallpaperType))
    }

    private var filteredBookmarks: [WallpaperBookmark] {
        var result = store.bookmarks
        // Honor type filter only while chips are visible and that type still exists.
        if showsTypeChips, case .type(let type) = typeFilter, availableTypes.contains(type) {
            result = result.filter { $0.wallpaperType == type }
        }
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            result = result.filter { $0.label.localizedCaseInsensitiveContains(trimmed) }
        }
        return result
    }

    // MARK: - Apply

    private func applyToAll(_ bookmark: WallpaperBookmark) {
        Logger.info("Applying bookmark to all displays: \(bookmark.wallpaperType.rawValue)", category: .ui)
        for screen in screenManager.screens {
            screenManager.applyBookmark(bookmark, to: screen)
        }
    }
}

// MARK: - Type filter

private enum BookmarkTypeFilter: Hashable {
    case all
    case type(WallpaperType)
}

// MARK: - Tile

private struct BookmarkTile: View {
    let bookmark: WallpaperBookmark
    let screens: [Screen]
    let isRenaming: Bool
    @Binding var renameDraft: String
    let onApply: (Screen) -> Void
    let onApplyToAll: () -> Void
    let onStartRename: () -> Void
    let onCommitRename: () -> Void
    let onCancelRename: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false
    @State private var thumbnail: NSImage?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            thumbnailTile
            metadata
                .padding(DesignTokens.Spacing.md)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .galleryTileChrome(isHovering: isHovering, reduceMotion: reduceMotion)
        .onHover { isHovering = $0 }
        .contextMenu { contextMenu }
        .task(id: bookmark.id) { await loadThumbnail() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityActions {
            if screens.count == 1, let only = screens.first {
                Button("Apply") { onApply(only) }
            } else if screens.count > 1 {
                Button("Apply to All Displays", action: onApplyToAll)
            }
            Button("Rename", action: onStartRename)
        }
        .accessibilityAction(.delete, onDelete)
    }

    private var accessibilityLabel: Text {
        let name = bookmark.label
        return Text("\(name), \(Text(bookmark.wallpaperType.titleKey)) wallpaper bookmark",
             comment: "Bookmark tile accessibility label. %1$@ is the bookmark name, %2$@ is the localized wallpaper type (Video / Web / Scene / Monitor).")
    }

    // MARK: Thumbnail tile

    /// Poster as an `overlay` rather than a ZStack sibling: `scaledToFill` reports
    /// the *scaled* size, so as a sibling it grew the tile to the thumbnail's own
    /// aspect ratio and bled into the neighbouring grid column. See the same note
    /// in `AerialThumbnailCard`.
    private var thumbnailTile: some View {
        tileBackground
            .overlay { tileContent }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .clipped()
            .overlay(alignment: .topLeading) {
                typeBadge
                    .padding(DesignTokens.Spacing.sm)
            }
    }

    private var tileBackground: some View {
        Rectangle()
            .fill(bookmark.presentationTint.opacity(0.12))
    }

    @ViewBuilder
    private var tileContent: some View {
        if let thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .interpolation(.high)
                .scaledToFill()
        } else {
            Image(systemName: bookmark.iconName)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(bookmark.presentationTint.opacity(0.85))
        }
    }

    /// Thumbnail-only; SF Symbol fallback already implies type.
    private var typeBadge: some View {
        Image(systemName: bookmark.iconName)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(DesignTokens.Colors.overlayForeground)
            .frame(width: 20, height: 20)
            .floatingGlyphGlass(hovered: false)
            .opacity(thumbnail == nil ? 0 : 1)
            .accessibilityHidden(true)
    }

    private var applyControl: some View {
        LibraryTileApplyControl(
            screens: screens,
            tint: bookmark.presentationTint,
            onApply: onApply,
            onApplyToAll: onApplyToAll
        )
    }

    private var deleteButton: some View {
        Button(role: .destructive, action: onDelete) {
            Image(systemName: "trash")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text("Delete bookmark"))
    }

    // MARK: Metadata

    private var metadata: some View {
        HStack(alignment: .center, spacing: DesignTokens.Spacing.sm) {
            textBlock
            Spacer(minLength: DesignTokens.Spacing.xs)
            if !isRenaming {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    applyControl
                    deleteButton
                }
            }
        }
    }

    @ViewBuilder
    private var textBlock: some View {
        if isRenaming {
            renameField
        } else {
            VStack(alignment: .leading, spacing: 1) {
                Button(action: onStartRename) {
                    MarqueeText(bookmark.label, lineLimit: 1, isActive: isHovering)
                        .font(DesignTokens.Typography.bodyEmphasized)
                        .foregroundStyle(.primary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Text("Rename"))
                bookmark.subtitleText
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var renameField: some View {
        HStack(spacing: 4) {
            TextField("Name", text: $renameDraft)
                .textFieldStyle(.roundedBorder)
                .font(DesignTokens.Typography.body)
                .onSubmit(onCommitRename)
                .onExitCommand(perform: onCancelRename)
            Button(action: onCommitRename) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.tint)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.defaultAction)
            .help(Text("Save"))
            Button(action: onCancelRename) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help(Text("Cancel"))
        }
    }

    // MARK: Thumbnail loader

    /// Run via `.task(id: bookmark.id)` so SwiftUI cancels the decode +
    /// security-scoped resolve when the tile leaves the viewport on fast-scroll.
    @MainActor
    private func loadThumbnail() async {
        thumbnail = nil

        if let cached = WallpaperThumbnailService.shared.cachedThumbnail(forKey: bookmarkCacheKey) {
            thumbnail = cached
            return
        }

        switch bookmark.content {
        case .video(let bookmarkData, let packageEntryName):
            // Packaged videos resolve to a scene.pkg, which has no plain video
            // poster frame; skip the thumbnail rather than mis-decode the pkg.
            guard packageEntryName == nil else { break }
            guard case .success(let resolved) = SecurityScopedBookmarkResolver.shared.resolve(
                bookmarkData,
                target: .transient
            ) else { return }
            guard !Task.isCancelled else { return }
            if let image = await WallpaperThumbnailService.shared.videoPosterImage(
                for: resolved.url,
                cacheKey: bookmarkCacheKey
            ), !Task.isCancelled {
                thumbnail = image
            }
        case .html(let source, let config):
            if let image = await HTMLPreviewKey.fetchSnapshot(
                for: source,
                config: config,
                cacheKey: bookmarkCacheKey
            ), !Task.isCancelled {
                thumbnail = image
            }
        case .scene:
            break
        }
    }

    private var bookmarkCacheKey: String {
        // Include the content type so a thumbnail cached for one type can never
        // be served for another if a bookmark's resolved content changes.
        let typeTag: String
        switch bookmark.content {
        case .video:       typeTag = "video"
        case .html(let source, let config):
            typeTag = "html::" + HTMLPreviewKey.key(for: source, config: config)
        case .scene:       typeTag = "scene"
        }
        return "bookmark::\(typeTag)::\(bookmark.id.uuidString)"
    }

    // MARK: Context menu

    @ViewBuilder
    private var contextMenu: some View {
        if !screens.isEmpty {
            ForEach(screens, id: \.id) { screen in
                Button("Apply to \(screen.name)") { onApply(screen) }
            }
            if screens.count > 1 {
                Button("Apply to All Displays", action: onApplyToAll)
            }
            Divider()
        }
        Button("Rename", action: onStartRename)
        Button("Delete", role: .destructive, action: onDelete)
    }
}
