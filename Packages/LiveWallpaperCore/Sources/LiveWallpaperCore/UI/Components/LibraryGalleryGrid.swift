import SwiftUI

/// Tiles pack from the leading edge in fixed-width columns; whatever width is left over
/// stays empty on the trailing side instead of re-centring or stretching the tiles.
public struct LibraryGalleryGrid<Content: View>: View {
    private let size: LibraryTileSize
    private let aspect: DesignTokens.LibraryGrid.Aspect
    private let content: Content
    @State private var availableWidth: CGFloat

    public init(
        size: LibraryTileSize,
        aspect: DesignTokens.LibraryGrid.Aspect,
        initialWidth: CGFloat = 0,
        @ViewBuilder content: () -> Content
    ) {
        self.size = size
        self.aspect = aspect
        self.content = content()
        _availableWidth = State(initialValue: initialWidth)
    }

    public var body: some View {
        LazyVGrid(
            columns: DesignTokens.LibraryGrid.columns(for: size, aspect: aspect, fitting: availableWidth),
            alignment: .leading,
            spacing: DesignTokens.LibraryGrid.spacing
        ) {
            content
        }
        // Measured on the full-width frame, not the grid: fixed columns would report their own packed
        // width back. `minWidth: 0` keeps that packed width out of the hosting window's minimum size,
        // which would otherwise stop the window shrinking below the current column count.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { availableWidth = $0 }
    }
}
