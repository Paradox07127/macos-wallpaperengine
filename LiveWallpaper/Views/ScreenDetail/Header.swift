import LiveWallpaperCore
import SwiftUI

/// Raised by the Scene tab while it is showing the recent-projects grid: that
/// grid's actions live in this header, so the grid does not carry a title row of
/// its own. Declared here rather than beside the Scene view so the Lite build,
/// which has no Scene tab, still compiles the header.
struct SceneQuickActionsVisibleKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

struct Header: View {
    let screen: Screen
    @Binding var draft: DraftState
    let screenManager: ScreenManager
    let wallpaperSessionSummary: WallpaperSessionSummary
    let reduceMotion: Bool
    let showsHeaderWallpaperActions: Bool
    /// The Scene tab is showing its recent-projects grid, whose Workshop and
    /// Apply actions belong up here next to the display's own.
    var showsSceneQuickActions: Bool = false
    /// The overlay tab is showing, so "Apply to All" means this overlay only.
    var appliesOverlayOnly: Bool = false
    @Binding var showBookmarks: Bool
    let onApplyToAll: () -> Void
    let onClearWallpaper: () -> Void

    /// Bookmark-popover name draft, held here so it survives the popover being
    /// dismissed by a click outside (see `Popover`).
    @State private var bookmarkNameDraft = ""
    @State private var bookmarkDraftBaseline: String?

    /// Scheme-popover name draft, held here for the same reason as the bookmark one.
    @State private var schemeNameDraft = ""
    @State private var showSchemeCapture = false

