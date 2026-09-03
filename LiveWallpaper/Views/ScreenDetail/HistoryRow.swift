#if !LITE_BUILD
import SwiftUI
import AppKit
import LiveWallpaperCore
import LiveWallpaperProWPE

/// Probed once per workshop item and kept for the session: the resolution comes
/// from opening the actual video file, which is far too expensive to redo every
/// time a card scrolls back into view. Bounded by the size of the installed
/// library, and every value is a short label.
@MainActor
private final class WPEResolutionProbeCache {
    static let shared = WPEResolutionProbeCache()

    /// `.some(nil)` = probed, no label (scene/web, unresolvable, or SD-less).
    private var probed: [String: String?] = [:]

    func result(for id: String) -> String?? { probed[id] }
    func store(_ label: String?, for id: String) { probed[id] = label }
}

/// Shared Wallpaper Engine gallery card used by both the Scene tab and the
/// Installed library grid.
struct HistoryRow: View {
    let entry: WPEHistoryEntry
    let isActive: Bool
    var allowsInlineApply: Bool = false
    var isSelected: Bool = false
    var screens: [Screen] = []
    var onApply: (Screen) -> Void = { _ in }
    var onApplyToAll: () -> Void = {}
    var onTap: () -> Void = {}
    let onRemove: () -> Void
    var isBookmarked: Bool = false
    var onBookmark: (() -> Void)?
    var hasUpdate: Bool = false
    var onUpdate: (() -> Void)?

    @State private var isHovering = false
    @State private var showingFileActions = false
    @State private var bookmarkHovering = false
    @State private var resolutionLabel: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Read once per pane and handed down, not five `@AppStorage` per tile —
    /// see `GalleryCardPreferences`.
    @Environment(\.galleryCardPreferences) private var cardPreferences

    var body: some View {
        cardContainer
            .task(id: resolutionProbeKey) { await loadResolutionIfNeeded() }
            .galleryTileChrome(
                isHovering: isHovering,
                isSelected: isSelected,
                reduceMotion: reduceMotion
            )
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .settledHover { isHovering = $0 }
            .accessibilityElement(children: allowsInlineApply ? .contain : .ignore)
            .accessibilityLabel(accessibilityCardLabel)
            .accessibilityHint(applyAccessibilityHint)
            .contextMenu {
                if allowsInlineApply {
                    ForEach(screens, id: \.id) { screen in
                        Button("Apply to \(screen.name)") { onApply(screen) }
                    }
                    if screens.count > 1 {
                        Button("Apply to All Displays", action: onApplyToAll)
                    }
                    if !screens.isEmpty { Divider() }
                }
                if hasUpdate, let onUpdate {
                    Button(action: onUpdate) {
                        Label("Update from Steam", systemImage: "arrow.triangle.2.circlepath")
                    }
                    Divider()
                }
                if let onBookmark {
                    Button(isBookmarked ? "Remove Bookmark" : "Add Bookmark", action: onBookmark)
                    Divider()
                }
                Button("Show in Finder") { showInFinder() }
                Button("Remove", role: .destructive, action: onRemove)
            }
    }

    private var cardContainer: some View {
        Button(action: onTap) { card }
            .buttonStyle(.plain)
    }

