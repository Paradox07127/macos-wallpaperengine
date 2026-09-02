import SwiftUI

public extension View {
    /// `help` that is attached only while `isHovering`.
    ///
    /// AppKit runs one global tooltip timer: once any tooltip has appeared, moving
    /// to a neighbouring view shows its tooltip immediately. In a grid that means
    /// the first card waits, and then every card the pointer crosses flashes a
    /// tooltip. Mounting the tooltip owner only once the pointer has settled makes
    /// AppKit start its delay again for each card.
    ///
    /// Pair with `settledHover`, whose own delay decides how long "settled" is.
    func settledHelp(_ text: Text, isHovering: Bool) -> some View {
        help(isHovering ? text : Text(verbatim: ""))
    }
}
