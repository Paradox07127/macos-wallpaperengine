import AppKit
import LiveWallpaperCore
import SwiftUI

/// The Saved page's Bookmarks tab: the rows it lists, the modal a row opens and a card's context menu.
@MainActor @Observable
final class SavedBookmarks {
    let store: BookmarkStore
    /// The library modal's own actions, so a card's menu and the modal apply, rename and remove the same way.
    let actions: ModalActions
    let thumbnails: ShelfThumbnailCache
    let drag = LibraryDragController()
    var searchText = ""
    /// nil lists every type.
    var typeFilter: WallpaperType?
    /// The row whose modal is open; nil when none.
    var presentedItemID: String?
    /// The row the rename alert is open for; nil closes it.
    var renamingItemID: String?
    var nameDraft = ""
    #if !LITE_BUILD
    let workshopStore: WorkshopBookmarkStore
    /// The Workshop bookmark whose modal is open; nil when none.
    var presentedWorkshopID: UInt64?

    init(
        store: BookmarkStore, workshopStore: WorkshopBookmarkStore, undo: EditDeskUndoStack?,
        displays: @escaping @MainActor () -> [ModalActions.Display],
        apply: @escaping @MainActor (ApplyIntent, CGDirectDisplayID) -> Void,
        applyToAll: @escaping @MainActor (ApplyIntent, [CGDirectDisplayID]) -> Void
    ) {
        self.store = store
        self.workshopStore = workshopStore
        thumbnails = ShelfThumbnailCache()
        actions = Self.makeActions(
            store: store, thumbnails: thumbnails, undo: undo, displays: displays, apply: apply, applyToAll: applyToAll
        )
    }
    #else
    init(
        store: BookmarkStore, undo: EditDeskUndoStack?,
        displays: @escaping @MainActor () -> [ModalActions.Display],
        apply: @escaping @MainActor (ApplyIntent, CGDirectDisplayID) -> Void,
        applyToAll: @escaping @MainActor (ApplyIntent, [CGDirectDisplayID]) -> Void
    ) {
        self.store = store
        thumbnails = ShelfThumbnailCache()
        actions = Self.makeActions(
            store: store, thumbnails: thumbnails, undo: undo, displays: displays, apply: apply, applyToAll: applyToAll
        )
    }
    #endif

    private static func makeActions(
        store: BookmarkStore, thumbnails: ShelfThumbnailCache, undo: EditDeskUndoStack?,
        displays: @escaping @MainActor () -> [ModalActions.Display],
        apply: @escaping @MainActor (ApplyIntent, CGDirectDisplayID) -> Void,
        applyToAll: @escaping @MainActor (ApplyIntent, [CGDirectDisplayID]) -> Void
    ) -> ModalActions {
        var inputs = ModalActions.Inputs()
        inputs.item = { id in store.bookmarks.lazy.map(Self.item(for:)).first { $0.id == id } }
        inputs.displays = displays
        return ModalActions(
            inputs: inputs, bookmarks: store, thumbnails: thumbnails, undo: undo, apply: apply, applyToAll: applyToAll
        )
    }

    /// Every bookmark as its own row, including one the wallpaper library folds into its Workshop project.
    static func item(for bookmark: WallpaperBookmark) -> LibraryItem {
        let kind: LibraryItem.Kind = switch bookmark.content {
        case .video: .video
        case .html: .web
        case .scene: .scene
        }
        return LibraryItem(
            id: "bookmark:\(bookmark.id)", title: bookmark.label, kind: kind, source: .bookmark(bookmark),
            isSteam: false, createdAt: bookmark.createdAt, lastUsedAt: bookmark.lastUsedAt, onDisplays: [],
            thumbnail: .bookmark(bookmark), metadata: nil, isVariant: false, parentID: nil, isSupported: true
        )
    }

    var items: [LibraryItem] {
        store.bookmarks.map(Self.item(for:))
    }

    func item(_ id: String?) -> LibraryItem? {
        guard let id else { return nil }
        return store.bookmarks.lazy.map(Self.item(for:)).first { $0.id == id }
    }

    var isEmpty: Bool {
        #if LITE_BUILD
        store.bookmarks.isEmpty
        #else
        store.bookmarks.isEmpty && workshopBookmarks.isEmpty
        #endif
    }

    var totalCount: Int {
        #if LITE_BUILD
        store.bookmarks.count
        #else
        store.bookmarks.count + workshopBookmarks.count
        #endif
    }

    var availableTypes: Set<WallpaperType> {
        var types = Set(store.bookmarks.map(\.wallpaperType))
        #if !LITE_BUILD
        types.formUnion(workshopBookmarks.compactMap(Self.type(of:)))
        #endif
        return types
    }

