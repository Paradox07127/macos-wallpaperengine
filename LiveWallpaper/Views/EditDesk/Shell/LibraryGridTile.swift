import LiveWallpaperCore
import SwiftUI

/// Rides the filter row on the shelf. `progress` is read here rather than in `HomePage.body` so a
/// frame of the gesture invalidates this layer alone, and the ride runs on `.offset`/`.opacity`
/// because a per-frame `.padding` would re-run the page's layout.
struct ShelfChromeRide: ViewModifier {
    let stage: EditDeskStageModel
    /// Below this the row is too faint to aim at, so it is neither clickable nor a tab stop.
    static let interactiveOpacity = 0.5

    /// Lags the shelf's own rise: the row belongs to cards that are not on screen yet.
    static func opacity(_ progress: Double) -> Double {
        HomeHints.ramp(progress, from: 0.45, to: 0.95)
    }

    func body(content: Content) -> some View {
        let opacity = Self.opacity(stage.progress)
        return content
            .padding(.horizontal, DesignTokens.EditDesk.Spacing.gutter)
            .frame(maxHeight: .infinity, alignment: .top)
            .offset(y: StageGeometry.chipRowTop(progress: stage.progress, windowSize: stage.stageSize))
            .opacity(opacity)
            .allowsHitTesting(opacity > Self.interactiveOpacity)
            .accessibilityHidden(opacity <= Self.interactiveOpacity)
    }
}

/// The name rides over the card the pointer is on: inside the thumbnail the card to the right
/// covers all but the near edge. Its own view, like `ShelfChromeRide`, so a gesture frame invalidates it alone.
struct HoverCardName: View {
    let stage: EditDeskStageModel
    let library: SavedLibraryModel?
    let enabled: Bool

    private var caption: String? {
        guard let id = stage.hoveredCard, let item = library?.items.first(where: { $0.id == id }) else { return nil }
        return item.title.translatedWallpaperName + " · " + item.kind.localizedName
    }

