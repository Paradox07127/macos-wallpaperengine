import AppKit
import LiveWallpaperCore
import SwiftUI

/// The Edit Desk window's canvas. `frosted` swaps the flat fill for the desktop blurred behind the
/// window; Reduce Transparency and Increase Contrast keep the flat fill, which is what both settings ask for.
struct EditDeskBackdrop: View {
    let frosted: Bool

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Group {
            if frosted, !reduceTransparency, contrast != .increased {
                BehindWindowBlur()
            } else {
                DesignTokens.EditDesk.Colors.background
            }
        }
        .ignoresSafeArea()
    }
}

/// The overview's and the library's dot texture, drawn by `HomePage` over the window's canvas.
struct EditDeskDotGrid: View {
    var body: some View {
        Image(nsImage: Self.dotTile)
            .resizable(resizingMode: .tile)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// A SwiftUI layer rather than the stage's own `backgroundColor`: an opaque stage would force
    /// every piece of chrome above the shelf cards.
    private static let dotTile = NSImage(size: CGSize(width: 24, height: 24), flipped: true) { _ in
        NSColor(DesignTokens.EditDesk.Colors.dotGrid).setFill()
        NSBezierPath(ovalIn: CGRect(x: 11, y: 11, width: 2, height: 2)).fill()
        return true
    }
}

/// SCREENS S2: the shelf band darkens from transparent to scrim over the bottom 30%. Outside the
/// stage so the chip row can sit over it and still be under the cards.
struct EditDeskShelfScrim: View {
    /// Read per frame in `body` rather than handed in, so a moving gesture invalidates this view
    /// instead of the whole page.
    let stage: EditDeskStageModel

    /// The band's background, so it leads the chrome that sits over it; it leaves with the cards,
    /// so the grid's opaque page takes over from a clear band.
    static func opacity(_ progress: Double) -> Double {
        HomeHints.ramp(progress, from: 0.05, to: 0.6) * (1 - HomeHints.ramp(progress, from: 1, to: 2))
    }

    var body: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: DesignTokens.EditDesk.Colors.shelfScrim, location: 0.7),
            ],
            startPoint: .top, endPoint: .bottom
        )
        .frame(height: StageGeometry.shelfHeight)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .opacity(Self.opacity(stage.progress))
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}

/// Lights the shelf band while a Finder file over it would only join the library, in the look a
/// display takes for "drop to replace".
struct ShelfDropHighlight: View {
    /// Read per frame in `body`, as `EditDeskShelfScrim` does, so the band rides the rising shelf.
    let stage: EditDeskStageModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DesignTokens.EditDesk.Corner.panelLarge)
        shape
            .fill(DesignTokens.EditDesk.Colors.dropHighlight)
            .overlay { shape.strokeBorder(DesignTokens.EditDesk.Colors.success, lineWidth: 2) }
            .shadow(color: DesignTokens.EditDesk.Colors.dropHighlightGlow, radius: 30)
            .overlay {
                Text("Add to Library")
                    .font(DesignTokens.EditDesk.Typography.dropLabel)
                    .foregroundStyle(DesignTokens.Colors.overlayForeground)
                    .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
            }
            .opacity(stage.shelfDropTargeted ? 1 : 0)
            // Inside the placement below, so only the fade animates: the band follows the shelf frame by frame.
            .animation(reduceMotion ? .linear(duration: 0.15) : .easeOut(duration: 0.18), value: stage.shelfDropTargeted)
            .frame(height: StageGeometry.cardSize.height + 2 * DesignTokens.EditDesk.Spacing.s12)
            .padding(.horizontal, DesignTokens.EditDesk.Spacing.gutter)
            .frame(maxHeight: .infinity, alignment: .top)
            .offset(y: StageGeometry.shelfRowTop(progress: stage.progress, windowSize: stage.stageSize) - DesignTokens.EditDesk.Spacing.s12)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct BehindWindowBlur: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context _: Context) {
        view.state = .active
    }
}
