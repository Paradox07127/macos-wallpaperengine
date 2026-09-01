import LiveWallpaperCore
import SwiftUI

/// Apply control for library tiles: play button (1 display) or per-display menu (multi).
struct LibraryTileApplyControl: View {
    let screens: [Screen]
    let tint: Color
    let onApply: (Screen) -> Void
    /// Omitted by callers whose payload is a whole-screen setup: broadcasting one
    /// to every display would overwrite each display's entire setup at once, which
    /// is a product decision nobody has taken. Schemes therefore apply one at a time.
    var onApplyToAll: (() -> Void)?

    @State private var isHovering = false
    @State private var showingTargets = false

    var body: some View {
        if screens.count == 1, let only = screens.first {
            Button { onApply(only) } label: { applyIcon }
            .buttonStyle(.plain)
            .help(Text("Apply"))
        } else if screens.count > 1 {
            // Not a Menu: `.menuStyle(.borderlessButton)` is an AppKit popup that
            // ignores the label's `foregroundStyle` and paints the glyph in the
            // system control colour — black, and invisible on this tinted disc
            // over artwork. Only the multi-display branch was ever a Menu, so
            // the single-display button silently looked right.
            Button { showingTargets = true } label: { applyIcon }
                .buttonStyle(.plain)
                .help(Text("Apply"))
                .popover(isPresented: $showingTargets, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                        ForEach(screens, id: \.id) { screen in
                            Button("Apply to \(screen.name)") {
                                showingTargets = false
                                onApply(screen)
                            }
                        }
                        if let onApplyToAll {
                            Divider()
                            Button("Apply to All Displays") {
                                showingTargets = false
                                onApplyToAll()
                            }
                        }
                    }
                    .buttonStyle(.borderless)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .settingsPopoverChrome(width: 220)
                }
        }
    }

    private var applyIcon: some View {
        Image(systemName: "play.fill")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(DesignTokens.Colors.onAccentFill)
            .frame(width: 22, height: 22)
            // Interactive over-artwork glyph control — the hover glass API; the
            // strong opacity keeps the tinted-identity read of the old solid
            // fill, resting exactly where the thumbnailBadgeGlass backing sat.
            .floatingGlyphGlass(hovered: isHovering, tint: tint, opacity: 0.9)
            .onHover { isHovering = $0 }
    }
}
