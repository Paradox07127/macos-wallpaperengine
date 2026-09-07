import SwiftUI

/// Page identity in the toolbar's center. The main window hides its native title,
/// so the identity needs an explicit toolbar view.
struct LibraryIdentityLabel: View {
    private let systemImage: String
    private let title: Text

    init(systemImage: String, title: Text) {
        self.systemImage = systemImage
        self.title = title
    }

    var body: some View {
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

/// The title stays outside the shared toolbar capsule on macOS 26 and later.
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
