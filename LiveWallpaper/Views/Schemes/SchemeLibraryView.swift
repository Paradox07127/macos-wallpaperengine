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
    @State private var dragSession = LibraryDragSession()
    @AppStorage(SavedLibrarySortOrder.preferencesKey, store: .appScoped())
    private var sortOrder: SavedLibrarySortOrder = .recent

    var body: some View {
        DetailPageScaffold { content }
            .confirmDestructive($pendingDestructive)
    }

    // MARK: - Content

    /// Keep search available when no schemes match so the filter can be cleared.
    @ViewBuilder
    private var content: some View {
        if store.schemes.isEmpty {
            emptyState
        } else {
            VStack(spacing: 0) {
                filterBar
                Divider()
                gallery
            }
        }
    }

    @ViewBuilder
    private var filterBar: some View {
        if showsTypeChips {
            LibraryFilterBar(
                searchText: $searchText,
                searchPrompt: "Search schemes",
                resultCount: filteredSchemes.count,
                totalCount: store.schemes.count
            ) {
                HStack(spacing: DesignTokens.LibraryFilterBar.contentSpacing) {
                    typeChipRow
                    Spacer(minLength: 0)
                    SavedLibrarySortPicker(selection: $sortOrder)
                }
                .frame(maxWidth: .infinity)
            }
        } else {
            LibraryFilterBar(
                searchText: $searchText,
                searchPrompt: "Search schemes",
                resultCount: filteredSchemes.count,
                totalCount: store.schemes.count
            ) {
                HStack(spacing: DesignTokens.LibraryFilterBar.contentSpacing) {
                    Spacer(minLength: 0)
                    SavedLibrarySortPicker(selection: $sortOrder)
                }
                .frame(maxWidth: .infinity)
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

    @ViewBuilder
    private var gallery: some View {
        if filteredSchemes.isEmpty {
            IllustratedEmptyState(
                symbol: "magnifyingglass",
                title: "No schemes match your search"
            )
        } else {
            ScrollView {
                LazyVGrid(columns: DesignTokens.LibraryGrid.columns(for: tileSize), spacing: DesignTokens.LibraryGrid.spacing) {
                    ForEach(filteredSchemes) { scheme in
                        SchemeTile(
                            scheme: scheme,
                            screens: screenManager.screens,
                            isRenaming: renamingID == scheme.id,
                            renameDraft: $renameDraft,
                            onApply: { screen in requestApply(scheme, to: screen) },
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
                        .onDrag {
                            NSItemProvider(object: dragSession.begin(payload: scheme.id.uuidString) as NSString)
                        } preview: {
                            LibraryDragPreview(systemImage: scheme.iconName)
                        }
                    }
                }
                .padding(.horizontal, DesignTokens.Spacing.xl)
                .padding(.vertical, DesignTokens.Spacing.cardInset)
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
                          // Re-read both sides: the archive and the display list can
                          // both change while the provider read is in flight.
                          let scheme = store.schemes.first(where: { $0.id == id }),
                          let target = screenManager.screens.first(where: { $0.id == screen.id })
                    else { return }
                    requestApply(scheme, to: target)
                }
            }
        )
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

    private var showsTypeChips: Bool {
        availableTypes.count > 1
    }

    private var availableTypes: Set<WallpaperType> {
        Set(store.schemes.map(\.configuration.activeWallpaper.wallpaperType))
    }

    private var filteredSchemes: [ScreenScheme] {
        var result = store.schemes
        if showsTypeChips, case let .type(type) = typeFilter, availableTypes.contains(type) {
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
            screenManager.applyScheme(scheme, to: screen)
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
    let isRenaming: Bool
    @Binding var renameDraft: String
    let onApply: (Screen) -> Void
    let onStartRename: () -> Void
    let onCommitRename: () -> Void
    let onCancelRename: () -> Void
    let onDelete: () -> Void
    let onReplace: (Screen) -> Void

    @State private var isHovering = false
    @State private var thumbnail: NSImage?
    @State private var location = LibraryContentLocation.unknown
    @State private var showingTargets = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        thumbnailTile
            .frame(maxWidth: .infinity, alignment: .leading)
            .galleryTileChrome(isHovering: isHovering, reduceMotion: reduceMotion)
            .settledHover { isHovering = $0 }
            .popover(isPresented: $showingTargets, arrowEdge: .bottom) {
                LibraryApplyTargetList(
                    screens: screens,
                    onApply: onApply,
                    dismiss: { showingTargets = false }
                )
            }
            .help(applyHelp)
            .contextMenu { contextMenu }
            // Keyed on cover and capture time: the cover is written after capture, and replace-in-place keeps the id — without `updatedAt` an overwrite with no cover would keep the previous artwork.
            .task(id: TileContentKey(
                id: scheme.id,
                coverFileName: scheme.coverFileName,
                version: scheme.updatedAt
            )) {
                await loadTileContent()
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityActions {
                if screens.count == 1, let only = screens.first {
                    Button("Apply") { onApply(only) }
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
            // Scoped to the artwork, not the whole card: the title band carries the overflow button and a rename field that an ancestor tap would steal.
            .contentShape(Rectangle())
            .onTapGesture { applyFromCard() }
            .overlay {
                if !location.isAvailable {
                    LibraryTileUnavailableVeil()
                }
            }
            .overlay(alignment: .topLeading) {
                sourceBadge
                    .padding(DesignTokens.Spacing.sm)
            }
            .overlay(alignment: .topTrailing) {
                updatedBadge
                    .padding(DesignTokens.Spacing.sm)
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
                .font(.system(size: 30, weight: .light))
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
            Divider()
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
            Divider()
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
        if !screens.isEmpty, location.isAvailable {
            ForEach(screens, id: \.id) { screen in
                Button("Apply to \(screen.name)") { onApply(screen) }
            }
            Divider()
        }
        Button("Rename", action: onStartRename)
        if let revealURL = location.revealURL {
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([revealURL])
            }
        }
        replaceActions(dismiss: {})
        Divider()
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
        location = LibraryContentLocator.locate(
            content: scheme.configuration.activeWallpaper,
            wpeOrigin: scheme.configuration.wpeOrigin
        )
        // A scheme's cover also carries its overlay layers, which no recomputed
        // thumbnail can show — so it wins outright when one exists.
        if let coverFileName = scheme.coverFileName,
           let cover = WallpaperCoverStore.shared.cover(named: coverFileName) {
            thumbnail = cover
            return
        }
        await loadThumbnail()
    }

    @MainActor
    private func loadThumbnail() async {
        thumbnail = nil

        if let cached = WallpaperThumbnailService.shared.cachedThumbnail(forKey: cacheKey) {
            thumbnail = cached
            return
        }

        switch scheme.configuration.activeWallpaper {
        case let .video(bookmarkData, packageEntryName):
            // A packaged video resolves to a scene.pkg, which has no plain
            // poster frame; skip rather than mis-decode the package.
            guard packageEntryName == nil else { return }
            guard case let .success(resolved) = SecurityScopedBookmarkResolver.shared.resolve(
                bookmarkData,
                target: .transient
            ) else { return }
            guard !Task.isCancelled else { return }
            if let image = await WallpaperThumbnailService.shared.videoPosterImage(
                for: resolved.url,
                cacheKey: cacheKey
            ), !Task.isCancelled {
                thumbnail = image
            }
        case let .html(source, config):
            if let image = await HTMLPreviewKey.fetchSnapshot(
                for: source,
                config: config,
                cacheKey: cacheKey
            ), !Task.isCancelled {
                thumbnail = image
            }
        case .scene:
            return
        }
    }

    /// Includes the content type and the capture time: the id survives replace-in-place, so keying on it alone would serve the overwritten video's poster.
    private var cacheKey: String {
        let typeTag = switch scheme.configuration.activeWallpaper {
        case .video: "video"
        case let .html(source, config):
            "html::" + HTMLPreviewKey.key(for: source, config: config)
        case .scene: "scene"
        }
        return "scheme::\(typeTag)::\(scheme.id.uuidString)::\(scheme.updatedAt.timeIntervalSinceReferenceDate)"
    }
}