    /// A filter whose type is no longer saved lists everything, as the scheme grid does.
    private var activeType: WallpaperType? {
        typeFilter.flatMap { availableTypes.contains($0) ? $0 : nil }
    }

    private var query: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func visibleItems(sort: SavedLibrarySortOrder) -> [LibraryItem] {
        var result = store.bookmarks
        if let type = activeType {
            result = result.filter { $0.wallpaperType == type }
        }
        if !query.isEmpty {
            result = result.filter { $0.label.localizedCaseInsensitiveContains(query) }
        }
        return sort.sorted(result, name: \.label, date: \.createdAt, type: \.wallpaperType).map(Self.item(for:))
    }

    #if !LITE_BUILD
    /// One already saved as a wallpaper bookmark is listed with those instead.
    var workshopBookmarks: [WorkshopBookmark] {
        workshopStore.bookmarks.filter { !store.containsWPEBookmark(workshopID: String($0.id)) }
    }

    /// Newest first.
    var visibleWorkshopBookmarks: [WorkshopBookmark] {
        var result = workshopBookmarks
        if let type = activeType {
            result = result.filter { Self.type(of: $0) == type }
        }
        if !query.isEmpty {
            result = result.filter { WorkshopQueryItem.displayTitle($0.rawTitle, id: $0.id).localizedCaseInsensitiveContains(query) }
        }
        return result.sorted { $0.createdAt > $1.createdAt }
    }

    /// Read off the Steam tags saved with it; nil when none names a type.
    static func type(of bookmark: WorkshopBookmark) -> WallpaperType? {
        let tags = Set(bookmark.tags.map { $0.lowercased() })
        if tags.contains("scene") {
            return .scene
        }
        if tags.contains("video") {
            return .video
        }
        return tags.contains("web") ? .html : nil
    }

    /// Known metadata survives offline reopening; legacy references remain usable.
    static func queryItem(_ bookmark: WorkshopBookmark) -> WorkshopQueryItem {
        if let item = bookmark.queryItemSnapshot {
            return item
        }
        return WorkshopQueryItem(
            id: bookmark.id, rawTitle: bookmark.rawTitle, shortDescription: "", creatorID: nil,
            previewImageURL: bookmark.previewImageURL, fileSizeBytes: nil, timeUpdated: nil,
            subscriptionCount: nil, rating: nil, tags: bookmark.tags, visibility: .unknown,
            isBanned: false, steamCommunityURL: WorkshopCommunityURL.item(itemID: bookmark.id)
        )
    }
    #endif

    // MARK: Commands

    func requestRename(_ item: LibraryItem) {
        nameDraft = item.title
        renamingItemID = item.id
    }

    func rename(_ id: String) {
        guard let item = item(id) else { return }
        actions.actions(for: item).rename?(nameDraft)
    }

    func dragPayload(for item: LibraryItem, thumbnail: LibraryGridTile.Thumbnail?) -> LibraryDragController.Payload {
        LibraryDragController.Payload(
            item: item, image: thumbnail.flatMap { HomePage.gridImage($0, in: thumbnails) }, actions: actions.actions(for: item)
        )
    }

    /// `exportService` offers Add to or Remove from System Wallpaper for a video; nil leaves them out.
    func menuItems(for item: LibraryItem, exportService: WallpaperExportService?) -> [StageMenuItem] {
        let modal = actions.actions(for: item)
        let targets = actions.targets(for: item)
        var rows: [StageMenuItem] = []
        if targets.count == 1, let only = targets.first {
            rows.append(StageMenuItem(title: String(localized: "Apply", bundle: .appLanguage), isEnabled: true) {
                modal.applyTo(only.id)
            })
        } else {
            rows.append(StageMenuItem(
                title: String(localized: "Apply to", bundle: .appLanguage), isEnabled: !targets.isEmpty,
                submenu: targets.map { target in
                    StageMenuItem(title: target.name, isEnabled: true) { modal.applyTo(target.id) }
                }
            ) {})
        }
        rows.append(StageMenuItem(
            title: String(localized: "Apply to All Displays", bundle: .appLanguage), isEnabled: !targets.isEmpty,
            action: modal.applyToAllDisplays
        ))
        rows.append(StageMenuItem(title: String(localized: "Rename", bundle: .appLanguage), isEnabled: true) { [self] in
            requestRename(item)
        })
        if let showInFinder = modal.showInFinder {
            rows.append(StageMenuItem(
                title: String(localized: "Show in Finder", bundle: .appLanguage), isEnabled: true, action: showInFinder
            ))
        }
        if let exportService, EditDeskRouter.systemWallpaperSupported,
           case let .bookmark(bookmark) = item.source, case .video = bookmark.content {
            if exportService.isPublished(bookmarkID: bookmark.id) {
                rows.append(StageMenuItem(
                    title: String(localized: "Remove from System Wallpaper", bundle: .appLanguage), isEnabled: true
                ) {
                    try? exportService.remove(itemID: bookmark.id.uuidString)
                })
            } else {
                rows.append(StageMenuItem(
                    title: String(localized: "Add to System Wallpaper", bundle: .appLanguage), isEnabled: true
                ) {
                    Task { try? await exportService.publish(bookmark: bookmark) }
                })
            }
        }
        if let remove = modal.removeFromSaved {
            rows.append(StageMenuItem(
                title: String(localized: "Remove Bookmark", bundle: .appLanguage), isEnabled: true, isDestructive: true,
                action: remove
            ))
        }
        return rows
    }
}

