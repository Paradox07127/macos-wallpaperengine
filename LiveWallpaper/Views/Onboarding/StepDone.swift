import LiveWallpaperCore
import SwiftUI

struct StepDone: View {
    let destination: OnboardingCompletionDestination
    let finish: () -> Void
    @Environment(ScreenManager.self) private var screenManager

    private var configuredScreen: Screen? {
        guard case .display(let screenID) = destination else { return nil }
        guard let screenID else { return nil }
        return screenManager.screens.first { $0.id == screenID }
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: DesignTokens.Spacing.xl + DesignTokens.Spacing.sm)

            ZStack {
                Circle()
                    .fill(DesignTokens.Colors.Status.active.opacity(0.12))
                    .frame(width: Metrics.successSymbolSize, height: Metrics.successSymbolSize)
                Image(systemName: "checkmark")
                    .font(.system(size: Metrics.checkmarkSize, weight: .semibold))
                    .foregroundStyle(DesignTokens.Colors.Status.active)
            }
            .accessibilityHidden(true)

            Spacer().frame(height: DesignTokens.Spacing.lg)

            VStack(spacing: DesignTokens.Spacing.sm) {
                Text("You're All Set")
                    .font(DesignTokens.Typography.hero)
                    .accessibilityAddTraits(.isHeader)

                if let completionMessage {
                    Text(completionMessage)
                        .font(DesignTokens.Typography.body)
                        .foregroundStyle(DesignTokens.Colors.textSecondary)
                        .multilineTextAlignment(.center)
                }
            }

            if let configuredScreen {
                Label {
                    Text(verbatim: configuredScreen.name)
                        .lineLimit(1)
                } icon: {
                    Image(systemName: "display")
                }
                .font(DesignTokens.Typography.bodyEmphasized)
                .foregroundStyle(DesignTokens.Colors.textPrimary)
                .padding(.horizontal, DesignTokens.Spacing.lg)
                .padding(.vertical, DesignTokens.Spacing.md)
                .background(
                    RoundedRectangle(cornerRadius: DesignTokens.Corner.md, style: .continuous)
                        .fill(DesignTokens.Colors.surfaceRaised)
                )
                .padding(.top, DesignTokens.Spacing.lg)
            }

            Spacer()

            Button(action: finish) {
                Text(completionButtonTitle)
                    .frame(minWidth: 140)
            }
            .buttonStyle(CapsuleButtonStyle(preset: .large))
            .keyboardShortcut(.defaultAction)
            .accessibilityHint(Text("Close onboarding and open \(BundleIdentity.productDisplayName)"))

            Text("Use the menu bar icon for quick playback controls.")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Colors.textSecondary)
                .padding(.top, DesignTokens.Spacing.sm)

            Spacer().frame(height: DesignTokens.Spacing.xl + DesignTokens.Spacing.sm)
        }
    }

    private enum Metrics {
        static let successSymbolSize: CGFloat = 92
        static let checkmarkSize: CGFloat = 38
    }

    /// Aerials/Workshop get no message: the button already names the
    /// destination, and a sentence restating it is words without information.
    private var completionMessage: LocalizedStringKey? {
        switch destination {
        case .display:
            return "Your wallpaper is ready."
        case .appleAerials, .steamWorkshop:
            return nil
        }
    }

    private var completionButtonTitle: LocalizedStringKey {
        switch destination {
        case .display:
            return "Open display settings"
        case .appleAerials:
            return "Open Apple Aerials"
        case .steamWorkshop:
            return "Open Steam Workshop"
        }
    }
}
