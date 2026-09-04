import AppKit
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import SwiftUI
import Testing

/// Ablation bench for the Workshop browse grid's scroll cost.
///
/// It does NOT measure frame time — it measures what a `LazyVGrid` pays every
/// time a card scrolls into view: constructing the SwiftUI subtree and laying it
/// out. `LazyVGrid` does not recycle views (unlike the `NSCollectionView` the
/// nearest competitor moved to), so this construct+layout cost is paid per cell
/// per appearance, which is the mechanism behind the jank.
///
/// Read the numbers as ratios between rows, never as absolute milliseconds:
/// the app host is a Debug build unless the run passes `-configuration Release`,
/// and an unoptimised stack fingerprint misattributes cost.
@MainActor
@Suite("Browse card layout cost", .serialized)
struct BrowseCardLayoutCostTests {
    /// One screenful at the default tile size, which is what a scroll actually
    /// materialises at a time.
    private static let cardCount = 50
    private static let gridWidth: CGFloat = 1200
    /// Enough passes that a single scheduling hiccup cannot carry a row.
    private static let iterations = 5

    private func makeItems(_ count: Int) -> [WorkshopQueryItem] {
        (0 ..< count).map { index in
            WorkshopQueryItem(
                id: UInt64(1_000_000 + index),
                title: "Wallpaper \(index)",
                shortDescription: "A description long enough to wrap onto a second line.",
                creatorID: "7656119800000000",
                creatorPersonaName: "Creator \(index % 7)",
                // nil: the bench isolates view cost, not the image pipeline —
                // a real URL would make every row wait on the network.
                previewImageURL: nil,
                fileSizeBytes: UInt64(12_345_678 + index),
                timeUpdated: Date(timeIntervalSince1970: 1_760_000_000),
                subscriptionCount: 1234 + index,
                voteScore: 0.9,
                tags: index.isMultiple(of: 2) ? ["Scene", "Anime"] : ["Video"],
                visibility: .public,
                isBanned: false,
                steamCommunityURL: URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(1_000_000 + index)")!
            )
        }
    }

    /// Which layers this row keeps. Each `false` is one ablation.
    private struct Variant {
        var name: String
        var contextMenu = true
        var chrome = true
        var thumbnail = true
        var badges = true
        /// Whether the thumbnail branch gets the same `aspectRatio(1, .fit)` the
        /// placeholder branch always had.
        var squareConstraint = true
        /// `AdaptiveGlassContainer` wraps the badges in the system's glass
        /// coordination container on macOS 26+ and never consults
        /// `thumbnailBadgeSurface`. Inside a gallery card its badges are already
        /// `.opaque`, so it has nothing left to coordinate — measured free (+1%),
        /// which is why the wrapper stays.
        var glassContainer = true
        /// What a user actually gets from the badge toggles: the pills vanish
        /// but `BrowseCard` still builds the container, its `HStack` and the
        /// padding, because only the pills sit behind the `if`s.
        var pills = true
        /// `GalleryTileChrome` starts with `.thumbnailBadgeSurface(.opaque)`, so
        /// ablating the chrome silently un-ablates opaque badges — 100 real
        /// `glassEffect` surfaces reappear and the row reads as "chrome is free".
        /// Kept separate so the two effects can be told apart.
        var opaqueBadges = true
    }

