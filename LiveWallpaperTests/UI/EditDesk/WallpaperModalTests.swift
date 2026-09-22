import CoreGraphics
import Foundation
@testable import LiveWallpaper
import Testing

/// Pins SCREENS.md S4's panel box, the ⌘n map and the bottom bar's button budget.
@Suite("Library wallpaper modal")
struct WallpaperModalTests {
    private func near(_ actual: CGFloat, _ expected: CGFloat, _ tolerance: CGFloat = 0.01) -> Bool {
        abs(actual - expected) <= tolerance
    }

    private func target(_ index: Int, primary: Bool = false) -> ModalDisplayTarget {
        ModalDisplayTarget(
            id: CGDirectDisplayID(index), name: "Display \(index)", shortcutIndex: index,
            aspectRatio: 16.0 / 9, thumbnail: nil, isPrimary: primary
        )
    }

    // MARK: Panel box

    @Test("The panel is 880×560 at top 150, centred horizontally")
    func panelAtDesignSize() {
        #expect(
            ModalGeometry.panelFrame(in: CGSize(width: 1280, height: 820))
                == CGRect(x: 200, y: 150, width: 880, height: 560)
        )
        #expect(
            ModalGeometry.panelFrame(in: CGSize(width: 1600, height: 1000))
                == CGRect(x: 360, y: 150, width: 880, height: 560)
        )
    }

    @Test("A window too short for top 150 stops under the float strip and gives up height")
    func panelStopsUnderTheStripInAShortWindow() {
        let small = ModalGeometry.panelFrame(in: CGSize(width: 1040, height: 700))
        #expect(small == CGRect(x: 80, y: 130, width: 880, height: 554), Comment(rawValue: "\(small)"))
        let short = ModalGeometry.panelFrame(in: CGSize(width: 1280, height: 500))
        #expect(short == CGRect(x: 200, y: 130, width: 880, height: 354), Comment(rawValue: "\(short)"))
    }

    @Test("A narrow window keeps 24pt of air on each side")
    func panelNarrows() {
        let narrow = ModalGeometry.panelFrame(in: CGSize(width: 800, height: 600))
        #expect(narrow.minX == 24 && narrow.width == 752, Comment(rawValue: "\(narrow)"))
        #expect(narrow.maxX == 776, Comment(rawValue: "\(narrow)"))
    }

    @Test("The preview is the panel less a 12pt margin and the 152pt bottom bar")
    func previewSize() {
        let design = ModalGeometry.previewSize(inPanel: CGRect(x: 0, y: 0, width: 880, height: 560))
        #expect(design == CGSize(width: 856, height: 360), Comment(rawValue: "\(design)"))
        let short = ModalGeometry.previewSize(inPanel: CGRect(x: 0, y: 0, width: 880, height: 554))
        #expect(short == CGSize(width: 856, height: 354), Comment(rawValue: "\(short)"))
    }

    // MARK: ⌘n

    @Test("⌘n selects the display with that shortcut index, and nothing outside the list")
    func keyMap() {
        let targets = [target(1, primary: true), target(2), target(3)]
        #expect(ModalKeyMap.target(forShortcut: 1, in: targets)?.id == 1)
        #expect(ModalKeyMap.target(forShortcut: 3, in: targets)?.id == 3)
        #expect(ModalKeyMap.target(forShortcut: 4, in: targets) == nil)
        #expect(ModalKeyMap.target(forShortcut: 0, in: targets) == nil)
        #expect(ModalKeyMap.target(forShortcut: 1, in: []) == nil)
    }

    // MARK: Bottom bar buttons

    @Test("The bottom bar shows one primary and at most two secondary buttons; the rest overflow")
    func applyButtonBudget() {
        let many = [target(1), target(2, primary: true), target(3), target(4), target(5)]
        let split = ModalGeometry.applyButtons(targets: many)
        #expect(split.primary?.id == 2)
        #expect(split.secondary.map(\.id) == [1, 3], Comment(rawValue: "\(split.secondary.map(\.id))"))
        #expect(split.overflowCount == 2)

        let pair = ModalGeometry.applyButtons(targets: [target(1, primary: true), target(2)])
        #expect(pair.primary?.id == 1 && pair.secondary.map(\.id) == [2] && pair.overflowCount == 0)

        let none = ModalGeometry.applyButtons(targets: [])
        #expect(none.primary == nil && none.secondary.isEmpty && none.overflowCount == 0)
    }

    // MARK: Backdrop

    @Test("The backdrop blur is 8% of the panel width, so a 160px bitmap blurs by 12.7")
    func backdropBlurScales() {
        #expect(near(ModalBackdrop.blurRadius(forWidth: 880), 70))
        #expect(
            near(ModalBackdrop.blurRadius(forWidth: 160), 12.727, 0.001),
            Comment(rawValue: "\(ModalBackdrop.blurRadius(forWidth: 160))")
        )
    }

    // MARK: Meta line

    @Test("The meta line drops the parts the wiring left empty rather than printing bare separators")
    func metaLineSkipsEmptyParts() {
        #expect(ModalMetaLine.joined(["Steam Workshop", "", "nekomata", "214 MB"]) == "Steam Workshop · nekomata · 214 MB")
        #expect(ModalMetaLine.joined(["4K"]) == "4K")
        #expect(ModalMetaLine.joined(["", ""]).isEmpty)
        #expect(ModalMetaLine.joined([]).isEmpty)
    }
}
