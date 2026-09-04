import LiveWallpaperCore
import SwiftUI

struct LibraryGuideFeature: Equatable {
    let icon: String
    let text: LocalizedStringKey
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

            hero

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

            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(features.enumerated()), id: \.offset) { _, feature in
                    featureRow(feature)
                }
            }
            // No plate: this is a read-only feature list on a flat page, so a
            // container would only draw a box around text nobody can act on.
            .padding(.horizontal, 18)
            .padding(.vertical, DesignTokens.Spacing.cardInset)
            .frame(maxWidth: DesignTokens.GuidedLibrary.featureWidth)

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
        .background(halo)
    }

    private var hero: some View {
        ZStack {
            Circle()
                .fill(tint.opacity(0.12))
                .frame(
                    width: DesignTokens.GuidedLibrary.heroDiscSize,
                    height: DesignTokens.GuidedLibrary.heroDiscSize
                )
                .overlay(Circle().strokeBorder(tint.opacity(0.18), lineWidth: 1))

            Image(systemName: icon)
                .font(.system(size: DesignTokens.GuidedLibrary.iconSize, weight: .light))
                .foregroundStyle(tint)
                .symbolRenderingMode(.hierarchical)
        }
        .accessibilityHidden(true)
    }

    /// Dark mode takes ~2/3 the alpha: what reads as a hint over white reads as
    /// a coloured page over #1E1E1E.
    private var halo: some View {
        let isDark = colorScheme == .dark
        return GeometryReader { proxy in
            let span = max(proxy.size.width, proxy.size.height)
            ZStack {
                RadialGradient(
                    colors: [tint.opacity(isDark ? 0.10 : 0.16), .clear],
                    center: UnitPoint(x: 0.5, y: 0.16),
                    startRadius: 0,
                    endRadius: span * 0.6
                )
                RadialGradient(
                    colors: [tint.opacity(isDark ? 0.05 : 0.09), .clear],
                    center: UnitPoint(x: 0.88, y: 0.92),
                    startRadius: 0,
                    endRadius: span * 0.45
                )
            }
        }
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
