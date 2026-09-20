import CoreGraphics
import Foundation
@testable import LiveWallpaper
import Testing

@Suite("DisplayFloatLayer — thumbnail geometry, strip width and per-mode wording")
struct DisplayFloatLayerTests {
    @Test("A 16:9 display rounds to a 149pt thumbnail")
    func thumbnailWidthSixteenByNine() {
        #expect(FloatLayerGeometry.thumbnailWidth(aspect: 16.0 / 9) == 149)
    }

    @Test("A 16:10 display rounds to a 134pt thumbnail")
    func thumbnailWidthSixteenByTen() {
        #expect(FloatLayerGeometry.thumbnailWidth(aspect: 16.0 / 10) == 134)
    }

    @Test("A portrait 9:16 display clamps up to the 60pt floor")
    func thumbnailWidthPortraitClamps() {
        #expect(FloatLayerGeometry.thumbnailWidth(aspect: 9.0 / 16) == 60)
    }

    @Test("An ultrawide 32:9 display clamps down to the 150pt ceiling")
    func thumbnailWidthUltrawideClamps() {
        #expect(FloatLayerGeometry.thumbnailWidth(aspect: 32.0 / 9) == 150)
    }

    @Test("Strip width grows 160pt per display over a 120pt fixed run-in")
    func stripWidthGrowsWithCount() {
        #expect(FloatLayerGeometry.stripWidth(count: 1, windowWidth: 1280) == 280)
        #expect(FloatLayerGeometry.stripWidth(count: 2, windowWidth: 1280) == 440)
        #expect(FloatLayerGeometry.stripWidth(count: 5, windowWidth: 1280) == 920)
    }

    @Test("A window narrower than the display count demands caps the strip at W − 48")
    func stripWidthCapsOnNarrowWindow() {
        #expect(FloatLayerGeometry.stripWidth(count: 5, windowWidth: 700) == 652)
    }

    @Test("Four displays still fit; the fifth turns the thumbnail run into a scroller")
    func scrollThreshold() {
        #expect(FloatLayerGeometry.needsScroll(count: 4) == false)
        #expect(FloatLayerGeometry.needsScroll(count: 5) == true)
    }

    @Test("Each mode has its own caption key")
    func captionKeyPerMode() {
        #expect(FloatLayerGeometry.captionKey(for: .dropTarget) == "Drag to a display\nto apply")
        #expect(FloatLayerGeometry.captionKey(for: .selectTarget) == "After downloading\napply to")
    }

    @Test("Drop highlights name no display; selection highlights name the selected one")
    func highlightLabelPerMode() {
        #expect(FloatLayerGeometry.highlightLabel(for: .dropTarget, displayName: "MacBook").contains("MacBook") == false)
        #expect(FloatLayerGeometry.highlightLabel(for: .selectTarget, displayName: "MacBook").contains("MacBook"))
    }

    @Test("The drag ghost is the 140×79 card MOTION 7 specifies")
    func ghostSize() {
        #expect(ModalDragGhost.size == CGSize(width: 140, height: 79))
    }
}
