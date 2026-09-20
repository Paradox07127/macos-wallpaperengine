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
        // Hero + 12 gap + 24 note row, centred in the 764-tall stage area that starts at 56.
        #expect(near(hero.minY, 56 + (764 - (483.75 + 36)) / 2), Comment(rawValue: "\(hero)"))
    }

    @Test("The smallest window gives a 620×348.75 hero, still at x 24")
    func heroAtMinimumWindow() {
        let hero = DetailGeometry.heroFrame(in: CGSize(width: 1040, height: 700))
        #expect(near(hero.minX, 24) && near(hero.width, 620), Comment(rawValue: "\(hero)"))
        #expect(near(hero.height, 348.75), Comment(rawValue: "\(hero)"))
        #expect(near(hero.minY, 56 + (644 - (348.75 + 36)) / 2), Comment(rawValue: "\(hero)"))
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
        // 1600 − 372 − 48 = 1180 across, but only 644 − 48 − 36 = 560 of vertical budget.
        let hero = DetailGeometry.heroFrame(in: CGSize(width: 1600, height: 700))
        #expect(near(hero.width, 560 * 16 / 9), Comment(rawValue: "\(hero)"))
        #expect(near(hero.height, 560), Comment(rawValue: "\(hero)"))
        #expect(hero.maxX <= DetailGeometry.stageRect(in: CGSize(width: 1600, height: 700)).maxX)
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
