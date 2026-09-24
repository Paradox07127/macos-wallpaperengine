import LiveWallpaperCore
import SwiftUI

extension View {
    /// `.popover` whose content reads the in-app language: a popover does not inherit `\.locale` from the window.
    func appLanguagePopover(
        isPresented: Binding<Bool>, arrowEdge: Edge, @ViewBuilder content: @escaping () -> some View
    ) -> some View {
        popover(isPresented: isPresented, arrowEdge: arrowEdge) {
            AppLanguageScope(defaults: .appScoped()) {
                content()
            }
        }
    }
}
