import AppKit
import LiveWallpaperCore
import SwiftUI

/// Library of saved whole-display setups. Deliberately the same shape as the
/// Bookmarks library — scaffold, filter bar, gallery grid — because a scheme is
/// another archived thing you apply to a display; only the payload differs.
struct SchemeLibraryView: View {
    @Environment(ScreenManager.self) private var screenManager
    @State private var store = SchemeStore.shared
    @State private var renamingID: UUID?
    @State private var renameDraft: String = ""
    @State private var searchText: String = ""
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
            systemImage: "square.stack.3d.up.fill",
            title: { Text("Schemes") },
            metadata: {
                Text("\(store.schemes.count) saved setups")
            },
            actions: { EmptyView() }
        )
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if store.schemes.isEmpty {
            emptyState
        } else {
            VStack(spacing: 0) {
                LibraryFilterBar(
                    searchText: $searchText,
                    searchPrompt: "Search schemes",
                    resultCount: filteredSchemes.count,
                    totalCount: store.schemes.count
                )
                gallery
            }
        }
    }

    @ViewBuilder
    private var gallery: some View {
        if filteredSchemes.isEmpty {
            IllustratedEmptyState(
                symbol: "magnifyingglass",
                title: "No schemes match your search",
                message: "Try a different keyword, or clear the search field to see every saved scheme."
            )
        } else {
            ScrollView {
                LazyVGrid(columns: DesignTokens.LibraryGrid.columns, spacing: DesignTokens.LibraryGrid.spacing) {
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
                            }
                        )
                    }
                }
                .padding(.horizontal, DesignTokens.Spacing.xl)
                .padding(.vertical, DesignTokens.Spacing.cardInset)
            }
        }
    }

    private var emptyState: some View {
        IllustratedEmptyState(
            symbol: "square.stack.3d.up",
            title: "No schemes yet",
            message: "Open a display, set it up the way you like, then use Save as Scheme in its header. Saved setups land here and can be applied to any display."
        )
    }

    // MARK: - Filtering

    private var filteredSchemes: [ScreenScheme] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return store.schemes }
        return store.schemes.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed)
                || ($0.sourceDisplayName?.localizedCaseInsensitiveContains(trimmed) ?? false)
        }
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

    @State private var isHovering = false
    @State private var thumbnail: NSImage?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        thumbnailTile
            .frame(maxWidth: .infinity, alignment: .leading)
            .galleryTileChrome(isHovering: isHovering, reduceMotion: reduceMotion)
            .settledHover { isHovering = $0 }
            .contextMenu { contextMenu }
            .task(id: scheme.id) { await loadThumbnail() }
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

    /// Poster as an `overlay` rather than a ZStack sibling, for the reason
    /// spelled out on `BookmarkTile`: `scaledToFill` reports the *scaled* size,
    /// which grows the tile into the thumbnail's own aspect ratio.
    private var thumbnailTile: some View {
        tileBackground
            .overlay { tileContent }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .clipped()
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

    /// Renaming takes the band's place rather than sitting inside it — same
    /// trade as `BookmarkTile`: the field is a full-height control, the band is
    /// one line of type.
    @ViewBuilder
    private var bottomBand: some View {
        if isRenaming {
            renameField
                .padding(DesignTokens.Spacing.sm)
                .adaptiveGlassSurface(.roundedRectangle(0), stroked: false)
        } else {
            ThumbnailTitleBand(title: scheme.name, isHovering: isHovering) {
                LibraryTileApplyControl(screens: screens, tint: tint, onApply: onApply)
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

    /// A real `Button` + popover, never a `Menu`: an AppKit popup paints its
    /// label in the system control colour, which is invisible over artwork.
    private var overflowButton: some View {
        SchemeOverflowButton(onStartRename: onStartRename, onDelete: onDelete)
    }

    @ViewBuilder
    private var contextMenu: some View {
        if !screens.isEmpty {
            ForEach(screens, id: \.id) { screen in
                Button("Apply to \(screen.name)") { onApply(screen) }
            }
            Divider()
        }
        Button("Rename", action: onStartRename)
        Button("Delete", role: .destructive, action: onDelete)
    }

    // MARK: Presentation

    private var tint: Color {
        switch scheme.configuration.activeWallpaper {
        case .video: DesignTokens.Colors.ContentType.video
        case .html: DesignTokens.Colors.ContentType.html
        case .scene: DesignTokens.Colors.ContentType.scene
        }
    }

    private var iconName: String {
        switch scheme.configuration.activeWallpaper {
        case .video: "play.rectangle"
        case let .html(source, _): source.iconName
        case .scene: "cube.transparent"
        }
    }

    // MARK: Thumbnail loader

    /// Run via `.task(id:)` so SwiftUI cancels the decode + security-scoped
    /// resolve when the tile leaves the viewport on fast-scroll.
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

    /// Includes the content type so a thumbnail cached for one kind can never be
    /// served for another if the scheme is re-captured onto the same id.
    private var cacheKey: String {
        let typeTag = switch scheme.configuration.activeWallpaper {
        case .video: "video"
        case let .html(source, config):
            "html::" + HTMLPreviewKey.key(for: source, config: config)
        case .scene: "scene"
        }
        return "scheme::\(typeTag)::\(scheme.id.uuidString)"
    }
}

// MARK: - Tile controls

/// Apply glyph for a scheme tile: straight apply on a single display, a target
/// picker on more. Deliberately without `LibraryTileApplyControl`'s "Apply to
/// All Displays" entry — a scheme overwrites a display's whole setup, and
/// broadcasting that is a separate product decision nobody has made yet.
private struct SchemeOverflowButton: View {
    let onStartRename: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false
    @State private var showingActions = false

    var body: some View {
        Button { showingActions = true } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DesignTokens.Colors.overlayForeground)
                .frame(width: 22, height: 22)
                .floatingGlyphGlass(hovered: isHovering)
                .onHover { isHovering = $0 }
        }
        .buttonStyle(.plain)
        .help(Text("More actions"))
        .accessibilityLabel(Text("More actions"))
        .popover(isPresented: $showingActions, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                Button("Rename") {
                    showingActions = false
                    onStartRename()
                }
                Divider()
                Button("Delete", role: .destructive) {
                    showingActions = false
                    onDelete()
                }
                .destructiveControlTint()
            }
            .buttonStyle(.borderless)
            .frame(maxWidth: .infinity, alignment: .leading)
            .settingsPopoverChrome(width: 180)
        }
    }
}
