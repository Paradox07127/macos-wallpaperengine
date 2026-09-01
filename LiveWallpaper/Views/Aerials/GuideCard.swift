import LiveWallpaperCore
import SwiftUI

struct LibraryGuideFeature: Equatable {
    let icon: String
    let text: LocalizedStringKey
}

struct LibraryGuideCard: View {
    let icon: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    let features: [LibraryGuideFeature]
    let actionTitle: LocalizedStringKey
    let actionSystemImage: String
    let secondaryTitle: LocalizedStringKey?
    let secondarySystemImage: String?
    let isActionInProgress: Bool
    let errorMessage: String?
    let action: () -> Void
    let secondaryAction: (() -> Void)?

    init(
        icon: String,
        title: LocalizedStringKey,
        message: LocalizedStringKey,
        features: [LibraryGuideFeature],
        actionTitle: LocalizedStringKey,
        actionSystemImage: String,
        secondaryTitle: LocalizedStringKey? = nil,
        secondarySystemImage: String? = nil,
        isActionInProgress: Bool = false,
        errorMessage: String? = nil,
        action: @escaping () -> Void,
        secondaryAction: (() -> Void)? = nil
    ) {
        self.icon = icon
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
            Spacer().frame(height: DesignTokens.GuidedLibrary.topSpacerHeight)

            Image(systemName: icon)
                .font(.system(size: DesignTokens.GuidedLibrary.iconSize, weight: .light))
                .foregroundStyle(Color.accentColor)
                .symbolRenderingMode(.hierarchical)

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

            HStack(spacing: 10) {
                Button(action: action) {
                    HStack(spacing: 8) {
                        if isActionInProgress {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Label(actionTitle, systemImage: actionSystemImage)
                            .frame(minWidth: 132)
                    }
                }
                .buttonStyle(CapsuleButtonStyle(preset: .large))
                .disabled(isActionInProgress)
                .keyboardShortcut(.defaultAction)

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

    private func featureRow(_ feature: LibraryGuideFeature) -> some View {
        HStack(spacing: 12) {
            Image(systemName: feature.icon)
                .font(DesignTokens.Typography.body.weight(.medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 22)
                .symbolRenderingMode(.hierarchical)

            Text(feature.text)
                .font(DesignTokens.Typography.body)
                .foregroundStyle(.primary)
        }
    }
}
