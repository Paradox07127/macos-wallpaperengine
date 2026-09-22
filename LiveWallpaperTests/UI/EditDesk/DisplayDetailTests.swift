import CoreGraphics
import Foundation
@testable import LiveWallpaper
import Testing

/// Pins GAP_ANALYSIS.md §8.2's layout B: 16:9 hero on the left, 372 inspector on the right.
@Suite("Display detail shell")
struct DisplayDetailTests {
    private func near(_ actual: CGFloat, _ expected: CGFloat, _ tolerance: CGFloat = 0.01) -> Bool {
        abs(actual - expected) <= tolerance
    }

    private func tag(_ index: Int, current: Bool = false) -> DetailDisplayTag {
        DetailDisplayTag(id: CGDirectDisplayID(index), name: "Display \(index)", thumbnail: nil, isCurrent: current)
    }

    // MARK: Stage area

    @Test("The stage area is everything left of the 372 inspector and below the 56 top bar")
    func stageAreaExcludesTheInspectorAndTopBar() {
        #expect(
            DetailGeometry.stageRect(in: CGSize(width: 1280, height: 820))
                == CGRect(x: 0, y: 56, width: 908, height: 764)
        )
        #expect(
            DetailGeometry.stageRect(in: CGSize(width: 1040, height: 700))
                == CGRect(x: 0, y: 56, width: 668, height: 644)
        )
        #expect(DetailGeometry.inspectorWidth == 372)
    }

    // MARK: Hero box

    @Test("The design window gives an 860×483.75 hero at x 24, centred in the stage area")
    func heroAtDesignSize() {
        let hero = DetailGeometry.heroFrame(in: CGSize(width: 1280, height: 820))
        #expect(near(hero.minX, 24) && near(hero.width, 860), Comment(rawValue: "\(hero)"))
        #expect(near(hero.height, 483.75), Comment(rawValue: "\(hero)"))
        // Preview alone is centred; no explanatory footer consumes canvas space.
        #expect(near(hero.minY, 56 + (764 - 483.75) / 2), Comment(rawValue: "\(hero)"))
    }

    @Test("The smallest window gives a 620×348.75 hero, still at x 24")
    func heroAtMinimumWindow() {
        let hero = DetailGeometry.heroFrame(in: CGSize(width: 1040, height: 700))
        #expect(near(hero.minX, 24) && near(hero.width, 620), Comment(rawValue: "\(hero)"))
        #expect(near(hero.height, 348.75), Comment(rawValue: "\(hero)"))
        #expect(near(hero.minY, 56 + (644 - 348.75) / 2), Comment(rawValue: "\(hero)"))
    }

    @Test("A wider window grows the hero at 16:9 and keeps the inspector at 372")
    func heroGrowsWithTheWindow() {
        let hero = DetailGeometry.heroFrame(in: CGSize(width: 1600, height: 1000))
        // 1600 − 372 − 48 = 1180 wide; the 944-tall stage area has height to spare.
        #expect(near(hero.minX, 24) && near(hero.width, 1180), Comment(rawValue: "\(hero)"))
        #expect(near(hero.height, 663.75), Comment(rawValue: "\(hero)"))
        #expect(near(hero.width / hero.height, 16.0 / 9), Comment(rawValue: "\(hero)"))
    }

    @Test("A short window lets the height cap the hero instead of the width")
    func heroHeightCaps() {
        // 1600 − 372 − 48 = 1180 across, but only 644 − 48 = 596 of vertical budget.
        let hero = DetailGeometry.heroFrame(in: CGSize(width: 1600, height: 700))
        #expect(near(hero.width, 596 * 16 / 9), Comment(rawValue: "\(hero)"))
        #expect(near(hero.height, 596), Comment(rawValue: "\(hero)"))
        #expect(hero.maxX <= DetailGeometry.stageRect(in: CGSize(width: 1600, height: 700)).maxX)
    }

    @Test("Overlay onboarding reserves space at minimum and wide window sizes")
    func overlayOnboardingDoesNotCoverCanvas() {
        for window in [CGSize(width: 1040, height: 700), CGSize(width: 1600, height: 1000)] {
            let cardBottom = OnboardingCardMetrics.blockHeight
            for logical in [CGSize(width: 1920, height: 1080), CGSize(width: 1080, height: 1920)] {
                let box = DetailGeometry.overlayFrame(
                    in: window, logicalSize: logical, topInset: cardBottom - DetailGeometry.topBarHeight
                )
                #expect(box.minY >= cardBottom + DetailGeometry.sideMargin)
                #expect(box.maxY <= window.height - DetailGeometry.sideMargin)
                #expect(box.maxX <= window.width - DetailGeometry.inspectorWidth - DetailGeometry.sideMargin)
                #expect(near(box.width / box.height, logical.width / logical.height))
            }
        }
    }

    @Test("Left swipe requires deliberate horizontal travel; vertical and diagonal scrolling stay in place")
    func backSwipeRejectsScrollNoise() {
        var left = DetailBackSwipeGesture()
        let swipeResult1 = left.update(dx: -50, dy: 3)
        #expect(!swipeResult1)
        let swipeResult2 = left.update(dx: -50, dy: 1)
        #expect(swipeResult2)
        var vertical = DetailBackSwipeGesture()
        let swipeResult3 = vertical.update(dx: -5, dy: 30)
        #expect(!swipeResult3)
        let swipeResult4 = vertical.update(dx: -120, dy: 0)
        #expect(!swipeResult4)
        var right = DetailBackSwipeGesture()
        let swipeResult5 = right.update(dx: 150, dy: 0)
        #expect(!swipeResult5)
        var diagonal = DetailBackSwipeGesture()
        let swipeResult6 = diagonal.update(dx: -110, dy: 90)
        #expect(!swipeResult6)
    }

    @Test("Collapsing or resizing the inspector preserves preview centering and aspect ratio")
    func variableInspectorGeometry() {
        let window = CGSize(width: 1040, height: 700)
        for width: CGFloat in [0, 300, 372, 520] {
            let hero = DetailGeometry.heroFrame(in: window, inspectorWidth: width)
            #expect(near(hero.midX, (window.width - width) / 2))
            #expect(near(hero.midY, 56 + (window.height - 56) / 2))
            #expect(near(hero.width / hero.height, 16.0 / 9))
            #expect(hero.maxX <= window.width - width - 24)
            #expect(hero.maxY <= window.height - 24)
        }
    }

    // MARK: Top-bar tags

    @Test("Three display tags stay unfolded")
    func threeTagsDoNotFold() {
        let split = DetailTagRow.split([tag(1, current: true), tag(2), tag(3)])
        #expect(split.visible.count == 3)
        #expect(split.overflow == 0)
    }

    @Test("Five display tags fold to the first three plus +2")
    func fiveTagsFold() {
        let split = DetailTagRow.split((1 ... 5).map { tag($0) })
        #expect(split.visible.map(\.id) == [1, 2, 3])
        #expect(split.overflow == 2)
        // Four is the first count that folds at all.
        #expect(DetailTagRow.split((1 ... 4).map { tag($0) }).overflow == 1)
    }
}
