import LiveWallpaperCore
import SwiftUI

struct ScreenDetailHeader: View {
    let screen: Screen
    @Binding var draft: ScreenDetailDraftState
    let screenManager: ScreenManager
    let wallpaperSessionSummary: WallpaperSessionSummary
    let reduceMotion: Bool
    let showsHeaderWallpaperActions: Bool
    @Binding var showBookmarks: Bool
    let onApplyToAll: () -> Void
    let onClearWallpaper: () -> Void

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
                            Text(sessionStatusText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            },
            actions: {
                HStack(spacing: 8) {
                    applyToAllButton

                    // Offer the bookmark action only when this type has
                    // bookmarkable content — no empty icon on an unconfigured display.
                    if inspectorContent != nil {
                        Button {
                            showBookmarks = true
                        } label: {
                            Image(systemName: isCurrentBookmarked ? "bookmark.fill" : "bookmark")
                        }
                        .adaptiveGlassButton(isCurrentBookmarked ? .prominent : .regular, shape: .circle)
                        .controlSize(.large)
                        .help(Text(isCurrentBookmarked
                            ? "Bookmarked — click to rename or remove"
                            : "Bookmark this wallpaper"))
                        .accessibilityLabel(Text(isCurrentBookmarked ? "Bookmarked" : "Bookmark"))
                        .popover(isPresented: $showBookmarks, arrowEdge: .bottom) {
                            BookmarksPopover(screen: screen, candidateContent: inspectorContent)
                                .environment(screenManager)
                        }
                    }

                    // No per-type import button here: the toolbar's + picker
                    // routes any file or folder by what it is, for this display.
                    if showsHeaderWallpaperActions {
                        Button(role: .destructive, action: onClearWallpaper) {
                            Image(systemName: "trash")
                        }
                        .adaptiveGlassButton(.regular, shape: .circle)
                        .tint(DesignTokens.Colors.Status.danger)
                        .controlSize(.large)
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

    @ViewBuilder
    private var applyToAllButton: some View {
        if screenManager.screens.count > 1 && screenManager.getConfiguration(for: screen) != nil {
            Button(action: onApplyToAll) {
                Image(systemName: "square.on.square")
            }
            .help(Text("Apply to All — copy this display's wallpaper and settings to every other display"))
            .accessibilityLabel(Text("Apply to all displays"))
            .accessibilityHint(Text("Copies the current wallpaper and settings to every other connected display"))
            .adaptiveGlassButton(.regular, shape: .circle)
            .controlSize(.large)
        }
    }

    private var sessionStatusText: LocalizedStringKey {
        switch wallpaperSessionSummary.activity {
        case .active:   return "Playing"
        case .paused:   return "Paused"
        case .off:      return "Off"
        case .error:    return "Error"
        case .inactive: return "Not configured"
        }
    }

    private var sessionStatusColor: Color {
        switch wallpaperSessionSummary.activity {
        case .active:   return DesignTokens.Colors.Status.active
        case .paused:   return DesignTokens.Colors.Status.warning
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