// MARK: - Grid

struct BookmarksLibraryView: View {
    let bookmarks: SavedBookmarks
    /// The window's width, which the grid tiles' decode size is measured against.
    let windowWidth: CGFloat

    @Environment(\.libraryTileSize) private var tileSize
    @Environment(\.galleryCardPreferences) private var cardPreferences
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(WallpaperExportService.self) private var exportService: WallpaperExportService?
    @AppStorage(SavedLibrarySortOrder.preferencesKey, store: .appScoped())
    private var sortOrder: SavedLibrarySortOrder = .recent

    var body: some View {
        @Bindable var bookmarks = bookmarks
        DetailPageScaffold { content }
            .wallpaperRenameAlert(itemID: $bookmarks.renamingItemID, name: $bookmarks.nameDraft) { bookmarks.rename($0) }
    }

    @ViewBuilder
    private var content: some View {
        if bookmarks.isEmpty {
            IllustratedEmptyState(symbol: "bookmark", title: "No bookmarks yet")
        } else {
            let visible = bookmarks.visibleItems(sort: sortOrder)
            let shown = visible.count + visibleWorkshopCount
            VStack(spacing: 0) {
                filterBar
                if shown == 0 {
                    IllustratedEmptyState(symbol: "magnifyingglass", title: "No bookmarks match your search")
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            workshopSection
                            if !visible.isEmpty {
                                grid(visible)
                            }
                        }
                    }
                }
                LibraryStatusBar(summary: statusSummary(shown: shown))
            }
        }
    }

    private var visibleWorkshopCount: Int {
        #if LITE_BUILD
        0
        #else
        bookmarks.visibleWorkshopBookmarks.count
        #endif
    }

    private func statusSummary(shown: Int) -> Text {
        let total = bookmarks.totalCount
        return shown == total ? Text("\(total) bookmarks") : Text("\(shown) of \(total) shown")
    }

    private var filterBar: some View {
        @Bindable var bookmarks = bookmarks
        return LibraryFilterBar(searchText: $bookmarks.searchText, searchPrompt: "Search bookmarks") {
            HStack(spacing: DesignTokens.LibraryFilterBar.contentSpacing) {
                if bookmarks.availableTypes.count > 1 {
                    typeChipRow
                }
                Spacer(minLength: 0)
                SavedLibrarySortPicker(selection: $sortOrder)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var typeChipRow: some View {
        HStack(spacing: 6) {
            FilterChip(title: Text("All"), isSelected: bookmarks.typeFilter == nil) { bookmarks.typeFilter = nil }
            ForEach(WallpaperType.allCases) { type in
                if bookmarks.availableTypes.contains(type) {
                    FilterChip(title: Text(type.titleKey), isSelected: bookmarks.typeFilter == type) {
                        bookmarks.typeFilter = type
                    }
                }
            }
        }
    }

    private func grid(_ visible: [LibraryItem]) -> some View {
        LibraryGalleryGrid(size: tileSize, aspect: .wide) {
            ForEach(visible) { item in
                let thumbnail = HomePage.gridThumbnail(
                    for: item, stageWidth: windowWidth, size: tileSize, scale: NSScreen.main?.backingScaleFactor ?? 2
                )
                Button { bookmarks.presentedItemID = item.id } label: {
                    LibraryGridTile(item: item, thumbnail: thumbnail, thumbnails: bookmarks.thumbnails, badges: LibraryCardBadges())
                }
                .buttonStyle(.plain)
                .libraryDragSource(bookmarks.drag, enabled: true) { bookmarks.dragPayload(for: item, thumbnail: thumbnail) }
                .contextMenu { WallpaperMenuRows(items: bookmarks.menuItems(for: item, exportService: exportService)) }
                .accessibilityLabel(Text(verbatim: item.title))
            }
        }
        .libraryGridPadding()
    }

    @ViewBuilder
    private var workshopSection: some View {
        #if !LITE_BUILD
        let workshop = bookmarks.visibleWorkshopBookmarks
        if !workshop.isEmpty {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                Text("Workshop Bookmarks")
                    .font(DesignTokens.Typography.sectionTitle)
                    .accessibilityAddTraits(.isHeader)
                LibraryGalleryGrid(
                    size: tileSize, aspect: .square, columnWidth: DesignTokens.LibraryGrid.workshopBrowseColumnWidth
                ) {
                    ForEach(workshop) { bookmark in
                        BrowseCard(
                            item: SavedBookmarks.queryItem(bookmark), cardPreferences: cardPreferences,
                            reduceMotion: reduceMotion, isBookmarked: true,
                            onSelect: { bookmarks.presentedWorkshopID = bookmark.id }
                        )
                        .equatable()
                    }
                }
            }
            .libraryGridPadding()
        }
        #endif
    }
}

// MARK: - Modal

/// The wallpaper library's modal over the Bookmarks tab, and the strip and ghost of a drag toward the displays.
struct SavedBookmarkModal: View {
    let bookmarks: SavedBookmarks
    let windowSize: CGSize

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    @AppStorage(SavedLibrarySortOrder.preferencesKey, store: .appScoped())
    private var sortOrder: SavedLibrarySortOrder = .recent
    @State private var content: WallpaperModalContent?

    /// The loaded content's row, so a navigation still decoding keeps title, preview and actions together.
    private var presentedItem: LibraryItem? {
        bookmarks.item(content?.itemID ?? bookmarks.presentedItemID)
    }

    var body: some View {
        ZStack(alignment: .top) {
            if let item = presentedItem, let content {
                WallpaperModal(
                    content: content,
                    targets: bookmarks.actions.targets(for: item),
                    actions: bookmarks.actions.actions(for: item),
                    requestRename: { bookmarks.requestRename(item) },
                    requestDelete: {},
                    navigation: navigation(for: item),
                    windowSize: windowSize,
                    titlebarInset: DesignTokens.EditDesk.Spacing.topBar,
                    onDismiss: { bookmarks.presentedItemID = nil },
                    onDrag: handleDrag
                )
            }
            LibraryDragOverlay(
                drag: bookmarks.drag,
                targets: bookmarks.drag.payload.map { bookmarks.actions.targets(for: $0.item) } ?? [],
                windowWidth: windowSize.width
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(
            DesignTokens.motion(reduceMotion, .spring(response: 0.45, dampingFraction: 0.82)),
            value: bookmarks.presentedItemID != nil
        )
        .onChange(of: bookmarks.presentedItemID, initial: true) { _, id in
            if id == nil {
                content = nil
                bookmarks.drag.clear()
            }
        }
        .onChange(of: reduceMotion, initial: true) { bookmarks.drag.reduceMotion = reduceMotion }
        .task(id: bookmarks.presentedItemID) { await load() }
        .onChange(of: bookmarks.store.bookmarks) {
            // Removed from under the modal: nothing is left to show.
            if bookmarks.presentedItemID != nil, bookmarks.item(bookmarks.presentedItemID) == nil {
                bookmarks.presentedItemID = nil
            } else {
                Task { await load() }
            }
        }
    }

    private func load() async {
        guard let item = bookmarks.item(bookmarks.presentedItemID) else { return }
        var loaded = await bookmarks.actions.content(for: item)
        let preview = ModalGeometry.previewSize
        loaded.preview = await bookmarks.actions.preview(
            for: item, box: CGSize(width: preview.width * displayScale, height: preview.height * displayScale), liveStill: nil
        )
        // A slower load for the row shown before must not replace the newer one.
        guard bookmarks.presentedItemID == item.id else { return }
        content = loaded
    }

    private func navigation(for item: LibraryItem) -> ModalNavigation {
        // The grid's order, so ← → walk the run the user opened the row from.
        let run = bookmarks.visibleItems(sort: sortOrder).map(\.id)
        let index = run.firstIndex(of: bookmarks.presentedItemID ?? item.id)
        return ModalNavigation(
            canGoPrevious: index.map { $0 > 0 } ?? false,
            canGoNext: index.map { $0 + 1 < run.count } ?? false,
            previous: { navigate(by: -1) },
            next: { navigate(by: 1) }
        )
    }

    private func navigate(by offset: Int) {
        let run = bookmarks.visibleItems(sort: sortOrder).map(\.id)
        guard let id = bookmarks.presentedItemID, let index = run.firstIndex(of: id),
              run.indices.contains(index + offset) else { return }
        bookmarks.presentedItemID = run[index + offset]
    }

    private func handleDrag(_ phase: ModalDragPhase) {
        switch phase {
        case let .began(point):
            guard let item = presentedItem else { return }
            bookmarks.drag.begin(
                .init(item: item, image: content?.preview, actions: bookmarks.actions.actions(for: item)), at: point
            )
        case let .moved(point):
            bookmarks.drag.move(to: point)
        case let .ended(point):
            bookmarks.drag.end(at: point)
        case .cancelled:
            bookmarks.drag.clear()
        }
    }
}
