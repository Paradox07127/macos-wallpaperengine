import SwiftUI

/// Standard sheet/popover footer: [destructive] [leading] ··· [cancel] [primary].
/// Primary carries `.defaultAction`, cancel carries `.cancelAction`. Titles come
/// from the caller (resolved against the app catalog) so this component never
/// introduces its own localization keys.
public struct SheetFooterBar<Leading: View>: View {
    private let primaryTitle: LocalizedStringKey
    private let primaryAction: () -> Void
    private let primaryDisabled: Bool
    private let primaryHelp: LocalizedStringKey?
    private let cancelTitle: LocalizedStringKey?
    private let cancelAction: (() -> Void)?
    private let cancelHelp: LocalizedStringKey?
    private let destructiveTitle: LocalizedStringKey?
    private let destructiveAction: (() -> Void)?
    private let leading: Leading

    public init(
        primaryTitle: LocalizedStringKey,
        primaryAction: @escaping () -> Void,
        primaryDisabled: Bool = false,
        primaryHelp: LocalizedStringKey? = nil,
        cancelTitle: LocalizedStringKey? = nil,
        cancelAction: (() -> Void)? = nil,
        cancelHelp: LocalizedStringKey? = nil,
        destructiveTitle: LocalizedStringKey? = nil,
        destructiveAction: (() -> Void)? = nil,
        @ViewBuilder leading: () -> Leading
    ) {
        self.primaryTitle = primaryTitle
        self.primaryAction = primaryAction
        self.primaryDisabled = primaryDisabled
        self.primaryHelp = primaryHelp
        self.cancelTitle = cancelTitle
        self.cancelAction = cancelAction
        self.cancelHelp = cancelHelp
        self.destructiveTitle = destructiveTitle
        self.destructiveAction = destructiveAction
        self.leading = leading()
    }

    public var body: some View {
        VStack(spacing: 0) {
            Divider()

            HStack(spacing: DesignTokens.Spacing.md) {
                if let destructiveTitle, let destructiveAction {
                    Button(role: .destructive, action: destructiveAction) {
                        Text(destructiveTitle)
                    }
                    .buttonStyle(.borderless)
                    .destructiveControlTint()
                }

                leading

                Spacer(minLength: 0)

                if let cancelTitle, let cancelAction {
                    helped(
                        Button(action: cancelAction) {
                            Text(cancelTitle)
                        }
                        .buttonStyle(.bordered)
                        .keyboardShortcut(.cancelAction),
                        cancelHelp
                    )
                }

                helped(
                    Button(action: primaryAction) {
                        Text(primaryTitle)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(primaryDisabled),
                    primaryHelp
                )
            }
            .padding(.horizontal, DesignTokens.Spacing.lg)
            .padding(.vertical, DesignTokens.Spacing.md)
        }
    }

    @ViewBuilder
    private func helped(_ view: some View, _ key: LocalizedStringKey?) -> some View {
        if let key {
            view.help(Text(key))
        } else {
            view
        }
    }
}

public extension SheetFooterBar where Leading == EmptyView {
    init(
        primaryTitle: LocalizedStringKey,
        primaryAction: @escaping () -> Void,
        primaryDisabled: Bool = false,
        primaryHelp: LocalizedStringKey? = nil,
        cancelTitle: LocalizedStringKey? = nil,
        cancelAction: (() -> Void)? = nil,
        cancelHelp: LocalizedStringKey? = nil,
        destructiveTitle: LocalizedStringKey? = nil,
        destructiveAction: (() -> Void)? = nil
    ) {
        self.init(
            primaryTitle: primaryTitle,
            primaryAction: primaryAction,
            primaryDisabled: primaryDisabled,
            primaryHelp: primaryHelp,
            cancelTitle: cancelTitle,
            cancelAction: cancelAction,
            cancelHelp: cancelHelp,
            destructiveTitle: destructiveTitle,
            destructiveAction: destructiveAction,
            leading: { EmptyView() }
        )
    }
}