    var body: some View {
        DetailHeaderBar(
            systemImage: "display",
            title: {
                // Reload lives in the window toolbar, with the other whole-display actions.
                Text(verbatim: screen.name)
                    .help(Text(verbatim: screen.name))
            },
            metadata: {
                HStack(spacing: DesignTokens.DetailHeader.metadataSpacing) {
                    // A renamed display still has to say which panel it is.
                    if screen.customName != nil {
                        InfoBadge(icon: "display", text: screen.systemName)
                    }
                    if let diagonal = screen.diagonalInches {
                        InfoBadge(icon: "ruler", text: "\(Int(diagonal.rounded()))″")
                    }
                    InfoBadge(icon: "arrow.up.left.and.arrow.down.right", text: "\(Int(screen.frame.width))×\(Int(screen.frame.height))")
                    InfoBadge(icon: "gauge.medium", text: "\(screenManager.getScreenRefreshRate(for: screen.id)) Hz")
                    if wallpaperSessionSummary.isConfigured {
                        HStack(spacing: 4) {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 6))
                                .foregroundStyle(sessionStatusColor)
                                .symbolEffect(
                                    .pulse,
                                    options: .continuouslyRepeating,
                                    isActive: !reduceMotion && wallpaperSessionSummary.activity == .active
                                )
                            sessionStatusText
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            },
            actions: {
                HStack(spacing: 8) {
                    if showsSceneQuickActions {
                        #if !LITE_BUILD
                        SceneHistoryHeaderActions(screen: screen)
                        #endif
                    }

                    applyToAllButton

                    // Offer the bookmark action only when this type has
                    // bookmarkable content — no empty icon on an unconfigured display.
                    if inspectorContent != nil {
                        GlassIconButton(
                            isCurrentBookmarked ? "bookmark.fill" : "bookmark",
                            prominence: isCurrentBookmarked ? .prominent : .regular
                        ) {
                            showBookmarks = true
                        }
                        .help(Text(isCurrentBookmarked
                            ? "Bookmarked — click to rename or remove"
                            : "Bookmark this wallpaper"))
                        .accessibilityLabel(Text(isCurrentBookmarked ? "Bookmarked" : "Bookmark"))
                        .popover(isPresented: $showBookmarks, arrowEdge: .bottom) {
                            AppLanguageScope(defaults: .appScoped()) {
                                Popover(
                                    screen: screen,
                                    candidateContent: inspectorContent,
                                    nameDraft: $bookmarkNameDraft,
                                    draftBaseline: $bookmarkDraftBaseline
                                )
                                .environment(screenManager)
                            }
                        }
                    }

                    saveAsSchemeButton

                    // No per-type import button here: the toolbar's + picker
                    // routes any file or folder by what it is, for this display.
                    if showsHeaderWallpaperActions {
                        GlassIconButton(
                            "trash",
                            tint: DesignTokens.Colors.Status.danger,
                            role: .destructive,
                            action: onClearWallpaper
                        )
                        .help(Text(clearHelpText))
                        .accessibilityLabel(Text(clearAccessibilityLabel))
                    }
                }
            }
        )
    }

    private var clearHelpText: LocalizedStringKey {
        switch draft.selectedWallpaperType {
        case .video:       return "Clear Video — remove the saved video for this display"
        case .html:        return "Clear Web Page — remove the saved web page for this display"
        case .scene:       return "Clear Scene — remove the active scene for this display"
        }
    }

    private var clearAccessibilityLabel: LocalizedStringKey {
        switch draft.selectedWallpaperType {
        case .video:       return "Clear video"
        case .html:        return "Clear web page"
        case .scene:       return "Clear scene"
        }
    }

    /// Same gate as `applyToAllButton`: with no stored configuration there is
    /// nothing for `captureScheme` to read, and it would return nil silently.
    @ViewBuilder
    private var saveAsSchemeButton: some View {
        if screenManager.getConfiguration(for: screen) != nil {
            GlassIconButton("square.stack.3d.up") {
                showSchemeCapture = true
            }
            .help(Text("Save as Scheme — archive this display's wallpaper, overlay layout, and every setting"))
            .accessibilityLabel(Text("Save as Scheme"))
            .popover(isPresented: $showSchemeCapture, arrowEdge: .bottom) {
                AppLanguageScope(defaults: .appScoped()) {
                    SchemeCapturePopover(screen: screen, nameDraft: $schemeNameDraft)
                        .environment(screenManager)
                }
            }
        }
    }

    @ViewBuilder
    private var applyToAllButton: some View {
        if screenManager.screens.count > 1,
           appliesOverlayOnly || screenManager.getConfiguration(for: screen) != nil {
            GlassIconButton("square.on.square", action: onApplyToAll)
            // The button copies whatever tab you are on. On the overlay tab
            // that is the layer in front of you and nothing else — taking the
            // wallpaper along with it would replace content the user never
            // asked about from a page that does not even show it.
            .help(appliesOverlayOnly
                ? Text("Apply to All — copy this display's overlay to every other display, leaving their wallpapers alone")
                : Text("Apply to All — copy this display's wallpaper and settings to every other display"))
            .accessibilityLabel(Text("Apply to all displays"))
            .accessibilityHint(appliesOverlayOnly
                ? Text("Copies this overlay to every other connected display; their wallpapers are not changed")
                : Text("Copies the current wallpaper and settings to every other connected display"))
        }
    }

    private var sessionStatusText: Text {
        switch wallpaperSessionSummary.activity {
        case .active:   return Text("Playing")
        case .paused:   return Text("Paused")
        case .policySuspended:
            // Gate on the wording, not the reason set: a pure-absence set is
            // non-empty but has no user-visible text (nobody is watching), so
            // it must fall back rather than render an empty string.
            if let text = SuspendReasonText.localized(
                for: screenManager.suspendReasonsByScreen[screen.id] ?? []
            ) {
                // Already localized via AppLanguagePreference; verbatim avoids
                // a second catalog lookup with the translated string as key.
                return Text(verbatim: text)
            }
            return Text("Paused by system")
        case .restoring: return Text("Restoring")
        case .off:      return Text("Off")
        case .error:    return Text("Error")
        case .inactive: return Text("Not configured")
        }
    }

    private var sessionStatusColor: Color {
        switch wallpaperSessionSummary.activity {
        case .active:   return DesignTokens.Colors.Status.active
        case .paused:   return DesignTokens.Colors.Status.warning
        case .policySuspended: return DesignTokens.Colors.Status.warning
        case .restoring: return DesignTokens.Colors.Status.active
        case .off:      return .secondary
        case .error:    return DesignTokens.Colors.Status.danger
        case .inactive: return .secondary
        }
    }

    /// Bookmarkable content for the inspector tab currently in view — not the committed `activeWallpaper`.
    private var inspectorContent: WallpaperContent? {
        let config = screenManager.getConfiguration(for: screen)
        switch draft.selectedWallpaperType {
        case .video:
            if case .video(let bookmark, let packageEntryName)? = config?.activeWallpaper {
                return .video(bookmarkData: bookmark, packageEntryName: packageEntryName)
            }
            if let saved = config?.savedVideoBookmarkData {
                return .video(bookmarkData: saved)
            }
            return nil
        case .html:
            guard let source = draft.htmlSource else { return nil }
            return .html(source: source, config: draft.htmlConfig)
        case .scene:
            if case .scene(let descriptor)? = config?.activeWallpaper {
                return .scene(descriptor)
            }
            return nil
        }
    }

    private var isCurrentBookmarked: Bool {
        guard let content = inspectorContent else { return false }
        return BookmarkStore.shared.equivalentBookmark(content: content) != nil
    }
}
