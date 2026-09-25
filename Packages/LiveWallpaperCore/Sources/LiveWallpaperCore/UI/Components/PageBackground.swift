import SwiftUI

public extension EnvironmentValues {
    /// True under a window root that paints the canvas every page sits on (the Edit Desk).
    @Entry var windowPaintsCanvas = false
}

public extension View {
    /// A page's own background, left clear where the window root paints the canvas.
    func pageBackground() -> some View {
        modifier(PageBackground())
    }

    /// A content column that stays solid whatever the window paints behind it.
    func contentColumnBackground() -> some View {
        background(DesignTokens.Colors.pageBackground.ignoresSafeArea())
    }
}

private struct PageBackground: ViewModifier {
    @Environment(\.windowPaintsCanvas) private var windowPaintsCanvas

    func body(content: Content) -> some View {
        content.background {
            if !windowPaintsCanvas {
                DesignTokens.Colors.pageBackground.ignoresSafeArea()
            }
        }
    }
}
