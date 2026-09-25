import LiveWallpaperCore
import SwiftUI

/// The shelf card's now-playing capsule, for the grid tiles and the Workshop cards.
struct NowPlayingCapsule: View {
    let badge: NowPlayingBadge
    /// False where the playback state is not known, so the glyph never claims a wallpaper is playing.
    let animates: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Image(systemName: "waveform")
                .foregroundStyle(DesignTokens.EditDesk.Colors.nowPlayingGlyph)
                .symbolEffect(.variableColor.iterative.reversing, options: .repeating, isActive: animates && !reduceMotion)
            Text(verbatim: badge.text)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(DesignTokens.Colors.overlayForeground)
        }
        .font(DesignTokens.Typography.badge)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .thumbnailBadgeGlass()
        .accessibilityHidden(true)
    }
}
