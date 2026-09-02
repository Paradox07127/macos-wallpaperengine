import SwiftUI

/// The page's name and glyph, for the toolbar's leading edge.
///
/// Not `.navigationTitle`. The main window is a hand-built `NSWindow` with
/// `titleVisibility = .hidden`, and SwiftUI does not override that: probed on
/// 2026-09-01, `.navigationTitle` / `.navigationSubtitle` do reach `window.title`
/// and `window.subtitle`, but AppKit never draws them. An explicit toolbar view
/// is the only placement that actually renders.
///
/// Centred, not leading: the leading slot already holds the window's gear button,
/// and macOS 26 draws one shared capsule around every item in a slot — so a title
/// placed there came out inside a control cluster. Centre matches the pages that
/// switch scopes with a capsule (Workshop, Saved), so all five library pages name
/// themselves in the same place.
public struct LibraryIdentityLabel: View {
    private let systemImage: String
    private let title: Text

    public init(systemImage: String, title: Text) {
        self.systemImage = systemImage
        self.title = title
    }

    public var body: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Image(systemName: systemImage)
                .font(DesignTokens.Typography.body)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            title
                .font(DesignTokens.Typography.bodyEmphasized)
                .lineLimit(1)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// The identity label as a toolbar item, opted out of the slot's shared capsule
/// where the OS supports it.
///
/// `sharedBackgroundVisibility` is macOS 26 and this app deploys to 14.6, so the
/// older path just places the label; there is no shared capsule to escape there.
public struct LibraryIdentityToolbarItem: ToolbarContent {
    private let systemImage: String
    private let title: Text

    public init(systemImage: String, title: Text) {
        self.systemImage = systemImage
        self.title = title
    }

    public var body: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .principal) {
                LibraryIdentityLabel(systemImage: systemImage, title: title)
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .principal) {
                LibraryIdentityLabel(systemImage: systemImage, title: title)
            }
        }
    }
}
