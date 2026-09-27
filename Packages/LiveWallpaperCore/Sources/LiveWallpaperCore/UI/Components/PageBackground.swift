import SwiftUI

public extension View {
    /// A content column that stays solid whatever the window paints behind it.
    func contentColumnBackground() -> some View {
        background(DesignTokens.Colors.pageBackground.ignoresSafeArea())
    }
}
