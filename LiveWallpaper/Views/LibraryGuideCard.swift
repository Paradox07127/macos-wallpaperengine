import LiveWallpaperCore
import SwiftUI

struct LibraryGuideFeature: Equatable {
    let icon: String
    let text: LocalizedStringKey
}

/// Tinted disc under a hierarchical glyph. Shared with the display setup page:
/// a hairline SF Symbol has nothing to sit against on a flat pane.
struct GuideHeroSymbol: View {
    let icon: String
    let tint: Color
    var glyphSize: CGFloat = DesignTokens.GuidedLibrary.iconSize

    var body: some View {
        ZStack {
            Circle()
                .fill(tint.opacity(0.12))
                .frame(width: glyphSize * 2.125, height: glyphSize * 2.125)
                .overlay(Circle().strokeBorder(tint.opacity(0.18), lineWidth: 1))

            Image(systemName: icon)
                .font(.system(size: glyphSize, weight: .light))
                .foregroundStyle(tint)
                .symbolRenderingMode(.hierarchical)
        }
        .accessibilityHidden(true)
    }
}

/// A library's first-run page — owns the whole page, feature list, per-library
/// tint. `IllustratedEmptyState` stays the in-context "no matches" state.
struct LibraryGuideCard: View {
    @Environment(\.colorScheme) private var colorScheme

    let icon: String
    let tint: Color
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    let features: [LibraryGuideFeature]
    let actionTitle: LocalizedStringKey?
    let actionSystemImage: String?
    let secondaryTitle: LocalizedStringKey?
    let secondarySystemImage: String?
    let isActionInProgress: Bool
    let errorMessage: String?
    let action: (() -> Void)?
    let secondaryAction: (() -> Void)?

    init(
        icon: String,
        tint: Color,
        title: LocalizedStringKey,
        message: LocalizedStringKey,
        features: [LibraryGuideFeature],
        actionTitle: LocalizedStringKey? = nil,
        actionSystemImage: String? = nil,
        secondaryTitle: LocalizedStringKey? = nil,
        secondarySystemImage: String? = nil,
        isActionInProgress: Bool = false,
        errorMessage: String? = nil,
        action: (() -> Void)? = nil,
        secondaryAction: (() -> Void)? = nil
    ) {
        self.icon = icon
        self.tint = tint
        self.title = title
        self.message = message
        self.features = features
        self.actionTitle = actionTitle
        self.actionSystemImage = actionSystemImage
        self.secondaryTitle = secondaryTitle
        self.secondarySystemImage = secondarySystemImage
        self.isActionInProgress = isActionInProgress
        self.errorMessage = errorMessage
        self.action = action
        self.secondaryAction = secondaryAction
    }

    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: DesignTokens.GuidedLibrary.topSpacerHeight)

            GuideHeroSymbol(icon: icon, tint: tint)
                .background(halo)

            VStack(spacing: 6) {
                Text(title)
                    .font(DesignTokens.Typography.pageTitle.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)

                Text(message)
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: DesignTokens.GuidedLibrary.messageWidth)
            }

            if !features.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(features.enumerated()), id: \.offset) { _, feature in
                        featureRow(feature)
                    }
                }
                // No plate: this is a read-only feature list on a flat page, so
                // a container would only draw a box around text nobody can act on.
                .padding(.horizontal, 18)
                .padding(.vertical, DesignTokens.Spacing.cardInset)
                .frame(maxWidth: DesignTokens.GuidedLibrary.featureWidth)
            }

            actionRow

            if let errorMessage, !errorMessage.isEmpty {
                Text(verbatim: LogPrivacyRedactor.scrub(errorMessage))
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.Status.danger)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 380)
            }

            Spacer(minLength: 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DesignTokens.GuidedLibrary.outerPadding)
    }

    /// Sized off the hero, never the pane: a page-wide wash met the toolbar at
    /// a visible seam, because the toolbar keeps its own untinted background.
    /// Dark mode takes ~2/3 the alpha — what reads as a hint over white reads as
    /// a coloured page over #1E1E1E.
    private var halo: some View {
        let diameter = DesignTokens.GuidedLibrary.heroHaloDiameter
        return RadialGradient(
            colors: [tint.opacity(colorScheme == .dark ? 0.13 : 0.20), .clear],
            center: .center,
            startRadius: 0,
            endRadius: diameter / 2
        )
        .frame(width: diameter, height: diameter)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var actionRow: some View {
        if actionTitle != nil || secondaryTitle != nil {
            HStack(spacing: 10) {
                if let actionTitle, let action {
                    Button(action: action) {
                        HStack(spacing: 8) {
                            if isActionInProgress {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            if let actionSystemImage {
                                Label(actionTitle, systemImage: actionSystemImage)
                                    .frame(minWidth: 132)
                            } else {
                                Text(actionTitle)
                                    .frame(minWidth: 132)
                            }
                        }
                    }
                    .buttonStyle(CapsuleButtonStyle(tint: tint, preset: .large))
                    .disabled(isActionInProgress)
                    .keyboardShortcut(.defaultAction)
                }

                if let secondaryTitle, let secondaryAction {
                    Button(action: secondaryAction) {
                        if let secondarySystemImage {
                            Label(secondaryTitle, systemImage: secondarySystemImage)
                                .frame(minWidth: 96)
                        } else {
                            Text(secondaryTitle)
                                .frame(minWidth: 96)
                        }
                    }
                    .buttonStyle(CapsuleButtonStyle(tint: .secondary, preset: .large))
                }
            }
        }
    }

    private func featureRow(_ feature: LibraryGuideFeature) -> some View {
        HStack(spacing: 12) {
            Image(systemName: feature.icon)
                .font(DesignTokens.Typography.body.weight(.medium))
                .foregroundStyle(tint)
                .frame(width: 22)
                .symbolRenderingMode(.hierarchical)

            Text(feature.text)
                .font(DesignTokens.Typography.body)
                .foregroundStyle(.primary)
        }
    }
}
