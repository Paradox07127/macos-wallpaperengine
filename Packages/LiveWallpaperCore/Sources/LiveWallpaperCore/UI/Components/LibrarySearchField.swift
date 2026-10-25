import AppKit
import SwiftUI

public struct LibrarySearchField: View {
    @Binding private var text: String
    private let prompt: LocalizedStringKey
    /// Drawn instead of `prompt` while the field is too narrow to hold it; nil keeps `prompt` at any width.
    private let shortPrompt: LocalizedStringKey?
    private let minWidth: CGFloat
    private let idealWidth: CGFloat
    private let maxWidth: CGFloat
    private let isDisabled: Bool
    private let showsFocusRing: Bool
    private let onSubmit: (() -> Void)?
    private let onClear: (() -> Void)?
    /// Optional owner focus for an expandable search control; other callers keep local focus.
    private let focus: FocusState<Bool>.Binding?

    @FocusState private var isFocused: Bool
    @State private var width: CGFloat = 0
    /// The capsule in its window's content, top-left origin.
    @State private var frameInWindow: CGRect = .zero
    @State private var clickMonitor: Any?

    public init(
        text: Binding<String>,
        prompt: LocalizedStringKey,
        shortPrompt: LocalizedStringKey? = nil,
        minWidth: CGFloat = DesignTokens.LibraryFilterBar.searchMinWidth,
        idealWidth: CGFloat = DesignTokens.LibraryFilterBar.searchIdealWidth,
        maxWidth: CGFloat = DesignTokens.LibraryFilterBar.searchMaxWidth,
        isDisabled: Bool = false,
        showsFocusRing: Bool = false,
        onSubmit: (() -> Void)? = nil,
        onClear: (() -> Void)? = nil,
        focus: FocusState<Bool>.Binding? = nil
    ) {
        _text = text
        self.prompt = prompt
        self.shortPrompt = shortPrompt
        self.minWidth = minWidth
        self.idealWidth = idealWidth
        self.maxWidth = maxWidth
        self.isDisabled = isDisabled
        self.showsFocusRing = showsFocusRing
        self.onSubmit = onSubmit
        self.onClear = onClear
        self.focus = focus
    }

    public var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            magnifier

            TextField(shownPrompt, text: $text)
                .textFieldStyle(.plain)
                .font(DesignTokens.Typography.body)
                .focused(focus ?? $isFocused)
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
                        .foregroundStyle(DesignTokens.Colors.textSecondary)
                }
                .buttonStyle(.borderless)
                .help(Text("Clear search"))
                .accessibilityLabel(Text("Clear search"))
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .frame(minWidth: minWidth, idealWidth: idealWidth, maxWidth: maxWidth)
        .frame(height: DesignTokens.LibraryFilterBar.controlHeight)
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { width = $0 }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frameInWindow = $0 }
        .onChange(of: hasFocus) { _, focused in
            if focused {
                watchClicks()
            } else {
                stopWatchingClicks()
            }
        }
        .onDisappear { stopWatchingClicks() }
        .background(Capsule().fill(DesignTokens.Colors.textPrimary.opacity(0.04)))
        .overlay(Capsule().strokeBorder(DesignTokens.Colors.textPrimary.opacity(0.10), lineWidth: 0.5))
        .contentShape(Capsule())
        .overlay {
            if showsFocusRing, hasFocus {
                Capsule().strokeBorder(DesignTokens.Colors.accent, lineWidth: 1.5)
            }
        }
        .opacity(isDisabled ? DesignTokens.Opacity.disabledContent : 1)
        .atlasRole("LibrarySearchField")
    }

    private var hasFocus: Bool {
        focus?.wrappedValue ?? isFocused
    }

    /// AppKit leaves the field editing when a click lands on a view that never takes first responder.
    private func watchClicks() {
        guard clickMonitor == nil else { return }
        let frame = $frameInWindow
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            MainActor.assumeIsolated {
                guard let window = event.window, let content = window.contentView,
                      let field = (window.firstResponder as? NSText)?.delegate as? NSView else { return }
                let fieldFrame = content.convert(field.bounds, from: field)
                let fromTop = CGPoint(x: fieldFrame.midX, y: content.isFlipped ? fieldFrame.midY : content.bounds.height - fieldFrame.midY)
                // Another window's or another field's editing is not this field's to end.
                guard frame.wrappedValue.contains(fromTop) else { return }
                let click = content.convert(event.locationInWindow, from: nil)
                let clickFromTop = CGPoint(x: click.x, y: content.isFlipped ? click.y : content.bounds.height - click.y)
                if !frame.wrappedValue.contains(clickFromTop) {
                    window.makeFirstResponder(nil)
                }
            }
            return event
        }
    }

    private func stopWatchingClicks() {
        guard let clickMonitor else { return }
        NSEvent.removeMonitor(clickMonitor)
        self.clickMonitor = nil
    }

    private var shownPrompt: LocalizedStringKey {
        // `Typography.body` is `Font.body`, which the text field draws in this font.
        guard let shortPrompt,
              !Self.promptFits(Self.localized(prompt), width: width, font: .preferredFont(forTextStyle: .body))
        else { return prompt }
        return shortPrompt
    }

    /// Both horizontal insets, the magnifier (15pt at 2x, 14pt at 1x) and the shared gap; the text field's 2pt
    /// outset on each side cancels its cell's 2pt text inset.
    private static let chrome: CGFloat = 2 * DesignTokens.Spacing.md + 15 + DesignTokens.Spacing.sm

    /// Whether `prompt` drawn in `font` fits unclipped in a field `width` wide.
    static func promptFits(_ prompt: String, width: CGFloat, font: NSFont) -> Bool {
        NSAttributedString(string: prompt, attributes: [.font: font]).size().width <= width - chrome
    }

    /// `LocalizedStringKey` keeps its catalog key private; `key` is the stored key SwiftUI looks up.
    private static func localized(_ prompt: LocalizedStringKey) -> String {
        let key = Mirror(reflecting: prompt).children.first { $0.label == "key" }?.value as? String ?? ""
        return String(localized: String.LocalizationValue(key), bundle: .appLanguage)
    }

    @ViewBuilder
    private var magnifier: some View {
        let glyph = Image(systemName: "magnifyingglass")
            .font(DesignTokens.Glyph.searchMagnifier)
            .foregroundStyle(DesignTokens.Colors.textSecondary)

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
