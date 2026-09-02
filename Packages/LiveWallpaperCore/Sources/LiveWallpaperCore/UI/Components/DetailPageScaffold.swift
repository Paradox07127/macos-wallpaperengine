import SwiftUI
import AppKit

/// Shared frame for a library page: the page background and the size floor.
///
/// It used to also host an in-page `DetailHeaderBar`. Every library page moved
/// its identity to the toolbar and its search to a floating bar over the grid
/// (2026-09-01), which left the header slot with no callers, so the slot is gone
/// rather than sitting there as a second way to build a page.
public struct DetailPageScaffold<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DesignTokens.Colors.pageBackground)
            .frame(minWidth: DesignTokens.LibraryPage.minWidth, minHeight: DesignTokens.LibraryPage.minHeight)
    }
}

public struct DetailHeaderBar<Title: View, Metadata: View, Actions: View>: View {
    public let systemImage: String
    public let tint: Color
    private let title: Title
    private let metadata: Metadata
    private let actions: Actions

    public init(
        systemImage: String,
        tint: Color = .accentColor,
        @ViewBuilder title: () -> Title,
        @ViewBuilder metadata: () -> Metadata,
        @ViewBuilder actions: () -> Actions
    ) {
        self.systemImage = systemImage
        self.tint = tint
        self.title = title()
        self.metadata = metadata()
        self.actions = actions()
    }

    public var body: some View {
        HStack(alignment: .center, spacing: DesignTokens.DetailHeader.contentSpacing) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.15))
                    .frame(
                        width: DesignTokens.DetailHeader.iconSize,
                        height: DesignTokens.DetailHeader.iconSize
                    )
                Image(systemName: systemImage)
                    .font(.system(size: DesignTokens.DetailHeader.iconSymbolSize))
                    .foregroundStyle(tint)
                    .symbolRenderingMode(.hierarchical)
            }

            VStack(alignment: .leading, spacing: DesignTokens.DetailHeader.textSpacing) {
                title
                    .font(DesignTokens.Typography.pageTitle.weight(.semibold))
                    .lineLimit(1)

                metadata
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .layoutPriority(1)

            Spacer(minLength: DesignTokens.Spacing.md)

            actions
        }
        .padding(.horizontal, DesignTokens.DetailHeader.horizontalPadding)
        .padding(.vertical, DesignTokens.DetailHeader.verticalPadding)
    }
}
