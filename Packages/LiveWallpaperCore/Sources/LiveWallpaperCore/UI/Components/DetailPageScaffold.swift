import SwiftUI
import AppKit

/// Page identity belongs in the toolbar, not here.
public struct DetailPageScaffold<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .pageBackground()
            .frame(minWidth: DesignTokens.LibraryPage.minWidth, minHeight: DesignTokens.LibraryPage.minHeight)
    }
}
