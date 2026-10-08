import AppKit
import LiveWallpaperCore
import SwiftUI

struct SchemeLibraryView: View {
    @Environment(\.libraryTileSize) private var tileSize
    @Environment(ScreenManager.self) private var screenManager
    @State private var store = SchemeStore.shared
    @State private var renamingID: UUID?
    @State private var renameDraft: String = ""
    @State private var searchText: String = ""
    @State private var typeFilter: SchemeTypeFilter = .all
    @State private var pendingDestructive: PendingDestructive?
    @AppStorage("loomscreen.savedLibrary.sortOrder.v1", store: .appScoped())
    private var sortRaw = "recent"
    /// Drives the host page's display strip; a tile's drop ends in `requestApply`.
    private let drag: LibraryDragController
    /// The host page's detail modal: a tile's click opens it, and its apply buttons end in `requestApply`.
    private let details: SchemeDetailPresenter
    /// The Edit Desk apply path records the change for undo.
    private let apply: (ScreenScheme, Screen) -> Void

    init(drag: LibraryDragController, details: SchemeDetailPresenter, apply: @escaping (ScreenScheme, Screen) -> Void) {
        self.drag = drag
        self.details = details
        self.apply = apply
    }

    var body: some View {
        let types = availableTypes
        let visible = filteredSchemes(availableTypes: types)
        content(visible: visible, availableTypes: types)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .confirmDestructive($pendingDestructive)
            .onAppear { details.requestApply = { requestApply($0, to: $1) } }
            // The presenter outlives this view on the page's @State; a kept closure would retain the view.
            .onDisappear { details.requestApply = { _, _ in } }
            .onChange(of: visible, initial: true) { details.run = $1 }
    }

    // MARK: - Content

    /// Keep search available when no schemes match so the filter can be cleared.
    @ViewBuilder
    private func content(visible: [ScreenScheme], availableTypes: Set<WallpaperType>) -> some View {
        if store.schemes.isEmpty {
            emptyState
        } else {
            VStack(spacing: 0) {
                filterBar(availableTypes: availableTypes)
                gallery(visible)
                LibraryStatusBar(summary: statusSummary(shown: visible.count))
            }
        }
    }

    private func filterBar(availableTypes: Set<WallpaperType>) -> some View {
        LibraryToolbarRow {
            if availableTypes.count > 1 {
                typeChipRow(availableTypes: availableTypes)
            }
        } search: {
            LibrarySearchField(text: $searchText, prompt: "Search schemes")
        } sort: {
            LibrarySortControl(label: Text(Self.sortTitle(sortOrder))) {
                Picker("Sort", selection: Binding(
                    get: { sortOrder },
                    set: { sortOrder = $0 }
                )) {
                    ForEach([SavedLibraryModel.Sort.recentlyUsed, .name, .type], id: \.self) { order in
                        Text(Self.sortTitle(order)).tag(order)
                    }
                }
                .labelsHidden()
                .pickerStyle(.inline)
            }
        } actions: {
            EmptyView()
        }
        .padding(.horizontal, DesignTokens.LibraryFilterBar.horizontalPadding)
        .padding(.vertical, DesignTokens.LibraryFilterBar.verticalPadding)
    }

    /// Schemes sort by last capture and applying one records no use, so the date order is not "Recently Used".
    static func sortTitle(_ order: SavedLibraryModel.Sort) -> LocalizedStringKey {
        order == .recentlyUsed ? "Recent" : LibraryChipsRow.sortTitle(order)
    }

    private var sortOrder: SavedLibraryModel.Sort {
        get {
            switch sortRaw {
            case "name": .name
            case "type": .type
            default: .recentlyUsed
            }
        }
        nonmutating set {
            switch newValue {
            case .name: sortRaw = "name"
            case .type: sortRaw = "type"
            default: sortRaw = "recent"
            }
        }
    }

    private func statusSummary(shown: Int) -> Text {
        let total = store.schemes.count
        return shown == total
            ? Text("\(total) schemes")
            : Text("\(shown) of \(total) shown")
    }

    private func typeChipRow(availableTypes: Set<WallpaperType>) -> some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
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

