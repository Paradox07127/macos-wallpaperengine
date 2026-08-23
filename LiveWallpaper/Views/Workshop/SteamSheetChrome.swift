#if !LITE_BUILD
import LiveWallpaperCore
import SwiftUI

/// Shared chrome for the Steam sheets (connection, install consent, sign-in,
/// API key, privacy).
///
/// Five of them had each grown their own header and their own width — two of
/// the headers were the same fifteen lines with a different icon. One header
/// and two widths is what makes the family read as one feature rather than
/// five screens that happen to be adjacent.

// MARK: - Header

/// Icon + title + optional one-line subtitle, the shape every Steam sheet had
/// converged on by hand.
struct SteamSheetHeader: View {
    let icon: String
    let title: LocalizedStringKey
    /// Defaults to the "this is fine" tint. Callers whose icon changes with
    /// state must pass the matching colour — a warning glyph in green reads as
    /// success at a glance, which is worse than no glyph at all.
    var iconTint: Color = DesignTokens.Colors.Status.active
    var subtitle: LocalizedStringKey?
    /// Rendered next to the title when the sheet needs to explain itself in
    /// more than a subtitle's worth of words.
    var info: String.LocalizationValue?

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundStyle(iconTint)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.xs) {
                    Text(title, bundle: .main)
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    if let info {
                        InfoTooltipButton(text: info)
                    }
                }
                if let subtitle {
                    Text(subtitle, bundle: .main)
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)
        }
    }
}

// MARK: - Width

/// Two widths, not five. Anything wider than `dense` starts stretching
/// single-line detail text across a gulf; anything narrower than `form` wraps
/// CJK labels that run 1.5–2× their English source.
enum SteamSheetWidth {
    /// Forms, confirmations, short explanations.
    static let form: CGFloat = 480
    /// Rows carrying paths, statuses and their own controls.
    static let dense: CGFloat = 560
}

// MARK: - Status

/// One status vocabulary for the whole family.
///
/// Setup rows used a 6pt dot plus a word; probe rows used filled SF Symbols.
/// Two languages for one concept in one window meant a green dot and a green
/// checkmark had to be read as unrelated. This is the symbol version, because
/// the symbol survives being scanned at a glance and the dot does not.
enum SteamStatusIcon {
    static func symbol(for state: WorkshopStepState) -> String {
        switch state {
        case .ready: return "checkmark.circle.fill"
        case .attention: return "exclamationmark.triangle.fill"
        // Never rendered — `.working` draws a spinner instead, because a
        // static "refresh" glyph is indistinguishable from an idle button.
        case .working: return "arrow.triangle.2.circlepath"
        case .notStarted: return "circle.dashed"
        }
    }
}

/// The status glyph, sized and coloured once.
struct SteamStatusGlyph: View {
    let state: WorkshopStepState
    var size: CGFloat = 16

    var body: some View {
        if state == .working {
            ProgressView()
                .controlSize(.small)
                .frame(width: size, height: size)
                .accessibilityLabel(Text(state.statusText, bundle: .main))
        } else {
            Image(systemName: SteamStatusIcon.symbol(for: state))
                .font(.system(size: size))
                .foregroundStyle(state.tint)
                .accessibilityLabel(Text(state.statusText, bundle: .main))
        }
    }
}
#endif
