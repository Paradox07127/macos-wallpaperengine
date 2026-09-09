import LiveWallpaperCore
import SwiftUI

/// Inline banner when the active wallpaper session reports a `WallpaperRuntimeError`.
/// Sits in the content column, so it takes the content surface rather than glass
/// (DESIGN.md rule 11 tiers glass by position).
struct RuntimeErrorBanner: View {
    let error: WallpaperRuntimeError
    /// Hide Re-pick when the type has no picker (e.g. scene).
    var canRePick: Bool = true
    let onRetry: () -> Void
    let onRePick: () -> Void

    var body: some View {
        InlineNoticeBanner(
            tint: severityTint,
            symbol: severityIcon,
            title: Text(verbatim: LogPrivacyRedactor.scrub(error.title)),
            message: Text(verbatim: LogPrivacyRedactor.scrub(error.userMessage)),
            detail: error.subtitlePath.map(LogPrivacyRedactor.scrub),
            surface: .content,
            accessibilityDetail: LogPrivacyRedactor.scrub(error.accessibilityDetail)
        ) {
            if error.canRetry {
                Button("Retry", action: onRetry)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .accessibilityHint(Text("Retry loading the current wallpaper source"))
            }
            if canRePick {
                Button("Re-pick", action: onRePick)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityHint(Text("Pick a different wallpaper source"))
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.top, DesignTokens.Spacing.sm)
    }

    private var severityIcon: String {
        switch error.severity {
        case .error: "exclamationmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info: "info.circle.fill"
        }
    }

    private var severityTint: Color {
        switch error.severity {
        case .error: DesignTokens.Colors.Status.danger
        case .warning: DesignTokens.Colors.Status.warning
        case .info: DesignTokens.Colors.accent
        }
    }
}
