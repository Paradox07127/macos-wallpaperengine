import LiveWallpaperCore
import SwiftUI

/// The library items picked so far, in the order they were tapped.
struct AutomationPickOrder: Equatable {
    private(set) var ids: [LibraryItem.ID] = []

    mutating func toggle(_ id: LibraryItem.ID) {
        if let index = ids.firstIndex(of: id) {
            ids.remove(at: index)
        } else {
            ids.append(id)
        }
    }

    /// 1-based; nil when the item is not picked.
    func number(of id: LibraryItem.ID) -> Int? {
        ids.firstIndex(of: id).map { $0 + 1 }
    }

    /// `unavailable` counts picks that are no longer in `items` or cannot become an entry.
    @MainActor
    static func entries(
        for ids: [LibraryItem.ID], in items: [LibraryItem]
    ) -> (entries: [WallpaperQueueEntry], unavailable: Int) {
        let entries = ids.compactMap { id in
            items.first { $0.id == id }.flatMap(WallpaperQueueEntry.libraryItem)
        }
        return (entries, ids.count - entries.count)
    }
}

struct AutomationLibraryPicker: View {
    enum Purpose {
        /// Ordered multi-pick; `inPlaylist` holds the items the playlist already plays.
        case playlist(inPlaylist: Set<LibraryItem.ID>)
        /// A tap picks and returns; `current` is the item assigned now, nil when none matches.
        case single(title: LocalizedStringKey, current: LibraryItem.ID?)
        /// Unordered multi-pick; `excluded` holds the items library shuffle skips now.
        case exclude(excluded: Set<LibraryItem.ID>)

        var title: LocalizedStringKey {
            switch self {
            case .playlist: "Add to Playlist"
            case let .single(title, _): title
            case .exclude: "Exclude from Library Shuffle"
            }
        }
    }

    let library: SavedLibraryModel
    let thumbnails: ShelfThumbnailCache
    let purpose: Purpose
    /// The panel's width in points; the tiles' decode size follows from it.
    let width: CGFloat
    /// Picked item IDs in tap order; one ID in single mode.
    let commit: ([LibraryItem.ID]) -> Void
    /// Receives the cards picked so far before the open panel appears.
    let chooseVideos: ([LibraryItem.ID]) -> Void
    let cancel: () -> Void

    @State private var order: AutomationPickOrder
    @State private var search = ""
    /// nil shows every kind.
    @State private var kindName: String?

    private static let kinds: [LibraryItem.Kind] = [.video, .web, .scene, .aerial]

    init(
        library: SavedLibraryModel, thumbnails: ShelfThumbnailCache, purpose: Purpose, width: CGFloat,
        commit: @escaping ([LibraryItem.ID]) -> Void, chooseVideos: @escaping ([LibraryItem.ID]) -> Void,
        cancel: @escaping () -> Void
    ) {
        self.library = library
        self.thumbnails = thumbnails
        self.purpose = purpose
        self.width = width
        self.commit = commit
        self.chooseVideos = chooseVideos
        self.cancel = cancel
        if case let .exclude(excluded) = purpose {
            _order = State(initialValue: AutomationPickOrder(ids: excluded.sorted()))
        } else {
            _order = State(initialValue: AutomationPickOrder())
        }
    }

    private var isOrdered: Bool {
        if case .playlist = purpose {
            return true
        }
        return false
    }

    private var isExcluding: Bool {
        if case .exclude = purpose {
            return true
        }
        return false
    }

    private func mark(for item: LibraryItem) -> AutomationPickerTile.Mark {
        switch purpose {
        case .playlist: .order(order.number(of: item.id))
        case .single: .none
        case .exclude: .check(order.ids.contains(item.id))
        }
    }

    private var presentKinds: [LibraryItem.Kind] {
        Self.kinds.filter { kind in library.items.contains { $0.kind == kind } }
    }

