import AppKit
import LiveWallpaperCore
import SwiftUI

struct LibraryView: View {
    @Environment(\.libraryTileSize) private var tileSize
    @Environment(ScreenManager.self) private var screenManager
    @State private var store = BookmarkStore.shared
    @State private var renamingID: UUID?
    @State private var renameDraft: String = ""
    @State private var searchText: String = ""
    @State private var typeFilter: BookmarkTypeFilter = .all
    @State private var pendingDestructive: PendingDestructive?
    @State private var dragSession = LibraryDragSession()
    @AppStorage(SavedLibrarySortOrder.preferencesKey, store: .appScoped())
    private var sortOrder: SavedLibrarySortOrder = .recent


    var body: some View {
        DetailPageScaffold { content }
            .confirmDestructive($pendingDestructive)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if store.bookmarks.isEmpty {
            emptyState
        } else {
            let visible = filteredBookmarks
            VStack(spacing: 0) {
                filterBar
                Divider()
                gallery(visible)
                LibraryStatusBar(summary: statusSummary(shown: visible.count))
            }
        }
    }

    private var filterBar: some View {
        LibraryFilterBar(searchText: $searchText, searchPrompt: "Search bookmarks") {
            HStack(spacing: DesignTokens.LibraryFilterBar.contentSpacing) {
                if showsTypeChips {
                    typeChipRow
                }
                Spacer(minLength: 0)
                SavedLibrarySortPicker(selection: $sortOrder)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func statusSummary(shown: Int) -> Text {
        let total = store.bookmarks.count
        return shown == total
            ? Text("\(total) bookmarks")
            : Text("\(shown) of \(total) shown")
    }

    @ViewBuilder
    private func gallery(_ visible: [WallpaperBookmark]) -> some View {
        if visible.isEmpty {
            IllustratedEmptyState(
                symbol: "magnifyingglass",
                title: "No bookmarks match your search"
            )
        } else {
            ScrollView {
                LibraryGalleryGrid(size: tileSize, aspect: .wide) {
                    ForEach(visible) { bookmark in
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
                        .onDrag {
                            NSItemProvider(object: dragSession.begin(payload: bookmark.id.uuidString) as NSString)
                        } preview: {
                            LibraryDragPreview(systemImage: bookmark.iconName)
                        }
                    }
                }
                .libraryGridPadding()
            }
            .overlay(alignment: .top) {
                if dragSession.isDragging, !screenManager.screens.isEmpty {
                    dropBar
                }
            }
            .animation(.easeInOut(duration: 0.2), value: dragSession.isDragging)
        }
    }

    private var dropBar: some View {
        LibraryDragApplyBar(
            screens: screenManager.screens,
            onCancel: { dragSession.end() },
            makeDropHandler: { screen in
                { identifier, loadFailed in
                    dragSession.end()
                    guard !loadFailed,
                          let identifier,
                          let id = UUID(uuidString: identifier),
                          // Re-read both sides: the library and the display list can
                          // both change while the provider read is in flight.
                          let bookmark = store.bookmarks.first(where: { $0.id == id }),
                          screenManager.screens.contains(where: { $0.id == screen.id })
                    else { return }
                    // Same gate as the tile: a veiled entry is not applied by dropping it either.
                    Task { @MainActor in
                        let location = await LibraryContentLocator.locate(
                            content: bookmark.content, wpeOrigin: bookmark.wpeOrigin
                        )
                        guard location.isAvailable,
                              let target = screenManager.screens.first(where: { $0.id == screen.id })
                        else { return }
                        screenManager.applyBookmark(bookmark, to: target)
                    }
                }
            }
        )
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
        LibraryGuideCard(
            icon: "bookmark",
            tint: DesignTokens.Colors.LibraryTint.bookmarks,
            title: "No bookmarks yet",
            message: "Use the bookmark button on a display to save its wallpaper. Applying one swaps the wallpaper and leaves that display's settings alone."
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
        if showsTypeChips, case .type(let type) = typeFilter, availableTypes.contains(type) {
            result = result.filter { $0.wallpaperType == type }
        }
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            result = result.filter { $0.label.localizedCaseInsensitiveContains(trimmed) }
        }
        return sortOrder.sorted(
            result,
            name: \.label,
            date: \.createdAt,
            type: \.wallpaperType
        )
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
    @State private var location = LibraryContentLocation.unknown
    @State private var showingTargets = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(WallpaperExportService.self) private var exportService

    var body: some View {
        thumbnailTile
            .frame(maxWidth: .infinity, alignment: .leading)
            .galleryTileChrome(isHovering: isHovering, reduceMotion: reduceMotion)
            .settledHover { isHovering = $0 }
            .popover(isPresented: $showingTargets, arrowEdge: .bottom) {
                LibraryApplyTargetList(
                    screens: screens,
                    onApply: onApply,
                    onApplyToAll: onApplyToAll,
                    dismiss: { showingTargets = false }
                )
            }
            .help(applyHelp)
            .contextMenu { contextMenu }
            // Keyed on the cover too: it is written asynchronously after the
            // save, and the tile has to pick it up when it lands.
            .tileTask(id: TileContentKey(id: bookmark.id, coverFileName: bookmark.coverFileName)) {
                await loadTileContent()
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityActions {
                // Same gate as the tap and the context menu.
                if location.isAvailable, screens.count == 1, let only = screens.first {
                    Button("Apply") { onApply(only) }
                } else if location.isAvailable, screens.count > 1 {
                    Button("Apply to All Displays", action: onApplyToAll)
                }
                Button("Rename", action: onStartRename)
            }
            .accessibilityAction(.delete, onDelete)
    }

    private var applyHelp: Text {
        location.isAvailable
            ? Text("Apply")
            : Text("This wallpaper's file is missing")
    }

    private func applyFromCard() {
        guard !isRenaming, location.isAvailable else { return }
        if screens.count == 1, let only = screens.first {
            onApply(only)
        } else if screens.count > 1 {
            showingTargets = true
        }
    }

    private var accessibilityLabel: Text {
        let name = bookmark.label
        return Text("\(name), \(Text(bookmark.wallpaperType.titleKey)) wallpaper bookmark",
             comment: "Bookmark tile accessibility label. %1$@ is the bookmark name, %2$@ is the localized wallpaper type (Video / Web / Scene / Monitor).")
    }

    // MARK: Thumbnail tile

    /// An overlay keeps scaled-to-fill artwork from changing the tile’s aspect ratio.
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
            .overlay(alignment: .topLeading) {
                typeBadge
                    .padding(DesignTokens.Spacing.sm)
            }
            .overlay(alignment: .bottom) { bottomBand }
    }

    @ViewBuilder
    private var bottomBand: some View {
        if isRenaming {
            // Square glass panel (radius 0): the band sits flush against the
            // tile's clipped bottom edge. Its controls are adaptive-coloured,
            // not light-on-dark, so this is not a `thumbnailBadgeGlass` case.
            renameField
                .padding(DesignTokens.Spacing.sm)
                .adaptiveGlassSurface(.roundedRectangle(0), stroked: false)
        } else {
            ThumbnailTitleBand(title: bookmark.label, isHovering: isHovering) {
                overflowButton
            }
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
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var overflowButton: some View {
        LibraryTileOverflowButton { dismiss in
            Button("Rename") {
                dismiss()
                onStartRename()
            }
            if let revealURL = location.revealURL {
                Button("Show in Finder") {
                    dismiss()
                    NSWorkspace.shared.activateFileViewerSelecting([revealURL])
                }
            }
            systemWallpaperActions(dismiss: dismiss)
            Divider()
            Button("Delete", role: .destructive) {
                dismiss()
                onDelete()
            }
            .destructiveControlTint()
        }
    }

    @ViewBuilder
    private func systemWallpaperActions(dismiss: @escaping () -> Void) -> some View {
        if #available(macOS 26.0, *), case .video = bookmark.content {
            if exportService.isPublished(bookmarkID: bookmark.id) {
                // Not disabled while in use: the System Wallpaper page deliberately allows removing the
                // playing video, and the two entry points must agree.
                Button("Remove from System Wallpaper") {
                    dismiss()
                    try? exportService.remove(itemID: bookmark.id.uuidString)
                }
            } else {
                Button("Add to System Wallpaper") {
                    dismiss()
                    Task { try? await exportService.publish(bookmark: bookmark) }
                }
            }
        }
    }

    // MARK: Metadata

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

    @MainActor
    private func loadTileContent() async {
        thumbnail = nil
        // Resolved before the artwork: Show in Finder and the unavailable veil
        // both read it, and neither should wait on a decode.
        let resolvedLocation = await LibraryContentLocator.locate(
            content: bookmark.content,
            wpeOrigin: bookmark.wpeOrigin
        )
        guard !Task.isCancelled else { return }
        location = resolvedLocation
        // A cover is a still of the real display taken when this was saved, so
        // it beats anything recomputed from the file — and it is the only
        // artwork a scene bookmark has at all.
        if let coverFileName = bookmark.coverFileName,
           let cover = await WallpaperCoverStore.shared.cover(named: coverFileName),
           !Task.isCancelled {
            thumbnail = cover
            return
        }
        guard !Task.isCancelled else { return }
        await loadThumbnail()
    }

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
            guard let resolved = await LibraryContentLocator.resolvePreviewBookmark(bookmarkData) else { return }
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
        if !screens.isEmpty, location.isAvailable {
            ForEach(screens, id: \.id) { screen in
                Button("Apply to \(screen.name)") { onApply(screen) }
            }
            if screens.count > 1 {
                Button("Apply to All Displays", action: onApplyToAll)
            }
            Divider()
        }
        Button("Rename", action: onStartRename)
        if let revealURL = location.revealURL {
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([revealURL])
            }
        }
        systemWallpaperActions(dismiss: {})
        Divider()
        Button("Delete", role: .destructive, action: onDelete)
    }
}
