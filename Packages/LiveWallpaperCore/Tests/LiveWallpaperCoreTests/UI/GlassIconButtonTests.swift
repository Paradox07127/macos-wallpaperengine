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

    private static func componentSource() throws -> String {
        // Tests/LiveWallpaperCoreTests/UI/<this file> — the package root is four levels up.
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let path = "Sources/LiveWallpaperCore/UI/Components/GlassIconButton.swift"
        return try String(contentsOf: packageRoot.appendingPathComponent(path), encoding: .utf8)
    }

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

    @Test("Small and large are the HIG minimum and default; extra large is the toolbar's one-key group")
    func diameterLadder() {
        #expect(DesignTokens.iconButtonDiameter(.small) == 20)
        #expect(DesignTokens.iconButtonDiameter(.regular) == 24)
        #expect(DesignTokens.iconButtonDiameter(.large) == 28)
        #expect(DesignTokens.iconButtonDiameter(.mini) == DesignTokens.iconButtonDiameter(.small))
        #expect(DesignTokens.iconButtonDiameter(.extraLarge) == GlassToolbarMetrics.height)
    }

    /// The frame alone keeps `fittingSize` at the token even with the glyph as the label, while the glass
    /// still grows around a large glyph; only the source shows which one sizes the circle.
    @Test("The glyph rides an overlay and the frame is the token")
    func glyphStaysOutOfLayout() throws {
        let source = try Self.componentSource()
        #expect(source.contains("let diameter = DesignTokens.iconButtonDiameter(size)"))
        #expect(source.contains("Color.clear.overlay { Image(systemName: systemImage) }"), "the glyph sizes the glass again")
        #expect(source.contains(".frame(width: diameter, height: diameter)"))
    }
}
