import LiveWallpaperCore
import SwiftUI


// MARK: - Header

struct SteamSheetHeader: View {
    var icon: String?
    let title: LocalizedStringKey
    /// Callers must match the tint to state; warning glyphs must not use the success tint.
    var iconTint: Color = DesignTokens.Colors.Status.active
    var subtitle: LocalizedStringKey?
    var info: String.LocalizationValue?

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundStyle(iconTint)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.xs) {
                    Text(title)
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    if let info {
                        InfoTooltipButton(text: info)
                    }
                }
                if let subtitle {
                    Text(subtitle)
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)
        }
    }
}

#if !LITE_BUILD

// MARK: - Width

enum SteamSheetWidth {
    static let form: CGFloat = 480
    static let dense: CGFloat = 560
}

// MARK: - Status

enum SteamStatusIcon {
    static func symbol(for state: WorkshopStepState) -> String {
        switch state {
        case .ready: return "checkmark.circle.fill"
        case .attention: return "exclamationmark.triangle.fill"
        // SteamStatusGlyph renders a spinner for this state.
        case .working: return "arrow.triangle.2.circlepath"
        case .notStarted: return "circle.dashed"
        }
    }
}

struct SteamStatusGlyph: View {
    let state: WorkshopStepState
    var size: CGFloat = 16

    var body: some View {
        if state == .working {
            ProgressView()
                .controlSize(.small)
                .frame(width: size, height: size)
                .accessibilityLabel(Text(state.statusText))
        } else {
            Image(systemName: SteamStatusIcon.symbol(for: state))
                .font(.system(size: size))
                .foregroundStyle(state.tint)
                .accessibilityLabel(Text(state.statusText))
        }
    }
}
#endif
