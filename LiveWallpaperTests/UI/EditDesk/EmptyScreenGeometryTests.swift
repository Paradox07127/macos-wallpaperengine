import CoreGraphics
@testable import LiveWallpaper
import Testing

@MainActor
@Suite("Empty screen entry geometry")
struct EmptyScreenGeometryTests {
    private static let chooseWidth: CGFloat = 68
    private static let pasteWidth: CGFloat = 52

    /// Height at which the stack exactly fills the content layer, margins included. The glyph grows
    /// with the display, so the budget is a fixed point rather than a sum of constants.
    private static var minimumHeight: CGFloat {
        (2 * StageGeometry.emptyScreenMargin + 2 * StageGeometry.emptyScreenRowGap
            + StageGeometry.emptyScreenButtonHeight + StageGeometry.emptyScreenHintHeight)
            / (1 - StageGeometry.emptyScreenSymbolFraction)
    }

    /// What the arrangement actually hands a display in the named window, so the two window steps
    /// are the ones the stage draws rather than sizes picked for the test.
    private func contentSize(window: CGSize) -> CGSize {
        let frames = [
            CGRect(x: 0, y: 0, width: 1920, height: 1080),
            CGRect(x: 1920, y: 0, width: 1920, height: 1080),
        ]
        let arrangement = StageGeometry.arrangement(
            frames: frames, in: StageGeometry.stageRect(windowSize: window)
        )
        return arrangement.contentRects[0].size
    }

    private func layout(_ size: CGSize) -> StageGeometry.EmptyScreenLayout? {
        StageGeometry.emptyScreenLayout(
            content: size, chooseFileTextWidth: Self.chooseWidth, pasteURLTextWidth: Self.pasteWidth
        )
    }

    @Test("Both window steps stack the glyph, buttons and hint centred inside the content layer", arguments: [
        StageGeometry.designWindow, StageGeometry.minimumWindow,
    ])
    func stackFitsBothWindowSteps(window: CGSize) throws {
        let size = contentSize(window: window)
        let layout = try #require(layout(size))
        let bounds = CGRect(origin: .zero, size: size)
        let margin = StageGeometry.emptyScreenMargin
        for rect in [layout.symbol, layout.chooseFile, layout.pasteURL, layout.hint] {
            #expect(bounds.insetBy(dx: margin, dy: margin).contains(rect), Comment(rawValue: "\(rect) escapes \(size)"))
        }
        // One row, in reading order, with the buttons sized to their own text.
        #expect(layout.chooseFile.minY == layout.pasteURL.minY)
        #expect(layout.chooseFile.height == StageGeometry.emptyScreenButtonHeight)
        #expect(layout.pasteURL.height == StageGeometry.emptyScreenButtonHeight)
        #expect(layout.chooseFile.width == Self.chooseWidth + 2 * StageGeometry.emptyScreenButtonPadding)
        #expect(layout.pasteURL.width == Self.pasteWidth + 2 * StageGeometry.emptyScreenButtonPadding)
        #expect(layout.pasteURL.minX - layout.chooseFile.maxX == StageGeometry.emptyScreenButtonGap)
        #expect(abs((layout.chooseFile.minX + layout.pasteURL.maxX) / 2 - size.width / 2) < 0.00000001)
        // Glyph over buttons over hint, one gap each, and the whole stack centred vertically.
        #expect(layout.chooseFile.minY - layout.symbol.maxY == StageGeometry.emptyScreenRowGap)
        #expect(layout.hint.minY - layout.chooseFile.maxY == StageGeometry.emptyScreenRowGap)
        #expect(abs((layout.symbol.minY + layout.hint.maxY) / 2 - size.height / 2) < 0.00000001)
        #expect(layout.hint.width == size.width - 2 * margin)
        // A square glyph, centred on the content layer and scaled to it.
        #expect(layout.symbol.width == layout.symbol.height)
        #expect(abs(layout.symbol.midX - size.width / 2) < 0.00000001)
        #expect(layout.symbol.height == min(
            StageGeometry.emptyScreenSymbolMaxSide, size.height * StageGeometry.emptyScreenSymbolFraction
        ))
    }

    /// The shell the 1040 window gives a display when three of them share it — the smallest the
    /// stage ever draws. Dropping the title without re-cutting the budget would take the two
    /// buttons away here, which reads as a bare dashed rectangle rather than as a failure.
    @Test("The smallest shell the minimum window draws still keeps its entry points")
    func smallestShellKeepsItsEntryPoints() throws {
        let frames = (0 ..< 3).map { CGRect(x: CGFloat($0) * 1920, y: 0, width: 1920, height: 1080) }
        let size = StageGeometry.arrangement(
            frames: frames, in: StageGeometry.stageRect(windowSize: StageGeometry.minimumWindow)
        ).contentRects[0].size
        let layout = try #require(layout(size), Comment(rawValue: "\(size) lost its entry points"))
        #expect(CGRect(origin: .zero, size: size).contains(layout.chooseFile))
    }

    @Test("The minimum window draws displays smaller than the design window does")
    func minimumWindowShrinksTheContent() {
        #expect(contentSize(window: StageGeometry.minimumWindow).width < contentSize(window: StageGeometry.designWindow).width)
    }

    /// The degradation rule: one step under either threshold and nothing is drawn at all, so the
    /// shell stays a bare drop target instead of showing clipped buttons.
    @Test("A display drawn too small for the stack gets no entry points")
    func tooSmallDegradesToTheBareShell() {
        let row = Self.chooseWidth + Self.pasteWidth + 4 * StageGeometry.emptyScreenButtonPadding
            + StageGeometry.emptyScreenButtonGap + 2 * StageGeometry.emptyScreenMargin
        let column = Self.minimumHeight.rounded(.up)
        #expect(layout(CGSize(width: row, height: column)) != nil, "the exact fit still draws")
        #expect(layout(CGSize(width: row - 1, height: column)) == nil)
        #expect(layout(CGSize(width: row, height: Self.minimumHeight.rounded(.down) - 1)) == nil)
    }
}
