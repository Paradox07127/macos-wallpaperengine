import LiveWallpaperCore
import SwiftUI

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

    private var resolvedTint: AnyShapeStyle {
        if let tint {
            return AnyShapeStyle(tint)
        }
        return AnyShapeStyle(
            DesignTokens.Colors.overlayForeground.opacity(isActive ? 1 : 0.62)
        )
    }
}
