import SwiftUI
import LiveWallpaperCore

struct LastApplyFailureBanner: View {
    let failure: WallpaperFailureSnapshot
    let onViewDetails: () -> Void

    var body: some View {
        InlineNoticeBanner(
            tint: DesignTokens.Colors.Status.warning,
            symbol: "exclamationmark.triangle.fill",
            title: Text("Last wallpaper application failed"),
            message: Text(verbatim: LogPrivacyRedactor.scrub(failure.title)),
            code: failure.cause.code,
            surface: .content
        ) {
            Button("View Details", action: onViewDetails)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.top, DesignTokens.Spacing.sm)
    }
}