    private var shownItems: [LibraryItem] {
        library.items.filter { item in
            (kindName == nil || item.kind.localizedName == kindName)
                && (search.isEmpty || item.title.localizedCaseInsensitiveContains(search)
                    || item.title.translatedWallpaperName.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            LibraryToolbarRow {
                FilterChip(title: Text("All"), isSelected: kindName == nil) {
                    kindName = nil
                }
                ForEach(presentKinds, id: \.localizedName) { kind in
                    FilterChip(title: Text(verbatim: kind.localizedName), isSelected: kindName == kind.localizedName) {
                        kindName = kind.localizedName
                    }
                }
            } search: {
                LibrarySearchField(text: $search, prompt: "Search wallpapers")
            } sort: {
                EmptyView()
            } actions: {
                EmptyView()
            }
            .padding(.horizontal, DesignTokens.LibraryFilterBar.horizontalPadding)
            .padding(.vertical, DesignTokens.LibraryFilterBar.verticalPadding)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            footer
                .overlay {
                    countSummary
                        .font(DesignTokens.Typography.metric)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .allowsHitTesting(false)
                }
        }
    }

    private var countSummary: Text {
        if case .single = purpose {
            return Text("\(shownItems.count) wallpapers")
        }
        return Text("\(order.ids.count) selected") + Text(verbatim: " · ") + Text("\(shownItems.count) wallpapers")
    }

    @ViewBuilder
    private var content: some View {
        if library.items.isEmpty {
            IllustratedEmptyState(
                symbol: "photo.on.rectangle.angled",
                title: "No saved wallpapers",
                message: "Import wallpapers into the library, or choose video files below."
            )
        } else if shownItems.isEmpty {
            IllustratedEmptyState(
                symbol: "magnifyingglass",
                title: "No Results",
                primary: EmptyStateButtonAction("Clear filters") {
                    search = ""
                    kindName = nil
                }
            )
        } else {
            ScrollView {
                LibraryGalleryGrid(size: .small, aspect: .wide) {
                    ForEach(shownItems) { item in
                        AutomationPickerTile(
                            item: item,
                            thumbnail: HomePage.gridThumbnail(
                                for: item, stageWidth: width, size: .small, scale: NSScreen.main?.backingScaleFactor ?? 2
                            ),
                            thumbnails: thumbnails,
                            mark: mark(for: item),
                            badge: badge(for: item)
                        ) {
                            if isOrdered || isExcluding {
                                order.toggle(item.id)
                            } else {
                                commit([item.id])
                            }
                        }
                    }
                }
                .libraryGridPadding()
            }
        }
    }

    private func badge(for item: LibraryItem) -> LocalizedStringKey? {
        switch purpose {
        case let .playlist(inPlaylist): inPlaylist.contains(item.id) ? "In Playlist" : nil
        case let .single(_, current): current == item.id ? "Current" : nil
        case .exclude: nil
        }
    }

    @ViewBuilder
    private var footer: some View {
        if isExcluding {
            // An empty pick clears the list, so Done stays enabled.
            SheetFooterBar(
                primaryTitle: "Done",
                primaryAction: { commit(order.ids) },
                cancelTitle: "Cancel",
                cancelAction: cancel
            )
        } else if isOrdered {
            SheetFooterBar(
                primaryTitle: "Add",
                primaryAction: { commit(order.ids) },
                primaryDisabled: order.ids.isEmpty,
                cancelTitle: "Cancel",
                cancelAction: cancel,
                leading: {
                    Button("Choose Videos") { chooseVideos(order.ids) }
                }
            )
        } else {
            // A single pick commits on tap; a video file is the only other way forward.
            SheetFooterBar(
                primaryTitle: "Choose Video", primaryAction: { chooseVideos([]) },
                cancelTitle: "Cancel", cancelAction: cancel
            )
        }
    }
}

private struct AutomationPickerTile: View {
    enum Mark: Equatable {
        /// The item's 1-based pick number; nil while unpicked.
        case order(Int?)
        /// Unnumbered multi-pick; true while picked.
        case check(Bool)
        case none
    }

    private struct Load: Equatable {
        let thumbnail: LibraryGridTile.Thumbnail?
        let appearance: Int
    }

    let item: LibraryItem
    /// nil when the item has no preview to decode.
    let thumbnail: LibraryGridTile.Thumbnail?
    let thumbnails: ShelfThumbnailCache
    let mark: Mark
    let badge: LocalizedStringKey?
    let action: () -> Void

    /// Held by the tile because the shared cache can evict it while the tile is still on screen.
    @State private var loaded: (thumbnail: LibraryGridTile.Thumbnail, image: CGImage)?
    /// Bumped each time the tile comes back on screen: `tileTask` runs once per id.
    @State private var appearance = 0
    @State private var isOffScreen = false
    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var number: Int? {
        if case let .order(number) = mark {
            return number
        }
        return nil
    }

