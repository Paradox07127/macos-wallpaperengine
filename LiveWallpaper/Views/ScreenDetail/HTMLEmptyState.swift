import AppKit
import LiveWallpaperCore
import SwiftUI

/// Both button slots are deliberately empty: the skeleton renders
/// `icon → text → buttons → extra`, so "Choose Local File" in `secondary` would
/// sit ABOVE the address bar, and a composite field cannot live in that Button.
struct HTMLEmptyState: View {
    var screen: Screen
    var config: HTMLConfig

    @Environment(ScreenManager.self) private var screenManager

    @State private var urlInput: String = ""
    @FocusState private var addressFieldFocused: Bool

    /// 420 against the skeleton's own 360pt text column, so the bar reads as the
    /// anchored base rather than another paragraph.
    private let addressBarWidth: CGFloat = 420
    private let dividerWidth: CGFloat = 280

    var body: some View {
        IllustratedEmptyState(
            symbol: "globe",
            title: "Set a Web Wallpaper",
            message: "Enter a web address, or drop a folder containing index.html here.",
            symbolColor: .accentColor,
            variant: .dropTarget,
            accessibilityChildren: .contain
        ) {
            VStack(spacing: DesignTokens.Spacing.md) {
                addressBar
                orDivider
                chooseLocalButton
            }
            .padding(.top, DesignTokens.Spacing.lg)
        }
        .onAppear {
            // One hop: at first `onAppear` the backing NSTextField may not be mounted
            // yet and the assignment is silently dropped.
            DispatchQueue.main.async { addressFieldFocused = true }
        }
    }

    // MARK: - Address bar

    private var addressBar: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Image(systemName: "link")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField("example.com", text: $urlInput)
                .textFieldStyle(.plain)
                .font(DesignTokens.Typography.body)
                .focused($addressFieldFocused)
                .onSubmit(commitURL)
                .accessibilityLabel(Text("Web address"))

            Button(action: pasteFromClipboard) {
                Image(systemName: "doc.on.clipboard")
            }
            .buttonStyle(.borderless)
            .help(Text("Paste URL from clipboard"))
            .accessibilityLabel(Text("Paste URL from clipboard"))

            Button(action: commitURL) {
                Image(systemName: "arrow.forward.circle.fill")
                    .foregroundStyle(canCommit ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.borderless)
            .disabled(!canCommit)
            .help(Text("Use this web address"))
            .accessibilityLabel(Text("Use this web address"))
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Corner.md, style: .continuous)
                .fill(DesignTokens.Colors.surfaceRaised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Corner.md, style: .continuous)
                .strokeBorder(
                    addressFieldFocused ? Color.accentColor : DesignTokens.Colors.separator,
                    lineWidth: addressFieldFocused ? 1.5 : 1
                )
        )
        .frame(maxWidth: addressBarWidth)
    }

    /// Only a URL: `HTMLSource(userInput:)` turns any other non-empty text into
    /// `.inline`, so "foo" + Return would set the desktop to a page reading "foo".
    private var canCommit: Bool {
        parsedURL != nil
    }

    private var parsedURL: HTMLSource? {
        let source = HTMLSource(userInput: urlInput.trimmingCharacters(in: .whitespacesAndNewlines))
        guard case .url? = source else { return nil }
        return source
    }

    // MARK: - Secondary path

    private var orDivider: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            dividerRule
            Text("or")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(.secondary)
            dividerRule
        }
        .frame(maxWidth: dividerWidth)
        .accessibilityHidden(true)
    }

    private var dividerRule: some View {
        Rectangle()
            .fill(DesignTokens.Colors.separator)
            .frame(height: 1)
    }

    private var chooseLocalButton: some View {
        Button {
            HTMLLocalSourcePicker.pick { source in
                screenManager.setHTMLWallpaper(source: source, config: config, for: screen)
            }
        } label: {
            Label("Choose Local File…", systemImage: "folder")
                .font(DesignTokens.Typography.body)
        }
        .buttonStyle(.borderless)
    }

    // MARK: - Actions

    private func commitURL() {
        guard let parsed = parsedURL else { return }
        screenManager.setHTMLWallpaper(source: parsed, config: config, for: screen)
    }

    private func pasteFromClipboard() {
        guard let raw = NSPasteboard.general.string(forType: .string) else { return }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        urlInput = trimmed
        if case .url = HTMLSource(userInput: trimmed) {
            commitURL()
        }
    }
}
