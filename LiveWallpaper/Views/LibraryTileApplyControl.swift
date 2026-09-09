import LiveWallpaperCore
import SwiftUI

/// Apply control for library tiles: play button (1 display) or per-display menu (multi).
struct LibraryTileApplyControl: View {
    let screens: [Screen]
    let tint: Color
    let onApply: (Screen) -> Void
    /// Nil for whole-display schemes, which apply to one display at a time.
    var onApplyToAll: (() -> Void)?

    @State private var isHovering = false
    @State private var showingTargets = false

    var body: some View {
        if screens.count == 1, let only = screens.first {
            Button { onApply(only) } label: { applyIcon }
            .buttonStyle(.plain)
            .help(Text("Apply"))
        } else if screens.count > 1 {
            // A button/popover preserves glyph tint over artwork; AppKit Menu does not.
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
            // Match the resting thumbnail badge tint while retaining hover feedback.
            .floatingGlyphGlass(hovered: isHovering, tint: tint, opacity: 0.9)
            .onHover { isHovering = $0 }
    }
}
