import LiveWallpaperCore
import SwiftUI

/// A glyph over its own caption, for the preview bar's controls.
///
/// Captioned, not icon-only: the bar no longer carries the wallpaper name (it
/// has its own capsule on the top edge), so the width is affordable — and an
/// unlabelled `cursorarrow.click` that disables desktop clicks must not need a
/// hover to identify. Fixed width so a Japanese caption widens the row
/// predictably rather than letting one control grow past its neighbours.
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