    private var card: some View {
        VStack(spacing: 0) {
            WPEPreviewView(
                imageURL: entry.origin.sourcePreviewURL,
                securityScopedBookmarkData: entry.origin.sourceFolderBookmark,
                playbackMode: .hoverToPlay,
                previewSize: .tile
            )
            .overlay(alignment: .topTrailing) {
                AdaptiveGlassContainer(spacing: DesignTokens.Spacing.xs) {
                    HStack(spacing: DesignTokens.Spacing.xs) {
                        if let resolutionLabel, cardPreferences.showsResolution {
                            ThumbnailBadge(verbatim: resolutionLabel)
                        }
                        if let badge = compatibilityBadge {
                            ThumbnailBadge(
                                badge.titleKey,
                                tint: badge.tint,
                                opacity: 0.85,
                                accessibility: badge.accessibility
                            )
                        }
                        if let onBookmark {
                            bookmarkControl(onBookmark)
                        }
                    }
                }
                .padding(DesignTokens.Spacing.sm)
            }
            .overlay(alignment: .topLeading) {
                AdaptiveGlassContainer(spacing: DesignTokens.Spacing.xs) {
                    HStack(spacing: DesignTokens.Spacing.xs) {
                        if cardPreferences.showsType { typePill }
                        if hasUpdate, cardPreferences.showsUpdate { updateBadge }
                    }
                }
                .padding(DesignTokens.Spacing.sm)
            }
            // Title, in-use mark and bookmark ride the picture's bottom edge.
            // The "In use" pill used to sit in this same corner as a separate
            // overlay and would now be buried under the band.
            .overlay(alignment: .bottom) {
                ThumbnailTitleBand(title: entry.origin.title, isHovering: isHovering) {
                    if isActive, cardPreferences.showsInUse {
                        ThumbnailPresenceCheck()
                            .accessibilityLabel(Text("In use"))
                    }
                    // Primary-UI path to the context menu's file actions — the
                    // right-click menu must not be the only way to reach them.
                    // A Button, not a Menu: `.menuStyle(.borderlessButton)` is an
                    // AppKit popup that ignores the label's `foregroundStyle` and
                    // paints the glyph in the system control colour, which is
                    // invisible on the band (reported on 26, 2026-08-31).
                    Button { showingFileActions = true } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(DesignTokens.Colors.overlayForeground)
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .opacity(isHovering ? 1 : 0)
                    .accessibilityLabel(Text("More actions"))
                    .popover(isPresented: $showingFileActions, arrowEdge: .bottom) {
                        fileActionsPopover
                    }
                }
            }
        }
    }

