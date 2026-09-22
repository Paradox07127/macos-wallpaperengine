import AppKit
import LiveWallpaperCore
import SwiftUI

/// The Edit Desk's canvas. `frosted` swaps the flat fill for the desktop blurred behind the window;
/// Reduce Transparency falls back to the flat fill, because a see-through canvas is exactly what
/// that setting asks us not to do.
struct EditDeskBackdrop: View {
    let frosted: Bool

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            if frosted, !reduceTransparency {
                BehindWindowBlur()
            } else {
                DesignTokens.EditDesk.Colors.background
            }
            Image(nsImage: Self.dotTile)
                .resizable(resizingMode: .tile)
        }
        .ignoresSafeArea()
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

    /// The band's background, so it leads the chrome that sits over it.
    static func opacity(_ progress: Double) -> Double {
        HomeHints.ramp(progress, from: 0.05, to: 0.6)
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
