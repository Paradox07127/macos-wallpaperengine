import LiveWallpaperCore
import SwiftUI

/// Apply control for library tiles: play button (1 display) or per-display menu (multi).
struct LibraryTileApplyControl: View {
    let screens: [Screen]
    let tint: Color
    let onApply: (Screen) -> Void
    let onApplyToAll: () -> Void

    var body: some View {
        if screens.count == 1, let only = screens.first {
            Button { onApply(only) } label: { applyIcon }
            .buttonStyle(.plain)
            .help(Text("Apply"))
        } else if screens.count > 1 {
            Menu {
                ForEach(screens, id: \.id) { screen in
                    Button("Apply to \(screen.name)") { onApply(screen) }
                }
                Divider()
                Button("Apply to All Displays", action: onApplyToAll)
            } label: { applyIcon }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(Text("Apply"))
        }
    }

    private var applyIcon: some View {
        Image(systemName: "play.fill")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(DesignTokens.Colors.onAccentFill)
            .frame(width: 22, height: 22)
            // Over-artwork glyph control — same glass family as the thumbnail
            // badges, which handles legibility and Reduce Transparency; the
            // strong opacity keeps the tinted-identity read of the old solid fill.
            .thumbnailBadgeGlass(tint: tint, opacity: 0.9, in: .circle)
    }
}