    @ViewBuilder
    private func gallery(_ visible: [ScreenScheme]) -> some View {
        if visible.isEmpty {
            IllustratedEmptyState(
                symbol: "magnifyingglass",
                title: "No Results",
                primary: EmptyStateButtonAction("Clear filters") {
                    searchText = ""
                    typeFilter = .all
                }
            )
        } else {
            ScrollView {
                LibraryGalleryGrid(size: tileSize, aspect: .wide) {
                    ForEach(visible) { scheme in
                        SchemeTile(
                            scheme: scheme,
                            screens: screenManager.screens,
                            drag: drag,
                            isRenaming: renamingID == scheme.id,
                            renameDraft: $renameDraft,
                            onApply: { screen in requestApply(scheme, to: screen) },
                            onOpen: { details.presentedID = scheme.id },
                            onStartRename: {
                                renamingID = scheme.id
                                renameDraft = scheme.name
                            },
                            onCommitRename: {
                                store.rename(scheme.id, to: renameDraft)
                                renamingID = nil
                            },
                            onCancelRename: { renamingID = nil },
                            onDelete: {
                                pendingDestructive = PendingDestructive(
                                    .deleteScheme(schemeName: scheme.name)
                                ) { store.remove(scheme.id) }
                            },
                            onReplace: { screen in requestReplace(scheme, from: screen) }
                        )
                    }
                }
                .libraryGridPadding()
            }
        }
    }

    private var emptyState: some View {
        LibraryGuideCard(
            icon: "square.stack.3d.up",
            tint: DesignTokens.Colors.LibraryTint.schemes,
            title: "No schemes yet",
            message: "Use Save as Scheme in display details to capture a display's wallpaper, overlays, and settings together. Applying one replaces all of them."
        )
    }

    // MARK: - Filtering

    private var availableTypes: Set<WallpaperType> {
        Set(store.schemes.map(\.configuration.activeWallpaper.wallpaperType))
    }

    private func filteredSchemes(availableTypes: Set<WallpaperType>) -> [ScreenScheme] {
        var result = store.schemes
        if availableTypes.count > 1, case let .type(type) = typeFilter, availableTypes.contains(type) {
            result = result.filter { $0.configuration.activeWallpaper.wallpaperType == type }
        }
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            result = result.filter {
                $0.name.localizedCaseInsensitiveContains(trimmed)
                    || ($0.sourceDisplayName?.localizedCaseInsensitiveContains(trimmed) ?? false)
            }
        }
        return sortOrder.sorted(
            result,
            name: \.name,
            // A scheme's "recent" is its last capture, not its creation: the
            // whole point of replace-in-place is that the slot was just redone.
            date: \.updatedAt,
            type: \.configuration.activeWallpaper.wallpaperType
        )
    }

    // MARK: - Apply

    /// Whole-display overwrite, so it always goes through the confirmation.
    private func requestApply(_ scheme: ScreenScheme, to screen: Screen) {
        pendingDestructive = PendingDestructive(
            .applyScheme(schemeName: scheme.name, displayName: screen.name)
        ) {
            apply(scheme, screen)
        }
    }

    /// The display overwrites this scheme; one display can hold several, so this replaces the one you picked rather than "the" scheme for that display.
    private func requestReplace(_ scheme: ScreenScheme, from screen: Screen) {
        pendingDestructive = PendingDestructive(
            .replaceScheme(schemeName: scheme.name, displayName: screen.name)
        ) {
            screenManager.recaptureScheme(scheme, from: screen)
        }
    }
}

// MARK: - Type filter

private enum SchemeTypeFilter: Hashable {
    case all
    case type(WallpaperType)
}

// MARK: - Tile

private struct SchemeTile: View {
    let scheme: ScreenScheme
    let screens: [Screen]
    let drag: LibraryDragController
    let isRenaming: Bool
    @Binding var renameDraft: String
    /// Only the drag applies from the tile; a click opens the details.
    let onApply: (Screen) -> Void
    let onOpen: () -> Void
    let onStartRename: () -> Void
    let onCommitRename: () -> Void
    let onCancelRename: () -> Void
    let onDelete: () -> Void
    let onReplace: (Screen) -> Void

    @State private var isHovering = false
    @State private var thumbnail: NSImage?
    @State private var location = LibraryContentLocation.unknown
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        thumbnailTile
            .frame(maxWidth: .infinity, alignment: .leading)
            .galleryTileChrome(isHovering: isHovering, reduceMotion: reduceMotion)
            .settledHover { isHovering = $0 }
            .libraryDragSource(drag, enabled: location.isAvailable && !isRenaming) { dragPayload }
            .help(openHelp)
            .contextMenu { contextMenu }
            // Keyed on cover and capture time: the cover is written after capture, and replace-in-place keeps the id — without `updatedAt` an overwrite with no cover would keep the previous artwork.
            .tileTask(id: TileContentKey(
                id: scheme.id,
                coverFileName: scheme.coverFileName,
                version: scheme.updatedAt
            )) {
                await loadTileContent()
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(Text("Show details"))
            .accessibilityAction(.default, openDetails)
            .accessibilityActions {
                Button("Rename", action: onStartRename)
            }
            .accessibilityAction(.delete, onDelete)
    }

