import AppKit
@testable import LiveWallpaper
import LiveWallpaperCore
import SwiftUI
import Testing

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

        // The board is drawn down by the same 0.2, so the pill lands back at its design size.
        #expect(abs(boosted.height * 0.2 - unscaled.height) < 1)
    }
}
