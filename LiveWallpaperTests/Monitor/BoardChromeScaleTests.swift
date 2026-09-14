import CoreGraphics
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

@Suite("Monitor board edit-chrome scale")
struct BoardChromeScaleTests {
    /// A 5K display's points, drawn into an inspector canvas.
    private let board = CGSize(width: 2560, height: 1440)
    private let fifth: CGFloat = 0.2

    // MARK: Boost

    @Test("the boost is the exact inverse of the shrink")
    func boostInvertsTheShrink() {
        #expect(MonitorChromeScale.boost(forRenderScale: 0.2) == 5)
        #expect(MonitorChromeScale.boost(forRenderScale: 0.5) == 2)
    }

    @Test("a board drawn at its own size gets no boost")
    func desktopIsUntouched() {
        #expect(MonitorChromeScale.boost(forRenderScale: 1) == 1)
        // Chrome is never grown past its design size, so a magnified board must not shrink it.
        #expect(MonitorChromeScale.boost(forRenderScale: 2) == 1)
    }

    @Test("a degenerate scale cannot ask for an unbounded boost")
    func degenerateScalesAreBounded() {
        #expect(MonitorChromeScale.boost(forRenderScale: 0) == 1)
        #expect(MonitorChromeScale.boost(forRenderScale: -0.5) == 1)
        #expect(MonitorChromeScale.boost(forRenderScale: .nan) == 1)
        #expect(MonitorChromeScale.boost(forRenderScale: 0.0001) == MonitorChromeScale.maxBoost)
    }

    // MARK: Screen-point size

    @Test("the control bar keeps its design size on screen at preview scale")
    func controlBarStaysHittable() {
        let metrics = MonitorBoardChromeMetrics(boardSize: board, renderScale: fifth)
        let estimate = metrics.controlBarEstimate(for: .cpu)
        // Placement happens in board points, so the box grows there.
        #expect(estimate.height == 180)
        #expect(abs(estimate.height * fifth - 36) < 0.001)

        // The control: without the boost the same bar draws under 8 points.
        let unboosted = MonitorBoardChromeMetrics(boardSize: board, renderScale: 1)
        #expect(unboosted.controlBarEstimate(for: .cpu).height * fifth < 8)
    }

    @Test("boosted chrome still fits the canvas it is drawn into")
    func chromeFitsTheCanvas() {
        let metrics = MonitorBoardChromeMetrics(boardSize: board, renderScale: fifth)
        let canvas = CGSize(width: board.width * fifth, height: board.height * fifth)

        // catalogWidth is in screen points, so it is measured against the canvas, not the desktop.
        #expect(metrics.catalogWidth <= canvas.width)
        #expect(abs(metrics.catalogWidth - canvas.width * 0.86) < 0.001)
        #expect(metrics.settingsCardMaxHeight <= canvas.height)
        #expect(MonitorWidgetSettingsCard.cardWidth <= canvas.width)

        // The control: the old board-point width would be five canvases wide.
        let unboosted = MonitorBoardChromeMetrics(boardSize: board, renderScale: 1)
        #expect(unboosted.catalogWidth > canvas.width)
    }

    // MARK: Desktop parity

    @Test("at 1:1 every metric is the board-point value the desktop always used")
    func desktopValuesAreUnchanged() {
        let metrics = MonitorBoardChromeMetrics(boardSize: board, renderScale: 1)
        #expect(metrics.boost == 1)
        #expect(metrics.chromeSpace == board)
        #expect(metrics.board(8) == 8)
        #expect(metrics.catalogWidth == min(760, board.width * 0.86))
        #expect(metrics.settingsCardMaxHeight == board.height - 16)
        #expect(metrics.toolbarTopInset == min(max(board.height * 0.035, 44), 60))
        #expect(metrics.controlBarEstimate(for: .cpu) == CGSize(width: 68 + 3 * 30 + 16, height: 36))
        #expect(metrics.controlBarEstimate(for: .power) == CGSize(width: 68 + 2 * 30 + 16, height: 36))
        #expect(metrics.catalogScrollCap(anchorMaxY: 100) == max(min(board.height * 0.55, board.height - 100 - 80), 80))
    }

    // MARK: Catalog anchor

    /// The Add Widget frame arrives in the toolbar's own points, so it is expanded about
    /// the toolbar's board origin.
    @Test("the catalog anchors under the button as it is actually drawn")
    func catalogAnchorFollowsTheDrawnButton() {
        let metrics = MonitorBoardChromeMetrics(boardSize: board, renderScale: fifth)
        let toolbar = CGRect(x: 1000, y: 50, width: 700, height: 170)
        let button = CGRect(x: 4, y: 4, width: 90, height: 26)

        let anchor = metrics.catalogAnchor(toolbarFrame: toolbar, addButtonFrame: button)
        #expect(anchor == CGRect(x: 1020, y: 70, width: 450, height: 130))
        // The catalog hangs below `maxY`; a bottom taken from the unexpanded
        // frame would sit 100 board points inside the toolbar it must clear.
        #expect(anchor.maxY <= toolbar.maxY)
        #expect(anchor.maxY > toolbar.minY + button.maxY)

        let desktop = MonitorBoardChromeMetrics(boardSize: board, renderScale: 1)
        #expect(
            desktop.catalogAnchor(toolbarFrame: toolbar, addButtonFrame: button)
                == button.offsetBy(dx: toolbar.minX, dy: toolbar.minY)
        )
    }

    @Test("an unmeasured toolbar falls back to a boosted top-centre anchor")
    func anchorFallbackIsBoosted() {
        let metrics = MonitorBoardChromeMetrics(boardSize: board, renderScale: fifth)
        let fallback = metrics.catalogAnchor(toolbarFrame: .zero, addButtonFrame: .zero)
        #expect(fallback.midX == board.width / 2)
        #expect(fallback.minY == metrics.toolbarTopInset)
        #expect(fallback.size == CGSize(width: 400, height: 150))

        let half = metrics.catalogAnchor(
            toolbarFrame: CGRect(x: 1000, y: 50, width: 700, height: 170), addButtonFrame: .zero
        )
        #expect(half == fallback)
    }

    @Test("the catalog's scroll cap is measured in the points it lays out in")
    func scrollCapIsInChromePoints() {
        let metrics = MonitorBoardChromeMetrics(boardSize: board, renderScale: fifth)
        let cap = metrics.catalogScrollCap(anchorMaxY: 200)
        #expect(cap <= metrics.chromeSpace.height * 0.55)
        #expect(metrics.board(cap) <= board.height - 200)

        #expect(metrics.catalogScrollCap(anchorMaxY: board.height - 1) == 80)
    }
}
