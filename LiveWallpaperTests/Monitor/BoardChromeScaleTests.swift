import CoreGraphics
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

/// The inspector lays the board out at the display's own point size and draws it
/// down, so a 36pt control bar landed about seven points tall on a 5K display —
/// visible, but too small to hit. Edit chrome exists only in the preview, so it
/// undoes the shrink; widget tiles still shrink with the board, because their
/// job is to predict the desktop.
@Suite("Monitor board edit-chrome scale")
struct BoardChromeScaleTests {
    /// A 5K display's points, drawn into an inspector canvas — the 1:5 the bug
    /// was reported at.
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
        // Chrome is never grown past its design size, so a magnified board — no
        // caller makes one today — must not shrink it either.
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

    /// The reported defect: 36 board points at 1:5 is 7.2 screen points.
    @Test("the control bar keeps its design size on screen at preview scale")
    func controlBarStaysHittable() {
        let metrics = MonitorBoardChromeMetrics(boardSize: board, renderScale: fifth)
        let estimate = metrics.controlBarEstimate(for: .cpu)
        // Placement happens in board points, so the box grows there...
        #expect(estimate.height == 180)
        // ...and lands back at its design size once the board is drawn down.
        #expect(abs(estimate.height * fifth - 36) < 0.001)

        // The control: without the boost the same bar draws under 8 points.
        let unboosted = MonitorBoardChromeMetrics(boardSize: board, renderScale: 1)
        #expect(unboosted.controlBarEstimate(for: .cpu).height * fifth < 8)
    }

    @Test("boosted chrome still fits the canvas it is drawn into")
    func chromeFitsTheCanvas() {
        let metrics = MonitorBoardChromeMetrics(boardSize: board, renderScale: fifth)
        let canvas = CGSize(width: board.width * fifth, height: board.height * fifth)

        // The catalog sizes itself in screen points, so its width is measured
        // against the canvas the user has, not the desktop it stands for.
        #expect(metrics.catalogWidth <= canvas.width)
        #expect(abs(metrics.catalogWidth - canvas.width * 0.86) < 0.001)
        #expect(metrics.settingsCardMaxHeight <= canvas.height)
        #expect(MonitorWidgetSettingsCard.cardWidth <= canvas.width)

        // The control: the old board-point width would be five canvases wide.
        let unboosted = MonitorBoardChromeMetrics(boardSize: board, renderScale: 1)
        #expect(unboosted.catalogWidth > canvas.width)
    }

    // MARK: Desktop parity

    /// Every metric is a unit conversion, and at boost 1 it must convert nothing:
    /// the desktop board is the one place this whole mechanism must not show up.
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

    /// The Add Widget frame is measured inside the scaled toolbar, so it arrives
    /// in the toolbar's own points. Expanding it about the toolbar's board origin
    /// is what keeps the catalog under the button instead of behind the toolbar.
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

        // At 1:1 the two rects simply add up, which is the board frame the
        // desktop published before the toolbar had a space of its own.
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

        // A measured toolbar with no button frame yet is not enough to place it.
        let half = metrics.catalogAnchor(
            toolbarFrame: CGRect(x: 1000, y: 50, width: 700, height: 170), addButtonFrame: .zero
        )
        #expect(half == fallback)
    }

    @Test("the catalog's scroll cap is measured in the points it lays out in")
    func scrollCapIsInChromePoints() {
        let metrics = MonitorBoardChromeMetrics(boardSize: board, renderScale: fifth)
        let cap = metrics.catalogScrollCap(anchorMaxY: 200)
        // Fits both the canvas and the room left below the anchor.
        #expect(cap <= metrics.chromeSpace.height * 0.55)
        #expect(metrics.board(cap) <= board.height - 200)

        // Never collapses to nothing, however little room is left.
        #expect(metrics.catalogScrollCap(anchorMaxY: board.height - 1) == 80)
    }
}
