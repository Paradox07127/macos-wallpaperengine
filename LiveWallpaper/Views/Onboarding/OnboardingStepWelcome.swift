import LiveWallpaperCore
import SwiftUI

struct OnboardingStepWelcome: View {
    let nextStep: () -> Void
    let skip: () -> Void
    @Environment(\.featureCatalog) private var featureCatalog

    private var tagline: LocalizedStringKey {
        featureCatalog.isEnabled(.scene)
            ? "Video, web, and Wallpaper Engine scenes — alive on every display."
            : "Local video, interactive web, and Apple Aerials — alive on every display."
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: DesignTokens.Spacing.xl + DesignTokens.Spacing.sm)

            appIcon
                .frame(width: Metrics.appIconSize, height: Metrics.appIconSize)
                .shadow(
                    color: DesignTokens.Colors.textPrimary.opacity(0.16),
                    radius: DesignTokens.Corner.xl,
                    y: DesignTokens.Spacing.sm
                )

            Spacer().frame(height: DesignTokens.Spacing.xl)

            VStack(spacing: DesignTokens.Spacing.sm) {
                // Both SKUs ship under their own name (Pro "LiveWallpaper",
                // Lite "Loomscreen"), so the brand comes from the running
                // bundle rather than a literal.
                Text("Welcome to \(BundleIdentity.productDisplayName)")
                    .font(DesignTokens.Typography.hero)
                    .accessibilityAddTraits(.isHeader)

                Text(tagline)
                    .font(DesignTokens.Typography.sectionTitle)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, DesignTokens.Spacing.xl + DesignTokens.Spacing.sm)

                Label("No account. No telemetry. Your files stay on this Mac.", systemImage: "lock.shield")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                    .padding(.top, DesignTokens.Spacing.xs)
            }

            Spacer()

            Button(action: nextStep) {
                Text("Continue")
                    .frame(minWidth: 140)
            }
            .buttonStyle(GlassCapsuleButtonStyle(fontSize: 14, horizontalPadding: 24, verticalPadding: 10))
            .keyboardShortcut(.defaultAction)
            .accessibilityHint(Text("Proceed to choose your first wallpaper"))

            Button(action: skip) {
                Text("Skip for Now", comment: "Skip first-run wallpaper setup and open the app.")
                    .font(DesignTokens.Typography.body)
            }
            .buttonStyle(.plain)
            .foregroundStyle(DesignTokens.Colors.textSecondary)
            .padding(.top, DesignTokens.Spacing.md)

            Spacer().frame(height: DesignTokens.Spacing.xl)
        }
    }

    @ViewBuilder
    private var appIcon: some View {
        if let icon = NSImage(named: "AppIcon") {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
        } else {
            Image(systemName: "play.rectangle.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(DesignTokens.Colors.accent)
        }
    }

    private enum Metrics {
        static let appIconSize: CGFloat = 112
    }
}
