import LiveWallpaperCore
import SwiftUI

/// Full-page library setup or empty state. Use `IllustratedEmptyState` for no matches.
struct LibraryGuideCard: View {
    let icon: String
    let tint: Color
    let title: LocalizedStringKey
    let message: LocalizedStringKey?
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
        message: LocalizedStringKey? = nil,
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

                if let message {
                    Text(message)
                        .font(DesignTokens.Typography.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: DesignTokens.GuidedLibrary.messageWidth)
                }
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

    private var hero: some View {
        let disc = DesignTokens.GuidedLibrary.iconSize * 2.125
        return ZStack {
            Circle()
                .fill(tint.opacity(0.12))
                .frame(width: disc, height: disc)
                .overlay(Circle().strokeBorder(tint.opacity(0.18), lineWidth: 1))

            Image(systemName: icon)
                .font(.system(size: DesignTokens.GuidedLibrary.iconSize, weight: .light))
                .foregroundStyle(tint)
                .symbolRenderingMode(.hierarchical)
        }
        .accessibilityHidden(true)
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

}
