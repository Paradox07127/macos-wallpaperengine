import AppKit
import LiveWallpaperCore
import SwiftUI

/// The web wallpaper's "nothing picked yet" page.
///
/// Shares the `IllustratedEmptyState(.dropTarget)` skeleton with the video empty
/// state next door, so switching wallpaper type does not switch layout language.
/// URL is the dominant path and gets an address-bar-shaped field; local files are
/// a secondary link plus the page-wide drop target `DetailView` already routes
/// (`WallpaperImportRouter` → `.html`).
///
/// Both button slots are deliberately empty. The skeleton renders
/// `icon → text → buttons → extra`, so putting "Choose Local File" in `secondary`
/// would place the secondary path ABOVE the address bar, and a composite field
/// cannot live inside the slot's `.borderedProminent` Button anyway.
struct HTMLEmptyState: View {
    var screen: Screen
    var config: HTMLConfig

    @Environment(ScreenManager.self) private var screenManager

    @State private var urlInput: String = ""
    @FocusState private var addressFieldFocused: Bool

    /// Wide enough for a real URL without becoming a full-width form field —
    /// the skeleton's own text column is 360, so the bar reads as the anchored
    /// base of the composition rather than another paragraph.
    private let addressBarWidth: CGFloat = 420
    /// Narrower than the bar so the separator reads as a step down in weight.
    private let dividerWidth: CGFloat = 280

    var body: some View {
        IllustratedEmptyState(
            symbol: "globe",
            title: "Set a Web Wallpaper",
            message: "Enter a web address, or drop a folder containing index.html here.",
            symbolColor: .accentColor,
            variant: .dropTarget
        ) {
            VStack(spacing: DesignTokens.Spacing.md) {
                addressBar
                orDivider
                chooseLocalButton
            }
            .padding(.top, DesignTokens.Spacing.lg)
        }
        .onAppear {
            // One hop: at first `onAppear` the window's responder chain and the
            // backing NSTextField are not necessarily mounted yet, and the
            // assignment is silently dropped. Same reason `HTMLSourceSection`
            // defers its binding sync.
            DispatchQueue.main.async { addressFieldFocused = true }
        }
    }

    // MARK: - Address bar

    private var addressBar: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Image(systemName: "link")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            // `.plain` strips AppKit's own bezel so the surrounding capsule is the
            // only frame — a bordered field inside a drawn one reads as two boxes.
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
                // Not `Card.strokeWidth` (0.5): that token is the hairline for card
                // chrome, and a field border needs to read at a glance.
                .strokeBorder(
                    addressFieldFocused ? Color.accentColor : DesignTokens.Colors.separator,
                    lineWidth: addressFieldFocused ? 1.5 : 1
                )
        )
        .frame(maxWidth: addressBarWidth)
    }

    /// Requires a value that actually parses, not just a non-empty one: `commitURL`
    /// returns silently when `HTMLSource(userInput:)` fails, so gating on emptiness
    /// alone left "foo" + Return doing nothing with no feedback at all. Now the
    /// arrow lighting up IS the feedback that the address is usable.
    private var canCommit: Bool {
        HTMLSource(userInput: urlInput.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
    }

    // MARK: - Secondary path

    /// Spells out that the two paths are alternatives. Without it, a field stacked
    /// over a button reads as "step 1, then step 2".
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
        let trimmed = urlInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = HTMLSource(userInput: trimmed) else { return }
        screenManager.setHTMLWallpaper(source: parsed, config: config, for: screen)
    }

    /// Commits straight away when the pasted value already parses; otherwise it
    /// just fills the field so the user can finish editing it.
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