    private var isSelected: Bool {
        number != nil || mark == .check(true)
    }

    private var image: CGImage? {
        guard let thumbnail, !isOffScreen else { return nil }
        if let loaded, loaded.thumbnail == thumbnail {
            return loaded.image
        }
        return HomePage.gridImage(thumbnail, in: thumbnails)
    }

    var body: some View {
        Button(action: action) { poster }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .galleryTileChrome(isHovering: isHovering, isSelected: isSelected, reduceMotion: reduceMotion)
            .settledHover { isHovering = $0 }
            .disabled(!item.isSupported)
            .opacity(item.isSupported ? 1 : DesignTokens.Opacity.disabledContent)
            .help(Text(verbatim: item.statusBadge ?? ""))
            .onAppear {
                if isOffScreen {
                    isOffScreen = false
                    appearance += 1
                }
            }
            .onDisappear {
                isOffScreen = true
                loaded = nil
            }
            .tileTask(id: Load(thumbnail: thumbnail, appearance: appearance)) {
                guard let thumbnail,
                      let decoded = await thumbnails.image(thumbnail.request, pixelSize: thumbnail.pixelSize, scale: thumbnail.scale),
                      !Task.isCancelled else { return }
                loaded = (thumbnail, decoded)
            }
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue(number.map { Text($0, format: .number) } ?? Text(verbatim: ""))
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var accessibilityLabel: Text {
        let label = Text(verbatim: LibraryCardBadges().accessibilityLabel(title: item.title.translatedWallpaperName, kind: item.kind))
        guard let badge else { return label }
        return label + Text(verbatim: ", ") + Text(badge)
    }

    /// Artwork must stay an `overlay`: as a sibling, `scaledToFill` reports the scaled size.
    private var poster: some View {
        DesignTokens.Colors.surfaceRaised
            .overlay { artwork }
            .aspectRatio(StageGeometry.cardAspectRatio, contentMode: .fit)
            .clipped()
            .overlay(alignment: .topLeading) {
                if let badge {
                    ThumbnailBadge(badge)
                        .padding(DesignTokens.Spacing.sm)
                }
            }
            .overlay(alignment: .topTrailing) {
                if mark != Mark.none {
                    orderMark
                        .padding(DesignTokens.Spacing.sm)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottom) {
                ThumbnailTitleBand(
                    title: item.title.translatedWallpaperName,
                    isHovering: isHovering,
                    titleColor: image == nil ? DesignTokens.Colors.textPrimary : DesignTokens.Colors.overlayForeground
                ) { EmptyView() }
            }
    }

    @ViewBuilder
    private var artwork: some View {
        if let image, let thumbnail {
            Image(decorative: image, scale: thumbnail.scale)
                .resizable()
                .interpolation(.high)
                .scaledToFill()
        } else {
            Image(systemName: symbol)
                .font(DesignTokens.Glyph.videoPlaceholder)
                .foregroundStyle(DesignTokens.EditDesk.Colors.textSecondary)
        }
    }

    private var symbol: String {
        switch item.kind {
        case .video: "play.rectangle"
        case .web: "globe"
        case .scene: "cube.transparent"
        case .aerial: "sparkles"
        }
    }

    @ViewBuilder
    private var orderMark: some View {
        if let number {
            Text(number, format: .number)
                .font(DesignTokens.Typography.captionEmphasized)
                .monospacedDigit()
                .foregroundStyle(DesignTokens.Colors.overlayForeground)
                .frame(width: 22, height: 22)
                .background(DesignTokens.Colors.accent, in: Circle())
                .accessibilityHidden(true)
        } else if mark == .check(true) {
            Image(systemName: "checkmark")
                .font(DesignTokens.Typography.captionEmphasized)
                .foregroundStyle(DesignTokens.Colors.overlayForeground)
                .frame(width: 22, height: 22)
                .background(DesignTokens.Colors.accent, in: Circle())
                .accessibilityHidden(true)
        } else {
            Image(systemName: "circle")
                .font(DesignTokens.EditDesk.Typography.stageTitle)
                .foregroundStyle(DesignTokens.Colors.overlayForeground)
                .frame(width: 22, height: 22)
                .floatingGlyphGlass(hovered: isHovering, opacity: 0.72)
                .accessibilityHidden(true)
        }
    }
}