    /// Bookmark toggle in the picture's top-right corner. Glass-backed like the
    /// badges beside it: a bare glyph over arbitrary artwork has no guaranteed
    /// contrast, and this is an interactive glyph over media (see W5 R1c).
    private func bookmarkControl(_ toggle: @escaping () -> Void) -> some View {
        Button(action: toggle) {
            Image(systemName: isBookmarked ? "bookmark.fill" : "bookmark")
                .font(.system(size: 11))
                .foregroundStyle(isBookmarked
                    ? DesignTokens.Colors.rating
                    : DesignTokens.Colors.overlayForeground)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Explicit strength rather than the 0.18/0.32 default: the badge sits on
        // arbitrary wallpaper stills, and the default backing disappeared into
        // bright ones. Reads as a dark chip on every card.
        .floatingGlyphGlass(hovered: bookmarkHovering, opacity: 0.72)
        .onHover { bookmarkHovering = $0 }
        .help(isBookmarked ? Text("Remove Bookmark") : Text("Add Bookmark"))
        .accessibilityLabel(Text(isBookmarked ? "Remove Bookmark" : "Add Bookmark"))
    }

    private var fileActionsPopover: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Button("Show in Finder") {
                showingFileActions = false
                showInFinder()
            }
            Button("Remove", role: .destructive) {
                showingFileActions = false
                onRemove()
            }
        }
        .buttonStyle(.borderless)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsPopoverChrome(width: 200)
    }

    /// Only video projects have a resolution — a WPE scene renders at whatever the display is,
    /// and web has none; packaged video keeps media outside the source folder, so those stay
    /// unlabelled too. Keyed by import stamp + workshop ID: `recordWPEImport` restamps `importedAt`
    /// on a genuine re-import (preserves it on a relink), so a 1080p item updated to 4K re-probes instead of keeping its old label until relaunch.
    private var resolutionProbeKey: String {
        "\(entry.origin.workshopID)#\(entry.importedAt.timeIntervalSince1970)"
    }

    private func loadResolutionIfNeeded() async {
        let key = resolutionProbeKey
        if let cached = WPEResolutionProbeCache.shared.result(for: key) {
            resolutionLabel = cached
            return
        }
        // A new probe key means a different underlying item (re-import/relink
        // restamped it) — clear the stale label from whatever the row showed
        // before, so an early-return below can't leave the old value on screen.
        resolutionLabel = nil
        guard entry.origin.originalType == .video,
              let entryFile = entry.origin.entryFile else {
            WPEResolutionProbeCache.shared.store(nil, for: key)
            return
        }

        let bookmark = entry.origin.sourceFolderBookmark
        let resolved: URL? = await Task.detached { () -> URL? in
            try? SecurityScopedBookmarkResolver.shared
                .resolve(bookmark, target: .transient).get().url
        }.value
        guard let folder = resolved, !Task.isCancelled else { return }

        let didStart = folder.startAccessingSecurityScopedResource()
        defer { if didStart { folder.stopAccessingSecurityScopedResource() } }

        guard let videoURL = WPEPathSafety.resourceURL(root: folder, relativePath: entryFile),
              FileManager.default.fileExists(atPath: videoURL.path(percentEncoded: false)) else {
            WPEResolutionProbeCache.shared.store(nil, for: key)
            return
        }

        let label = (try? await PlayableVideoLoader.detectFormat(at: videoURL))?.resolutionShortLabel
        guard !Task.isCancelled else { return }
        WPEResolutionProbeCache.shared.store(label, for: key)
        resolutionLabel = label
    }

    private var typePill: some View {
        ThumbnailTypeBadge(
            systemImage: entry.origin.originalType.symbolName,
            title: entry.origin.localizedDisplayTypeName,
            style: cardPreferences.typeStyle
        )
    }

    private var updateBadge: some View {
        ThumbnailBadge(
            "Update",
            systemImage: "arrow.triangle.2.circlepath",
            tint: DesignTokens.Colors.Status.warning,
            opacity: 0.9
        )
    }

    private var accessibilityCardLabel: Text {
        var label = Text(
            "Imported project: \(entry.origin.title)",
            comment: "A11y label for an imported project history row card. The placeholder is the project title."
        )
        if isActive {
            label = label + Text(verbatim: " — ") + Text("Currently in use", comment: "A11y: this wallpaper is the active one.")
        }
        if hasUpdate {
            label = label + Text(verbatim: " — ") + Text("Update available", comment: "A11y: the installed item has a newer version on Steam.")
        }
        // Type and resolution are stated here unconditionally because their badges are
        // `accessibilityHidden` glyphs on the thumbnail — the card label is their only textual
        // path. Type used to ride in on the footer's `TypeBadge` (its own label, exposed as a child under `allowsInlineApply`); that badge is gone.
        label = label + Text(verbatim: " — ") + Text(verbatim: entry.origin.localizedDisplayTypeName)
        if let resolutionLabel {
            label = label + Text(verbatim: " — ") + Text(verbatim: resolutionLabel)
        }
        if let badge = compatibilityBadge {
            label = label + Text(verbatim: " — ") + badge.accessibility
        }
        return label
    }

    private var applyAccessibilityHint: Text {
        if allowsInlineApply {
            return Text("Tap to apply to all displays, or drag onto a display.", comment: "A11y hint for an Installed-library card: the whole card applies the wallpaper.")
        }
        return isActive
            ? Text("Currently in use. Tap to reactivate.", comment: "A11y hint for a WPE history row that is the active wallpaper.")
            : Text("Tap to apply", comment: "A11y hint for a WPE history row that can be applied.")
    }

    private func showInFinder() {
        guard let folder = (try? SecurityScopedBookmarkResolver.shared
            .resolve(entry.origin.sourceFolderBookmark, target: .transient).get().url) else { return }
        let didStart = folder.startAccessingSecurityScopedResource()
        defer { if didStart { folder.stopAccessingSecurityScopedResource() } }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    /// Plain scenes carry no badge — only hard blockers ("Won't run") and
    /// missing dependencies ("Needs deps").
    private var compatibilityBadge: (titleKey: LocalizedStringKey, tint: Color, accessibility: Text)? {
        switch entry.origin.originalType {
        case .video, .web, .unknown:
            return nil
        case .application:
            return ("Won't run", DesignTokens.Colors.Status.warning, Text("Wallpaper requires a Windows executable; cannot run on macOS"))
        case .scene:
            if entry.origin.requiresWindowsPlugin {
                return ("Won't run", DesignTokens.Colors.Status.warning, Text("Wallpaper bundles a Windows DLL plugin; cannot run on macOS"))
            }
            if !entry.origin.missingDependencyIDs.isEmpty {
                return ("Needs deps", DesignTokens.Colors.Status.caution, Text("Wallpaper depends on Workshop projects you haven't subscribed to"))
            }
            return nil
        }
    }
}

extension WPEType {
    /// Shared by cards, inspectors, and drag previews.
    var symbolName: String {
        switch self {
        case .video: return "play.rectangle.fill"
        case .web: return "globe"
        case .scene: return "cube.transparent.fill"
        case .application: return "app.dashed"
        case .unknown: return "questionmark.square.dashed"
        }
    }
}
#endif