    private var openHelp: Text {
        location.isAvailable
            ? Text("Show details")
            : Text("This wallpaper's file is missing")
    }

    /// A tile being renamed keeps its clicks for the name field.
    private func openDetails() {
        guard !isRenaming else { return }
        onOpen()
    }

    /// A scheme overwrites one whole display, so its drag offers no All Displays drop.
    private var dragPayload: LibraryDragController.Payload {
        LibraryDragController.Payload(
            item: nil,
            image: thumbnail?.cgImage(forProposedRect: nil, context: nil, hints: nil),
            applyTo: { id in
                if let screen = screens.first(where: { $0.id == id }) {
                    onApply(screen)
                }
            },
            applyToAllDisplays: nil
        )
    }

    private var accessibilityLabel: Text {
        if let source = scheme.sourceDisplayName, !source.isEmpty {
            return Text(
                "\(scheme.name), display scheme captured from \(source)",
                comment: "Scheme tile accessibility label. %1$@ is the scheme name, %2$@ is the display it was captured from."
            )
        }
        return Text(
            "\(scheme.name), saved display scheme",
            comment: "Scheme tile accessibility label when no source display was recorded. %@ is the scheme name."
        )
    }

    // MARK: Thumbnail tile

    /// An overlay keeps scaled-to-fill artwork from changing the tile’s aspect ratio.
    private var thumbnailTile: some View {
        tileBackground
            .overlay { tileContent }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .clipped()
            .contentShape(Rectangle())
            .onTapGesture(perform: openDetails)
            .overlay {
                if !location.isAvailable {
                    LibraryTileUnavailableVeil()
                }
            }
            .overlay(alignment: .topLeading) {
                sourceBadge
                    .padding(DesignTokens.Spacing.sm)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .topTrailing) {
                updatedBadge
                    .padding(DesignTokens.Spacing.sm)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottom) { bottomBand }
    }

    private var tileBackground: some View {
        Rectangle()
            .fill(tint.opacity(0.12))
    }

    @ViewBuilder
    private var tileContent: some View {
        if let thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .interpolation(.high)
                .scaledToFill()
        } else {
            Image(systemName: iconName)
                .font(DesignTokens.Glyph.schemePlaceholder)
                .foregroundStyle(tint.opacity(0.85))
        }
    }

    @ViewBuilder
    private var sourceBadge: some View {
        if let source = scheme.sourceDisplayName, !source.isEmpty {
            ThumbnailBadge(verbatim: source, systemImage: "display")
        }
    }

    private var updatedBadge: some View {
        ThumbnailBadge(
            verbatim: scheme.updatedAt.formatted(date: .abbreviated, time: .omitted),
            systemImage: "clock"
        )
    }

    @ViewBuilder
    private var bottomBand: some View {
        if isRenaming {
            renameField
                .padding(DesignTokens.Spacing.sm)
                .adaptiveGlassSurface(.roundedRectangle(0), stroked: false)
        } else {
            ThumbnailTitleBand(title: scheme.name, isHovering: isHovering) {
                overflowButton
            }
        }
    }

    private var renameField: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            TextField("Name", text: $renameDraft)
                .textFieldStyle(.roundedBorder)
                .font(DesignTokens.Typography.body)
                .onSubmit(onCommitRename)
                .onExitCommand(perform: onCancelRename)
            Button(action: onCommitRename) {
                Image(systemName: "checkmark.circle.fill")
                    .font(DesignTokens.EditDesk.Typography.body)
                    .foregroundStyle(.tint)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.defaultAction)
            .help(Text("Save"))
            Button(action: onCancelRename) {
                Image(systemName: "xmark.circle.fill")
                    .font(DesignTokens.EditDesk.Typography.body)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help(Text("Cancel"))
        }
    }

    // MARK: Overflow

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
            replaceActions(dismiss: dismiss)
            Button("Delete", role: .destructive) {
                dismiss()
                onDelete()
            }
            .destructiveControlTint()
        }
    }

    @ViewBuilder
    private func replaceActions(dismiss: @escaping () -> Void) -> some View {
        if !screens.isEmpty {
            ForEach(screens, id: \.id) { screen in
                Button {
                    dismiss()
                    onReplace(screen)
                } label: {
                    screens.count == 1
                        ? Text("Replace with Current Setup")
                        : Text("Replace with \(screen.name)")
                }
            }
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button("Rename", action: onStartRename)
        if let revealURL = location.revealURL {
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([revealURL])
            }
        }
        replaceActions(dismiss: {})
        Button("Delete", role: .destructive, action: onDelete)
    }

    // MARK: Presentation

    private var tint: Color {
        scheme.presentationTint
    }

    private var iconName: String {
        scheme.iconName
    }

    // MARK: Thumbnail loader

    @MainActor
    private func loadTileContent() async {
        thumbnail = nil
        let resolvedLocation = await SchemeArtwork.location(for: scheme)
        guard !Task.isCancelled else { return }
        location = resolvedLocation
        let image = await SchemeArtwork.image(for: scheme)
        guard !Task.isCancelled else { return }
        thumbnail = image
    }
}

