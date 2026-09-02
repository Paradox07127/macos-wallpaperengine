import LiveWallpaperCore
import SwiftUI

/// A glyph over its own caption, for the preview bar's controls.
///
/// The controls were icon-only for a spell, because the bar also carried the
/// wallpaper's name and a caption on every control was what pushed that name off
/// the edge. The name has its own capsule on the top edge now, so the bar's whole
/// width is controls and a word under each glyph is affordable again — and an
/// unlabelled `cursorarrow.click` is not something anyone should have to hover to
/// identify, least of all one that disables desktop clicks while it is on.
///
/// Fixed width so a Japanese caption widens the row predictably rather than
/// letting one control grow past its neighbours.
struct PreviewControlLabel: View {
    let systemImage: String
    let title: LocalizedStringKey
    var isActive = false
    var tint: Color?

    /// Wide enough for the longest caption at this size in every shipped
    /// language; past that the caption truncates rather than the row reflowing.
    static let width: CGFloat = 54

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .medium))
                .frame(height: 18)
            Text(title)
                .font(DesignTokens.Typography.caption)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(resolvedTint)
        .frame(width: Self.width)
        .contentShape(Rectangle())
    }

    /// White, not `.secondary` and not the accent. Both of those are tuned against
    /// the app's own background; on a wallpaper they are a mid grey and a blue on
    /// whatever colour happens to be behind them — the selected segment came out
    /// as accent text on a 35%-accent pill, which is the washed-out label in the
    /// bar. The scrim under the capsule is the known floor these read against.
    private var resolvedTint: AnyShapeStyle {
        if let tint {
            return AnyShapeStyle(tint)
        }
        return AnyShapeStyle(
            DesignTokens.Colors.overlayForeground.opacity(isActive ? 1 : 0.62)
        )
    }
}
