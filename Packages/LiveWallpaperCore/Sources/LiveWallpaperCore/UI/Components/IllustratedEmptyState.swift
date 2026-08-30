import SwiftUI

public enum EmptyStateVariant {
    case standard
    /// Renders a solid accent-tinted drop-target frame so the affordance is discoverable without
    /// dragging anything onto the area first. Pairs with the active `dragHintOverlay` in
    /// `PreviewArea` — the empty state is the ambient/idle state, the overlay is the stronger
    /// activated state, sharing the same shape and accent.
    case dropTarget
    /// Compact (denser padding, smaller icon) for use inside inspector rows.
    case compact
}

public struct EmptyStateButtonAction {
    public let title: LocalizedStringKey
    public let role: ButtonRole?
    public let action: () -> Void

    public init(_ title: LocalizedStringKey, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.title = title
        self.role = role
        self.action = action
    }
}

/// Standard illustrated empty state: icon + title + optional message + up to
/// two actions, plus an optional `extra` slot for state-specific fine print
/// (links, verbatim strings) so complex states don't fork the whole layout.
public struct IllustratedEmptyState<Extra: View>: View {
    let symbol: String
    let title: Text
    let message: Text?
    let symbolColor: Color
    let primary: EmptyStateButtonAction?
    let secondary: EmptyStateButtonAction?
    let variant: EmptyStateVariant
    let extra: Extra

    public init(
        symbol: String,
        title: LocalizedStringKey,
        message: LocalizedStringKey? = nil,
        symbolColor: Color = .secondary,
        primary: EmptyStateButtonAction? = nil,
        secondary: EmptyStateButtonAction? = nil,
        variant: EmptyStateVariant = .standard,
        @ViewBuilder extra: () -> Extra
    ) {
        self.symbol = symbol
        self.title = Text(title)
        self.message = message.map { Text($0) }
        self.symbolColor = symbolColor
        self.primary = primary
        self.secondary = secondary
        self.variant = variant
        self.extra = extra()
    }

    /// Verbatim variant for already-resolved runtime strings (e.g. an
    /// interpolated "No results for …" message) that must not be re-looked-up
    /// in the localization catalog.
    public init(
        symbol: String,
        verbatimTitle: String,
        message: LocalizedStringKey? = nil,
        symbolColor: Color = .secondary,
        primary: EmptyStateButtonAction? = nil,
        secondary: EmptyStateButtonAction? = nil,
        variant: EmptyStateVariant = .standard,
        @ViewBuilder extra: () -> Extra
    ) {
        self.symbol = symbol
        self.title = Text(verbatim: verbatimTitle)
        self.message = message.map { Text($0) }
        self.symbolColor = symbolColor
        self.primary = primary
        self.secondary = secondary
        self.variant = variant
        self.extra = extra()
    }

    public var body: some View {
        VStack(spacing: spacing) {
            Image(systemName: symbol)
                .font(.system(size: iconSize, weight: .regular))
                .foregroundStyle(symbolColor)
                .accessibilityHidden(true)

            VStack(spacing: DesignTokens.Spacing.xxs) {
                title
                    .font(titleFont)
                    .fontWeight(.semibold)
                    .multilineTextAlignment(.center)
                if let message {
                    message
                        .font(messageFont)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: 360)

            if primary != nil || secondary != nil {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    if let primary {
                        Button(role: primary.role, action: primary.action) {
                            Text(primary.title)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    if let secondary {
                        Button(role: secondary.role, action: secondary.action) {
                            Text(secondary.title)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(.top, DesignTokens.Spacing.xs)
            }

            extra
        }
        .padding(verticalPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            if case .dropTarget = variant {
                ZStack {
                    RoundedRectangle(cornerRadius: DesignTokens.Corner.preview, style: .continuous)
                        .fill(Color.accentColor.opacity(0.04))
                    RoundedRectangle(cornerRadius: DesignTokens.Corner.preview, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.32), lineWidth: 1)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var iconSize: CGFloat {
        switch variant {
        case .standard, .dropTarget: return 44
        case .compact: return 28
        }
    }

    private var spacing: CGFloat {
        switch variant {
        case .standard, .dropTarget: return DesignTokens.Spacing.md
        case .compact: return DesignTokens.Spacing.sm
        }
    }

    private var verticalPadding: CGFloat {
        switch variant {
        case .standard, .dropTarget: return DesignTokens.Spacing.xl
        case .compact: return DesignTokens.Spacing.md
        }
    }

    private var titleFont: Font {
        switch variant {
        case .standard, .dropTarget: return .headline
        case .compact: return .subheadline
        }
    }

    private var messageFont: Font {
        switch variant {
        case .standard, .dropTarget: return .footnote
        case .compact: return .footnote
        }
    }
}

extension IllustratedEmptyState where Extra == EmptyView {
    public init(
        symbol: String,
        title: LocalizedStringKey,
        message: LocalizedStringKey? = nil,
        symbolColor: Color = .secondary,
        primary: EmptyStateButtonAction? = nil,
        secondary: EmptyStateButtonAction? = nil,
        variant: EmptyStateVariant = .standard
    ) {
        self.init(
            symbol: symbol,
            title: title,
            message: message,
            symbolColor: symbolColor,
            primary: primary,
            secondary: secondary,
            variant: variant,
            extra: { EmptyView() }
        )
    }

    public init(
        symbol: String,
        verbatimTitle: String,
        message: LocalizedStringKey? = nil,
        symbolColor: Color = .secondary,
        primary: EmptyStateButtonAction? = nil,
        secondary: EmptyStateButtonAction? = nil,
        variant: EmptyStateVariant = .standard
    ) {
        self.init(
            symbol: symbol,
            verbatimTitle: verbatimTitle,
            message: message,
            symbolColor: symbolColor,
            primary: primary,
            secondary: secondary,
            variant: variant,
            extra: { EmptyView() }
        )
    }
}
