import LiveWallpaperCore
import SwiftUI

/// Inline banner when the active wallpaper session reports a `WallpaperRuntimeError`.
struct RuntimeErrorBanner: View {
    let error: WallpaperRuntimeError
    /// Hide Re-pick when the type has no picker (e.g. scene).
    var canRePick: Bool = true
    let onRetry: () -> Void
    let onRePick: () -> Void

    var body: some View {
        let sanitizedTitle = LogPrivacyRedactor.scrub(error.title)

        HStack(alignment: .center, spacing: 12) {
            Image(systemName: severityIcon)
                .foregroundStyle(severityTint)
                .font(.title3)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: sanitizedTitle)
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                if let subtitle = error.subtitlePath, !subtitle.isEmpty {
                    Text(verbatim: LogPrivacyRedactor.scrub(subtitle))
                        .font(DesignTokens.Typography.codeCaption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(verbatim: sanitizedTitle))
            .accessibilityValue(Text(verbatim: LogPrivacyRedactor.scrub(error.accessibilityDetail)))

            Spacer(minLength: 8)

            if error.canRetry {
                Button("Retry", action: onRetry)
                    .adaptiveGlassButton(.prominent, size: .small)
                    .accessibilityHint(Text("Retry loading the current wallpaper source"))
            }
            if canRePick {
                Button("Re-pick", action: onRePick)
                    .adaptiveGlassButton(.regular, size: .small)
                    .accessibilityHint(Text("Pick a different wallpaper source"))
            }
        }
        .padding(12)
        .adaptiveGlassSurface(.roundedRectangle(DesignTokens.Corner.md), tint: severityTint)
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Corner.md)
                .stroke(severityTint.opacity(0.4), lineWidth: 0.5)
        )
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
    }

    private var severityIcon: String {
        switch error.severity {
        case .error:   return "exclamationmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info:    return "info.circle.fill"
        }
    }

    private var severityTint: Color {
        switch error.severity {
        case .error:   return DesignTokens.Colors.Status.danger
        case .warning: return DesignTokens.Colors.Status.warning
        case .info:    return .blue
        }
    }
}
