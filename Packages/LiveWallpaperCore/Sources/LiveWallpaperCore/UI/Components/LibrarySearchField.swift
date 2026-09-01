import SwiftUI

/// Shared search capsule for library filter bars (`LibraryFilterBar`, the
/// Workshop Browse ribbon). Owns only the visual shell — magnifier, text
/// field, clear button, capsule chrome. Submit/clear/debounce behavior stays
/// with the caller through the closure slots: `onSubmit` (Return key, and it
/// also turns the magnifier into a submit button) and `onClear` (replaces the
/// default `text = ""`).
public struct LibrarySearchField: View {
    @Binding private var text: String
    private let prompt: LocalizedStringKey
    private let minWidth: CGFloat
    private let idealWidth: CGFloat
    private let maxWidth: CGFloat
    private let isDisabled: Bool
    private let showsFocusRing: Bool
    private let onSubmit: (() -> Void)?
    private let onClear: (() -> Void)?

    @FocusState private var isFocused: Bool

    public init(
        text: Binding<String>,
        prompt: LocalizedStringKey,
        minWidth: CGFloat = DesignTokens.LibraryFilterBar.searchMinWidth,
        idealWidth: CGFloat = DesignTokens.LibraryFilterBar.searchIdealWidth,
        maxWidth: CGFloat = DesignTokens.LibraryFilterBar.searchMaxWidth,
        isDisabled: Bool = false,
        showsFocusRing: Bool = false,
        onSubmit: (() -> Void)? = nil,
        onClear: (() -> Void)? = nil
    ) {
        _text = text
        self.prompt = prompt
        self.minWidth = minWidth
        self.idealWidth = idealWidth
        self.maxWidth = maxWidth
        self.isDisabled = isDisabled
        self.showsFocusRing = showsFocusRing
        self.onSubmit = onSubmit
        self.onClear = onClear
    }

    public var body: some View {
        HStack(spacing: 7) {
            magnifier

            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(DesignTokens.Typography.body)
                .focused($isFocused)
                .disabled(isDisabled)
                .onSubmit { onSubmit?() }
                .accessibilityLabel(Text(prompt))

            if !text.isEmpty {
                Button {
                    if let onClear {
                        onClear()
                    } else {
                        text = ""
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(DesignTokens.Typography.captionEmphasized)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help(Text("Clear search"))
                .accessibilityLabel(Text("Clear search"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(minWidth: minWidth, idealWidth: idealWidth, maxWidth: maxWidth)
        .background(Capsule().fill(Color.primary.opacity(0.04)))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
        .contentShape(Capsule())
        .overlay {
            if showsFocusRing, isFocused {
                Capsule().strokeBorder(Color.accentColor, lineWidth: 1.5)
            }
        }
        .opacity(isDisabled ? 0.5 : 1)
    }

    /// Decorative glyph by default; a borderless submit button when the
    /// caller provides `onSubmit` (Workshop Browse: clicking the glass skips
    /// the debounce and searches now).
    @ViewBuilder
    private var magnifier: some View {
        let glyph = Image(systemName: "magnifyingglass")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)

        if let onSubmit {
            Button(action: onSubmit) { glyph }
                .buttonStyle(.borderless)
                .disabled(isDisabled)
                .help(Text("Search"))
        } else {
            glyph.accessibilityHidden(true)
        }
    }
}