    /// Rebuilds the card's shape layer by layer. It deliberately mirrors
    /// `BrowseCard.body` rather than calling it: the point is to remove one
    /// layer at a time, which a single opaque view cannot do.
    @ViewBuilder
    private func card(_ item: WorkshopQueryItem, _ variant: Variant, reduceMotion: Bool) -> some View {
        let base = Button {} label: {
            Group {
                if variant.thumbnail {
                    AnimatedGIFThumbnail(
                        url: item.previewImageURL,
                        playbackMode: .hoverToPlay,
                        showsPlayingBadge: false,
                        isBlurred: false,
                        isHovered: .constant(false)
                    )
                    // The Rectangle branch carried this and the component did
                    // not, so the row that looked like "the thumbnail costs 48%"
                    // was really "an unconstrained tile height costs 48%".
                    .modifier(OptionalSquare(enabled: variant.squareConstraint))
                } else {
                    Rectangle().fill(Color.secondary.opacity(0.12)).aspectRatio(1, contentMode: .fit)
                }
            }
            .overlay(alignment: .topLeading) {
                // Mirrors the shipped gate: with both pills off the container,
                // its stack and the padding are not built at all.
                if variant.badges, variant.pills {
                    Group {
                        if variant.glassContainer {
                            AdaptiveGlassContainer(spacing: DesignTokens.Spacing.xs) {
                                HStack(spacing: DesignTokens.Spacing.xs) {
                                    ThumbnailBadge(verbatim: "Scene")
                                    ThumbnailBadge(verbatim: "4.5")
                                }
                            }
                        } else {
                            HStack(spacing: DesignTokens.Spacing.xs) {
                                ThumbnailBadge(verbatim: "Scene")
                                ThumbnailBadge(verbatim: "4.5")
                            }
                        }
                    }
                    .padding(DesignTokens.Spacing.sm)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)

        Group {
            if variant.chrome {
                base.galleryTileChrome(
                    isHovering: false,
                    isSelected: false,
                    cornerRadius: DesignTokens.Corner.lg,
                    reduceMotion: reduceMotion
                )
            } else {
                base
            }
        }
        .modifier(OptionalContextMenu(enabled: variant.contextMenu, item: item))
        .modifier(OptionalOpaqueBadges(enabled: variant.opaqueBadges && !variant.chrome))
    }

    /// Re-applies only the badge-surface half of the chrome.
    private struct OptionalOpaqueBadges: ViewModifier {
        let enabled: Bool

        func body(content: Content) -> some View {
            if enabled {
                content.thumbnailBadgeSurface(.opaque)
            } else {
                content
            }
        }
    }

    private struct OptionalSquare: ViewModifier {
        let enabled: Bool
        func body(content: Content) -> some View {
            if enabled {
                content.aspectRatio(1, contentMode: .fit)
            } else {
                content
            }
        }
    }

    private struct OptionalContextMenu: ViewModifier {
        let enabled: Bool
        let item: WorkshopQueryItem

        func body(content: Content) -> some View {
            if enabled {
                content.contextMenu {
                    Button {} label: { Label("Download", systemImage: "arrow.down.circle") }
                    Divider()
                    Button {} label: { Label("Open in Steam", systemImage: "arrow.up.forward.app") }
                }
            } else {
                content
            }
        }
    }

    /// Wall time to build and lay out one full grid, averaged over `iterations`.
    private func measure(_ variant: Variant) -> Double {
        let items = makeItems(Self.cardCount)
        let columns = DesignTokens.LibraryGrid.columns(for: .medium)
        var total: Double = 0
        for _ in 0 ..< Self.iterations {
            let grid = ScrollView {
                LazyVGrid(columns: columns, spacing: DesignTokens.LibraryGrid.spacing) {
                    ForEach(items) { item in
                        card(item, variant, reduceMotion: true)
                    }
                }
            }
            let host = NSHostingView(rootView: AnyView(grid))
            host.frame = NSRect(x: 0, y: 0, width: Self.gridWidth, height: 900)
            let started = CACurrentMediaTime()
            // `layoutSubtreeIfNeeded` is what forces the SwiftUI subtree to be
            // built and measured; without it the host defers everything and
            // every row reads as free.
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            total += CACurrentMediaTime() - started
        }
        return (total / Double(Self.iterations)) * 1000
    }

    @Test("Ablation: which layer of a browse card costs the grid its scroll budget")
    func ablationTable() {
        let variants: [Variant] = [
            Variant(name: "baseline (everything)"),
            Variant(name: "no .contextMenu", contextMenu: false),
            Variant(name: "no thumbnail view", thumbnail: false),
            Variant(name: "thumbnail, unconstrained", squareConstraint: false),
            // Confounded on purpose, kept for the record: it drops opaque badges with it.
            Variant(name: "no chrome (confounded)", chrome: false, opaqueBadges: false),
            Variant(name: "no chrome, badges opaque", chrome: false),
            // Separates the two things the old "no glass badges" row removed at once.
            Variant(name: "badges, no GlassContainer", glassContainer: false),
            // With the shipped gate this must now land on "no badges at all";
            // before the fix it sat 10.4% above it, paying for an empty shell.
            Variant(name: "pills off (user toggle)", pills: false),
            Variant(name: "no badges at all", badges: false),
            Variant(name: "floor (empty tiles)", contextMenu: false, chrome: false, thumbnail: false, badges: false),
            // Control: the same variant as row 1, run last. If it does not land
            // near the first baseline, the table is reading sequence effects
            // (allocator state, autorelease pressure) rather than the layers.
            Variant(name: "baseline again (control)"),
        ]

        // One discarded pass: the first grid built in a process pays for SwiftUI's
        // own one-time setup, which would otherwise land entirely on the baseline row.
        _ = measure(Variant(name: "warmup"))

        var rows: [String] = []
        var baseline: Double = 0
        for variant in variants {
            let ms = measure(variant)
            if variant.name.hasPrefix("baseline") {
                baseline = ms
            }
            let delta = baseline > 0 ? (ms - baseline) / baseline * 100 : 0
            rows.append(String(
                format: "  %-24s %7.2f ms   %+6.1f%%",
                (variant.name as NSString).utf8String!, ms, delta
            ))
        }
        print("\n=== Browse card ablation (\(Self.cardCount) cards, \(Self.iterations) passes each) ===")
        print(rows.joined(separator: "\n"))
        print("=== lower is better; read deltas, not absolutes ===\n")

        // The bench is only meaningful if it measured something at all.
        #expect(baseline > 0)
    }
}

/// Second-level ablation: `AnimatedGIFThumbnail` cost 48% of a browse card in
/// `BrowseCardLayoutCostTests`, with `previewImageURL` nil — so none of it was
/// image decoding. Its `content` is already a plain `Image` whether or not the
/// GIF is playing, which rules out "the animated view is heavy". This suite
/// takes the wrapper around that image apart instead.
@MainActor
@Suite("Browse thumbnail wrapper cost", .serialized)
struct BrowseThumbnailWrapperCostTests {
    private static let cardCount = 50
    private static let gridWidth: CGFloat = 1200
    private static let iterations = 5

    private struct Variant {
        var name: String
        /// `.blur(radius: isBlurred ? 26 : 0)` — always attached today, and a
        /// zero radius is not necessarily free.
        var blur = true
        /// `@State GIFAnimationController()`, one `@Observable` per card.
        var controller = true
        /// `.task(id:)` + the three lifecycle hooks driving the playback gate.
        var lifecycle = true
        /// The `isAnimating` overlay and its `.animation`.
        var playingOverlay = true
        /// The four things a `ViewBuilder` replica silently drops: `@State`
        /// storage, two `@Environment` reads, a `@Binding`, and the
        /// `.onChange(of:)` over a six-field computed struct. These are
        /// per-view storage and dependency tracking — exactly what a recycling
        /// collection view does not re-establish on every scroll-in.
        var perViewStorage = false
    }

    /// A real `View` struct, so `@State` / `@Environment` / `@Binding` actually
    /// allocate and register. A `@ViewBuilder` function cannot express these.
    private struct StorageTile: View {
        let blur: Bool
        let playingOverlay: Bool
        let lifecycle: Bool
        @State private var controller = GIFAnimationController()
        @State private var isVisible = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.colorScheme) private var colorScheme
        @Binding var isHovered: Bool

        private var gate: some Equatable {
            ThumbnailPlaybackGateProbe(
                isVisible: isVisible, isHovered: isHovered,
                reduceMotion: reduceMotion, dark: colorScheme == .dark
            )
        }

        var body: some View {
            ZStack {
                Rectangle().fill(Color.secondary.opacity(0.12))
                Group {
                    if let frame = controller.displayedFrame {
                        Image(decorative: frame, scale: 1).resizable().scaledToFill().clipped()
                    } else {
                        Image(systemName: "cube.transparent")
                            .font(.system(size: 36, weight: .regular))
                            .foregroundStyle(.tertiary)
                    }
                }
                .modifier(OptionalBlur(enabled: blur))
            }
            .modifier(OptionalPlayingOverlay(enabled: playingOverlay, isAnimating: controller.isAnimating))
            .clipped()
            .aspectRatio(1, contentMode: .fit)
            .modifier(OptionalLifecycle(enabled: lifecycle))
            .onChange(of: gate) { _, _ in }
        }
    }

    private struct ThumbnailPlaybackGateProbe: Equatable {
        let isVisible: Bool
        let isHovered: Bool
        let reduceMotion: Bool
        let dark: Bool
    }

    /// Mirrors `AnimatedGIFThumbnail.body`'s structure, minus the parts each row drops.
    @ViewBuilder
    private func thumbnail(_ variant: Variant) -> some View {
        if variant.perViewStorage {
            StorageTile(
                blur: variant.blur,
                playingOverlay: variant.playingOverlay,
                lifecycle: variant.lifecycle,
                isHovered: .constant(false)
            )
        } else {
            plainThumbnail(variant)
        }
    }

    @ViewBuilder
    private func plainThumbnail(_ variant: Variant) -> some View {
        let controller = variant.controller ? GIFAnimationController() : nil
        ZStack {
            Rectangle().fill(Color.secondary.opacity(0.12))
            Group {
                if let frame = controller?.displayedFrame {
                    Image(decorative: frame, scale: 1).resizable().scaledToFill().clipped()
                } else {
                    Image(systemName: "cube.transparent")
                        .font(.system(size: 36, weight: .regular))
                        .foregroundStyle(.tertiary)
                }
            }
            .modifier(OptionalBlur(enabled: variant.blur))
        }
        .modifier(OptionalPlayingOverlay(enabled: variant.playingOverlay, isAnimating: controller?.isAnimating ?? false))
        .clipped()
        .aspectRatio(1, contentMode: .fit)
        .modifier(OptionalLifecycle(enabled: variant.lifecycle))
    }

    private struct OptionalBlur: ViewModifier {
        let enabled: Bool
        func body(content: Content) -> some View {
            if enabled {
                content.blur(radius: 0)
            } else {
                content
            }
        }
    }

    private struct OptionalPlayingOverlay: ViewModifier {
        let enabled: Bool
        let isAnimating: Bool
        func body(content: Content) -> some View {
            if enabled {
                content
                    .overlay(alignment: .bottomLeading) {
                        if isAnimating {
                            ThumbnailBadge("Playing", systemImage: "play.fill", opacity: 0.7)
                        }
                    }
                    .animation(.easeInOut(duration: 0.15), value: isAnimating)
            } else {
                content
            }
        }
    }

    private struct OptionalLifecycle: ViewModifier {
        let enabled: Bool
        @State private var isVisible = false
        func body(content: Content) -> some View {
            if enabled {
                content
                    .task(id: "static") {}
                    .onAppear { isVisible = true }
                    .onDisappear { isVisible = false }
            } else {
                content
            }
        }
    }

    private func measure(_ variant: Variant) -> Double {
        let columns = DesignTokens.LibraryGrid.columns(for: .medium)
        var total: Double = 0
        for _ in 0 ..< Self.iterations {
            let grid = ScrollView {
                LazyVGrid(columns: columns, spacing: DesignTokens.LibraryGrid.spacing) {
                    ForEach(0 ..< Self.cardCount, id: \.self) { _ in
                        thumbnail(variant)
                    }
                }
            }
            let host = NSHostingView(rootView: AnyView(grid))
            host.frame = NSRect(x: 0, y: 0, width: Self.gridWidth, height: 900)
            let started = CACurrentMediaTime()
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            total += CACurrentMediaTime() - started
        }
        return (total / Double(Self.iterations)) * 1000
    }

    @Test("Ablation: which part of the thumbnail wrapper costs the grid")
    func wrapperAblation() {
        let variants: [Variant] = [
            Variant(name: "baseline (full wrapper)"),
            Variant(name: "+ @State/@Env/@Binding", perViewStorage: true),
            Variant(name: "  same, no .blur(0)", blur: false, perViewStorage: true),
            Variant(name: "  same, no lifecycle", lifecycle: false, perViewStorage: true),
            Variant(name: "no .blur(0)", blur: false),
            Variant(name: "no controller", controller: false),
            Variant(name: "no .task/lifecycle", lifecycle: false),
            Variant(name: "no playing overlay", playingOverlay: false),
            Variant(name: "floor (bare Image)", blur: false, controller: false, lifecycle: false, playingOverlay: false),
            Variant(name: "baseline again (control)"),
        ]
        _ = measure(Variant(name: "warmup"))

        var rows: [String] = []
        var baseline: Double = 0
        for variant in variants {
            let ms = measure(variant)
            if variant.name.hasPrefix("baseline (") {
                baseline = ms
            }
            let delta = baseline > 0 ? (ms - baseline) / baseline * 100 : 0
            rows.append(String(
                format: "  %-26s %7.2f ms   %+6.1f%%",
                (variant.name as NSString).utf8String!, ms, delta
            ))
        }
        print("\n=== Thumbnail wrapper ablation (\(Self.cardCount) tiles, \(Self.iterations) passes) ===")
        print(rows.joined(separator: "\n"))
        print("=== lower is better; read deltas, not absolutes ===\n")
        #expect(baseline > 0)
    }
}
