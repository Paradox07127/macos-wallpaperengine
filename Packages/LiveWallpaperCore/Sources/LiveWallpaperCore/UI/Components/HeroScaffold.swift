// Hero-type sheet/page scaffold (centered illustration + title + vertical action stack), W3 landed.
import SwiftUI

/// Accent gradient disc behind an SF Symbol — the shared illustration style
/// for hero sheets. Decorative, so it is hidden from accessibility.
public struct HeroGlyph: View {
    let systemImage: String

    public init(systemImage: String) {
        self.systemImage = systemImage
    }

    public var body: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(
                    colors: [
                        DesignTokens.Colors.accent.opacity(0.35),
                        DesignTokens.Colors.accent.opacity(0.05),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
                .frame(width: Metrics.discSize, height: Metrics.discSize)
            Image(systemName: systemImage)
                .font(.system(size: Metrics.symbolSize, weight: .light))
                .foregroundStyle(DesignTokens.Colors.accent)
        }
        .accessibilityHidden(true)
    }

    private enum Metrics {
        static let discSize: CGFloat = 100
        static let symbolSize: CGFloat = 42
    }
}

/// Hero scaffold: centered illustration + title + optional message + a free
/// mid slot (bullets, chips) + one prominent primary action with 0–3
/// borderless alternatives stacked under it. Horizontal inset only — width
/// and vertical inset stay with the caller (sheet vs page).
public struct HeroScaffold<Illustration: View, Content: View>: View {
    private let illustration: Illustration
    private let title: LocalizedStringKey
    private let message: LocalizedStringKey?
    private let content: Content
    private let primary: (title: LocalizedStringKey, action: () -> Void)
    private let alternatives: [(LocalizedStringKey, () -> Void)]

    public init(
        title: LocalizedStringKey,
        message: LocalizedStringKey? = nil,
        primary: (title: LocalizedStringKey, action: () -> Void),
        alternatives: [(LocalizedStringKey, () -> Void)] = [],
        @ViewBuilder illustration: () -> Illustration,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.message = message
        self.primary = primary
        self.alternatives = alternatives
        self.illustration = illustration()
        self.content = content()
    }

    public var body: some View {
        VStack(spacing: DesignTokens.Spacing.lg) {
            illustration

            VStack(spacing: DesignTokens.Spacing.sm) {
                Text(title)
                    .font(DesignTokens.Typography.pageTitle)
                    .multilineTextAlignment(.center)
                if let message {
                    Text(message)
                        .font(DesignTokens.Typography.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            content

            Spacer(minLength: DesignTokens.Spacing.sm)

            VStack(spacing: DesignTokens.Spacing.sm) {
                Button(action: primary.action) {
                    Text(primary.title)
                        .frame(maxWidth: HeroScaffoldMetrics.primaryMaxWidth)
                        .padding(.vertical, DesignTokens.Spacing.xs)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)

                ForEach(Array(alternatives.enumerated()), id: \.offset) { _, alternative in
                    Button(action: alternative.1) {
                        Text(alternative.0)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.xl)
    }
}

/// File scope: a nested type would inherit the scaffold's generic context,
/// where static stored properties are not allowed.
private enum HeroScaffoldMetrics {
    static let primaryMaxWidth: CGFloat = 220
}
