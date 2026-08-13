import CoreGraphics
import Foundation
import Testing
@testable import LiveWallpaperCore

@Suite("Display arrangement map geometry")
struct DisplayArrangementLayoutTests {

    /// 1920×1080 main at the origin, a second panel docked to its right.
    private let main = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    private let right = CGRect(x: 1920, y: 0, width: 1920, height: 1080)
    /// Global display space is y-up, so a display sitting physically ABOVE the
    /// main one has a positive origin.y.
    private let above = CGRect(x: 0, y: 1080, width: 1920, height: 1080)

    @Test("Bounds span every display")
    func boundsSpanAllDisplays() {
        let bounds = DisplayArrangementLayout.bounds(of: [main, right])
        #expect(bounds == CGRect(x: 0, y: 0, width: 3840, height: 1080))
    }

    @Test("Scale fits the union inside the band and never overflows it")
    func scaleFitsInsideBand() {
        let bounds = DisplayArrangementLayout.bounds(of: [main, right])
        let band = CGSize(width: 384, height: 150)
        let scale = DisplayArrangementLayout.scale(bounds: bounds, in: band)

        // Width is the binding constraint here: 384/3840 = 0.1 < 150/1080.
        #expect(abs(scale - 0.1) < 0.0001)
        #expect(bounds.width * scale <= band.width + 0.001)
        #expect(bounds.height * scale <= band.height + 0.001)
    }

    @Test("Side-by-side displays keep their left-to-right order")
    func horizontalOrderIsPreserved() {
        let bounds = DisplayArrangementLayout.bounds(of: [main, right])
        let scale = DisplayArrangementLayout.scale(bounds: bounds, in: CGSize(width: 384, height: 150))
        let mainRect = DisplayArrangementLayout.tileRect(for: main, bounds: bounds, scale: scale, gap: 0)
        let rightRect = DisplayArrangementLayout.tileRect(for: right, bounds: bounds, scale: scale, gap: 0)

        #expect(mainRect.minX < rightRect.minX)
        #expect(abs(mainRect.minY - rightRect.minY) < 0.001)
        #expect(abs(mainRect.maxX - rightRect.minX) < 0.001)
    }

    /// The bug this guards: global display space is y-up while the map draws
    /// y-down, so a missing flip silently renders stacked displays upside down.
    @Test("A display physically above the main one is drawn above it")
    func verticalAxisIsFlippedForDrawing() {
        let bounds = DisplayArrangementLayout.bounds(of: [main, above])
        let scale = DisplayArrangementLayout.scale(bounds: bounds, in: CGSize(width: 384, height: 150))
        let mainRect = DisplayArrangementLayout.tileRect(for: main, bounds: bounds, scale: scale, gap: 0)
        let aboveRect = DisplayArrangementLayout.tileRect(for: above, bounds: bounds, scale: scale, gap: 0)

        #expect(aboveRect.minY < mainRect.minY)
        #expect(abs(aboveRect.minY) < 0.001)
        #expect(abs(aboveRect.maxY - mainRect.minY) < 0.001)
    }

    @Test("Gap insets the tile without moving it off the union")
    func gapInsetsEachTile() {
        let bounds = DisplayArrangementLayout.bounds(of: [main])
        let scale = DisplayArrangementLayout.scale(bounds: bounds, in: CGSize(width: 192, height: 150))
        let noGap = DisplayArrangementLayout.tileRect(for: main, bounds: bounds, scale: scale, gap: 0)
        let gapped = DisplayArrangementLayout.tileRect(for: main, bounds: bounds, scale: scale, gap: 8)

        #expect(abs(gapped.width - (noGap.width - 8)) < 0.001)
        #expect(abs(gapped.minX - (noGap.minX + 4)) < 0.001)
        #expect(gapped.width >= 1)
    }

    @Test("A degenerate bounds yields no scale instead of dividing by zero")
    func degenerateBoundsAreSafe() {
        let empty = DisplayArrangementLayout.bounds(of: [])
        #expect(DisplayArrangementLayout.scale(bounds: empty, in: CGSize(width: 100, height: 100)) == 0)
        #expect(DisplayArrangementLayout.scale(bounds: .zero, in: CGSize(width: 100, height: 100)) == 0)
    }
}
