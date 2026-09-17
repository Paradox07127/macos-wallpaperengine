import CoreGraphics
@testable import LiveWallpaperCore
import Testing

@MainActor
@Suite("FullScreenDetector window-union occlusion")
struct FullScreenOcclusionTests {
    @Test("Empty / degenerate inputs are zero area")
    func emptyIsZero() {
        #expect(FullScreenDetector.unionArea(of: []) == 0)
        #expect(FullScreenDetector.unionArea(of: [CGRect(x: 0, y: 0, width: 0, height: 100)]) == 0)
    }

    @Test("Disjoint rectangles sum their areas")
    func disjointSums() {
        let a = CGRect(x: 0, y: 0, width: 100, height: 100)
        let b = CGRect(x: 200, y: 200, width: 50, height: 50)
        #expect(FullScreenDetector.unionArea(of: [a, b]) == 12500)
    }

    @Test("Overlapping rectangles count the overlap once")
    func overlapCountedOnce() {
        let a = CGRect(x: 0, y: 0, width: 100, height: 100)
        let b = CGRect(x: 50, y: 0, width: 100, height: 100)
        #expect(FullScreenDetector.unionArea(of: [a, b]) == 15000)
    }

    @Test("A fully-contained rectangle adds nothing")
    func containedAddsNothing() {
        let big = CGRect(x: 0, y: 0, width: 100, height: 100)
        let small = CGRect(x: 10, y: 10, width: 20, height: 20)
        #expect(FullScreenDetector.unionArea(of: [big, small]) == 10000)
    }

    @Test("Only a window that also covers the menu bar strip counts as a full-screen app")
    func fullScreenNeedsTheWholeDisplay() {
        let display = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        // A zoomed window on a Dock-less display leaves only the 30 pt menu bar uncovered.
        let zoomed = CGRect(x: -1920, y: 30, width: 1920, height: 1050)
        #expect(!FullScreenDetector.windowFillsDisplay(zoomed.intersection(display), display: display))
        let fullScreen = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        #expect(FullScreenDetector.windowFillsDisplay(fullScreen.intersection(display), display: display))
        let oversized = CGRect(x: -2000, y: -100, width: 2200, height: 1400)
        #expect(FullScreenDetector.windowFillsDisplay(oversized.intersection(display), display: display))
        #expect(!FullScreenDetector.windowFillsDisplay(.null, display: display))
    }

    @Test("A full-screen window that stops at the notch's safe area still counts as full screen")
    func fullScreenMayStopAtTheSafeArea() {
        let display = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let safeArea = CGRect(x: 0, y: 37, width: 1728, height: 1080)
        let notchAvoiding = CGRect(x: 0, y: 37, width: 1728, height: 1080)
        #expect(!FullScreenDetector.windowFillsDisplay(notchAvoiding.intersection(display), display: display))
        #expect(FullScreenDetector.windowFillsDisplay(notchAvoiding, display: display, safeArea: safeArea))
        // A zoomed window below a menu bar on a display without a notch is still an ordinary window.
        let plain = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let zoomed = CGRect(x: 0, y: 30, width: 1920, height: 1050)
        #expect(!FullScreenDetector.windowFillsDisplay(zoomed, display: plain, safeArea: plain))
    }

    @Test("Tiled windows reach the 85% threshold by union, not by any single window")
    func tiledReaches85Percent() {
        let screenArea: CGFloat = 1_000_000
        let tiles = [
            CGRect(x: 0, y: 0, width: 500, height: 450),
            CGRect(x: 500, y: 0, width: 500, height: 450),
            CGRect(x: 0, y: 550, width: 500, height: 450),
            CGRect(x: 500, y: 550, width: 500, height: 450),
        ]
        let union = FullScreenDetector.unionArea(of: tiles)
        #expect(union == 900_000)
        #expect(union >= screenArea * 0.85)
        #expect(tiles.allSatisfy { ($0.width * $0.height) < screenArea * 0.85 })
    }
}
