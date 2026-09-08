import SwiftUI

public extension View {
    /// Attach help after settledHover activates the card, so crossing a grid
    /// does not immediately show each neighboring tooltip.
    func settledHelp(_ text: Text, isHovering: Bool) -> some View {
        help(isHovering ? text : Text(verbatim: ""))
    }
}
