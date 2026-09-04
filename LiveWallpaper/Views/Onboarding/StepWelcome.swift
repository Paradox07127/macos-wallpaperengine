import LiveWallpaperCore
import SwiftUI

struct StepWelcome: View {
    let nextStep: () -> Void
    @Environment(\.featureCatalog) private var featureCatalog

    private var tagline: LocalizedStringKey {
        featureCatalog.isEnabled(.scene)
            ? "Video, web, and Wallpaper Engine scenes on every display."
            : "Local video, interactive web, and Apple Aerials on every display."
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

            VStack(spacing: DesignTokens.Spacing.md) {
                // Both SKUs ship under their own name (Pro "Loomscreen Pro",
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
            }

            Spacer().frame(height: DesignTokens.Spacing.xl)

            typeChips

            Spacer()

            Button(action: nextStep) {
                Text("Continue")
                    .frame(minWidth: 140)
            }
            .buttonStyle(CapsuleButtonStyle(preset: .large))
            .keyboardShortcut(.defaultAction)
            .accessibilityHint(Text("Proceed to choose your first wallpaper"))

            Spacer().frame(height: DesignTokens.Spacing.xl)
        }
    }

    /// The wallpaper kinds this SKU plays, shown before any of them is asked
    /// for. Display only — the picker two steps later is where they're chosen.
    private var typeChips: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            typeChip(icon: "film", title: "Video")
            typeChip(icon: "globe", title: "Web")
            if featureCatalog.isEnabled(.scene) {
                typeChip(icon: "cube.transparent", title: "Scene")
            }
            typeChip(icon: "sparkles.tv", title: "Apple Aerials")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Supported wallpaper types"))
    }

    private func typeChip(icon: String, title: LocalizedStringKey) -> some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Image(systemName: icon)
                .font(DesignTokens.Typography.caption.weight(.medium))
                .foregroundStyle(DesignTokens.Colors.accent)
            Text(title)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Colors.textSecondary)
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.xs + 2)
        .background(
            Capsule(style: .continuous)
                .fill(DesignTokens.Colors.surfaceRaised)
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(DesignTokens.Colors.separator.opacity(0.55), lineWidth: 0.5)
        )
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