    var body: some View {
        ZStack {
            if enabled, stage.progress < 1.5, let caption, let rect = stage.hoveredCardRect, stage.showsShelf {
                Text(verbatim: caption)
                    .font(DesignTokens.Typography.captionEmphasized)
                    .foregroundStyle(DesignTokens.EditDesk.Colors.textPrimary)
                    .lineLimit(1)
                    .padding(.horizontal, DesignTokens.EditDesk.Spacing.s8)
                    .padding(.vertical, 4)
                    .background(DesignTokens.EditDesk.Colors.panel, in: Capsule())
                    .fixedSize()
                    .position(x: rect.midX, y: rect.minY - 16)
                    .id(stage.hoveredCard)
                    .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
        // Keyed on the card, not the rect: the rect moves every gesture frame and must not lag.
        .animation(DesignTokens.Motion.feedback, value: stage.hoveredCard)
    }
}

/// Full-library tile at p = 2. Thumbnails come from `ShelfThumbnailCache` like the shelf cards.
struct LibraryGridTile: View {
    /// The item's preview at the tile's own size in backing pixels.
    struct Thumbnail: Equatable {
        let request: ShelfThumbnailCache.Request
        let pixelSize: CGSize
        let scale: CGFloat

        init(_ request: ShelfThumbnailCache.Request, tileWidth: CGFloat, scale: CGFloat) {
            // Rounded up to 64px, or a live resize would key a new decode for every tile on every frame.
            let width = (tileWidth * scale / 64).rounded(.up) * 64
            self.request = request
            pixelSize = CGSize(width: width, height: (width / StageGeometry.cardAspectRatio).rounded())
            self.scale = scale
        }
    }

    private struct Load: Equatable {
        let thumbnail: Thumbnail?
        let appearance: Int
    }

    let item: LibraryItem
    /// nil when the item has no preview to decode.
    let thumbnail: Thumbnail?
    let thumbnails: ShelfThumbnailCache
    let badges: LibraryCardBadges
    /// nil for a tile that never plays its preview.
    var preview: LibraryGridPreview?
    /// Held by the tile because the shared cache can evict it while the tile is still on screen.
    @State private var loaded: (thumbnail: Thumbnail, image: CGImage)?
    /// Bumped each time the tile comes back on screen: `tileTask` runs once per id, so that appearance loads again.
    @State private var appearance = 0
    /// Without it the cache fallback below would redraw the image into the off-screen body LazyVGrid keeps.
    @State private var isOffScreen = false
    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    private var image: CGImage? {
        guard let thumbnail, !isOffScreen else { return nil }
        if let loaded, loaded.thumbnail == thumbnail {
            return loaded.image
        }
        return HomePage.gridImage(thumbnail, in: thumbnails)
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // An overlay, not a ZStack sibling: `scaledToFill` reports the picture's own proportions, which would size the tile.
            DesignTokens.Colors.surfaceRaised
                .overlay {
                    if let image, let thumbnail {
                        LibraryGridTilePicture(poster: image, id: item.id, thumbnail: thumbnail, preview: preview)
                    } else {
                        Image(systemName: item.kind == .web ? "globe" : item.kind == .scene ? "cube.transparent" : item.kind == .aerial ? "sparkles" : "play.rectangle")
                            .foregroundStyle(DesignTokens.EditDesk.Colors.textSecondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            if item.statusBadge != nil {
                LibraryTileUnavailableVeil()
            }
            LinearGradient(
                colors: [.clear, DesignTokens.EditDesk.Colors.gradientCardBottom],
                startPoint: .center, endPoint: .bottom
            )
            Group {
                RoundedRectangle(cornerRadius: DesignTokens.Corner.lg, style: .continuous)
                    .strokeBorder(
                        contrast == .increased
                            ? DesignTokens.EditDesk.Colors.cardRimRingIncreased : DesignTokens.EditDesk.Colors.cardRimRing,
                        lineWidth: 1
                    )
                VStack(spacing: 0) {
                    Rectangle().fill(DesignTokens.EditDesk.Colors.cardRimHighlight).frame(height: 1)
                    Spacer(minLength: 0)
                    Rectangle().fill(DesignTokens.EditDesk.Colors.cardRimShade).frame(height: 1)
                }
            }
            .allowsHitTesting(false)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: item.title.translatedWallpaperName)
                    .font(DesignTokens.EditDesk.Typography.cardTitle)
                    .foregroundStyle(DesignTokens.Colors.overlayForeground)
                    .lineLimit(1)
                    .wpeAuthorLabelHelp(item.title.wallpaperNameHelp)
                if let status = item.statusBadge {
                    Text(verbatim: status)
                        .font(DesignTokens.EditDesk.Typography.metaMono)
                        .foregroundStyle(DesignTokens.EditDesk.Colors.warning)
                        .lineLimit(1)
                }
            }
            .padding(DesignTokens.EditDesk.Spacing.s8)
        }
        .overlay(alignment: .topLeading) {
            if let nowPlaying = badges.nowPlaying {
                NowPlayingCapsule(badge: nowPlaying, animates: nowPlaying.isLive)
                    .padding(DesignTokens.EditDesk.Spacing.s8)
            }
        }
        .overlay(alignment: .topTrailing) {
            let isBookmarked = LibraryBookmarkStore.shared.contains(item.id)
            HStack(spacing: DesignTokens.Spacing.xs) {
                if badges.needsUpdate {
                    ThumbnailBadge("Needs Update", systemImage: "arrow.down.circle", tint: DesignTokens.Colors.Status.warning, opacity: 0.9)
                }
                if isBookmarked || isHovering {
                    TileMarkBadge(mark: .bookmark, isOn: isBookmarked) { LibraryBookmarkStore.shared.toggle(item.id) }
                }
            }
            .padding(DesignTokens.EditDesk.Spacing.s8)
        }
        .aspectRatio(StageGeometry.cardAspectRatio, contentMode: .fit)
        .galleryTileChrome(isHovering: isHovering, reduceMotion: reduceMotion)
        .settledHover {
            isHovering = $0
            preview?.settle(item.id, hovering: $0)
        }
        .accessibilityLabel(Text(verbatim: item.title.translatedWallpaperName))
        .wpeTranslateWallpaperName(item.title, persist: true)
        // LazyVGrid may keep a scrolled-away tile alive, and any image the tile holds with it.
        .onAppear {
            // Bumped on the way back rather than on the way out, so the id never changes off screen.
            if isOffScreen {
                isOffScreen = false
                appearance += 1
            }
        }
        .onDisappear {
            isOffScreen = true
            loaded = nil
            // A tile searched out from under the pointer gets no hover exit.
            preview?.settle(item.id, hovering: false)
        }
        .tileTask(id: Load(thumbnail: thumbnail, appearance: appearance)) {
            guard let thumbnail,
                  let decoded = await thumbnails.image(thumbnail.request, pixelSize: thumbnail.pixelSize, scale: thumbnail.scale),
                  !Task.isCancelled else { return }
            loaded = (thumbnail, decoded)
        }
    }
}