// MARK: - Artwork

/// A scheme's still and whether its content is still there; the tile and the detail modal show the same.
@MainActor
enum SchemeArtwork {
    static func location(for scheme: ScreenScheme) async -> LibraryContentLocation {
        await LibraryContentLocator.locate(
            content: scheme.configuration.activeWallpaper,
            wpeOrigin: scheme.configuration.wpeOrigin
        )
    }

    static func image(for scheme: ScreenScheme) async -> NSImage? {
        // A scheme's cover also carries its overlay layers, which no recomputed
        // thumbnail can show — so it wins outright when one exists.
        if let coverFileName = scheme.coverFileName,
           let cover = await WallpaperCoverStore.shared.cover(named: coverFileName) {
            return cover
        }
        guard !Task.isCancelled else { return nil }
        return await thumbnail(for: scheme)
    }

    private static func thumbnail(for scheme: ScreenScheme) async -> NSImage? {
        let cacheKey = cacheKey(for: scheme)
        if let cached = WallpaperThumbnailService.shared.cachedThumbnail(forKey: cacheKey) {
            return cached
        }

        switch scheme.configuration.activeWallpaper {
        case let .video(bookmarkData, packageEntryName):
            // A packaged video resolves to a scene.pkg, which has no plain
            // poster frame; skip rather than mis-decode the package.
            guard packageEntryName == nil else { return nil }
            guard let resolved = await LibraryContentLocator.resolvePreviewBookmark(bookmarkData) else { return nil }
            guard !Task.isCancelled else { return nil }
            return await WallpaperThumbnailService.shared.videoPosterImage(
                for: resolved.url,
                cacheKey: cacheKey
            )
        case let .html(source, config):
            return await HTMLPreviewKey.fetchSnapshot(
                for: source,
                config: config,
                cacheKey: cacheKey
            )
        case .scene:
            return nil
        }
    }

    /// Includes the content type and the capture time: the id survives replace-in-place, so keying on it alone would serve the overwritten video's poster.
    private static func cacheKey(for scheme: ScreenScheme) -> String {
        let typeTag = switch scheme.configuration.activeWallpaper {
        case .video: "video"
        case let .html(source, config):
            "html::" + HTMLPreviewKey.key(for: source, config: config)
        case .scene: "scene"
        }
        return "scheme::\(typeTag)::\(scheme.id.uuidString)::\(scheme.updatedAt.timeIntervalSinceReferenceDate)"
    }
}

extension SavedLibraryModel.Sort {
    /// `date` is whatever "recent" means for the entry kind — creation for a bookmark, last capture for a scheme.
    func sorted<Element>(
        _ elements: [Element],
        name: (Element) -> String,
        date: (Element) -> Date,
        type: (Element) -> WallpaperType
    ) -> [Element] {
        switch self {
        case .recentlyUsed, .size:
            elements.sorted { date($0) > date($1) }
        case .name:
            elements.sorted { name($0).localizedStandardCompare(name($1)) == .orderedAscending }
        case .type:
            elements.sorted { lhs, rhs in
                let lhsType = type(lhs), rhsType = type(rhs)
                if lhsType != rhsType {
                    return lhsType.rawValue < rhsType.rawValue
                }
                return name(lhs).localizedStandardCompare(name(rhs)) == .orderedAscending
            }
        #if !LITE_BUILD
        case .needsUpdate:
            elements.sorted { date($0) > date($1) }
        #endif
        }
    }
}
