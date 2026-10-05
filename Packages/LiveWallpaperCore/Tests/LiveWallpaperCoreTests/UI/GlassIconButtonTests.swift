import AppKit
@testable import LiveWallpaperCore
import SwiftUI
import Testing

/// One circle per control size, whatever the symbol: the token sizes the glass, the glyph does not.
@MainActor
@Suite("Glass icon buttons")
struct GlassIconButtonTests {
    /// Narrow, tall, wide and square glyphs; each gives its own circle when the glyph sizes the button.
    private static let symbols = [
        "link", "doc.on.doc", "arrow.up.forward.app", "xmark", "chevron.left",
        "folder.badge.minus", "backward.end.fill", "square.stack.3d.up", "trash",
    ]

    @Test("Every symbol, plain or prominent, gets its size's token circle")
    func circleComesFromTheToken() {
        let sizes: [(ControlSize, String)] = [(.small, "small"), (.regular, "regular"), (.large, "large")]
        for (size, name) in sizes {
            let diameter = DesignTokens.iconButtonDiameter(size)
            for symbol in Self.symbols {
                for prominence in [AdaptiveGlassProminence.regular, .prominent] {
                    let fitting = NSHostingView(rootView: GlassIconButton(symbol, prominence: prominence, size: size) {}).fittingSize
                    #expect(
                        fitting == CGSize(width: diameter, height: diameter),
                        "\(symbol) at \(name), \(prominence): \(fitting)"
                    )
                }
            }
        }
    }

}
