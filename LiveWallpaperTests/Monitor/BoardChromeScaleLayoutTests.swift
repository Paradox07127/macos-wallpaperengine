import AppKit
@testable import LiveWallpaper
import LiveWallpaperCore
import SwiftUI
import Testing

/// The arithmetic in `BoardChromeScaleTests` only says what the numbers should
/// be. This lays the real chrome out through `NSHostingView` and measures the
/// box it claims, because the boost is worth nothing if the modifier reports its
/// pre-scale size — the placement clamps would then push panels off the board.
@Suite("Monitor board edit-chrome layout")
@MainActor
struct BoardChromeScaleLayoutTests {
    private func fittingSize(renderScale: CGFloat) -> CGSize {
        let model = InteractionModel(configuration: MonitorBoardConfiguration(widgets: []))
        model.setEditing(true)
        let view = MonitorBoardEditToolbar(model: model, showsDone: false)
            .monitorChromeScaled()
            .environment(\.monitorRenderScale, renderScale)
        let host = NSHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    @Test("the toolbar claims a box the boost has already grown")
    func toolbarBoxGrowsWithTheBoost() {
        let unscaled = fittingSize(renderScale: 1)
        #expect(unscaled.height > 0, "nothing laid out; this suite proves nothing")

        let boosted = fittingSize(renderScale: 0.2)
        let boost = MonitorChromeScale.boost(forRenderScale: 0.2)
        #expect(abs(boosted.height - unscaled.height * boost) < 1)
        #expect(abs(boosted.width - unscaled.width * boost) < 1)

        // What the user ends up looking at: the board is drawn down by the same
        // 0.2, so the pill lands back at the size it was designed at.
        #expect(abs(boosted.height * 0.2 - unscaled.height) < 1)
    }
}
