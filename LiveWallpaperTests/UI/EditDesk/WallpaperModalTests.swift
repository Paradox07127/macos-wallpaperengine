import CoreGraphics
import Foundation
@testable import LiveWallpaper
import Testing

/// Pins the detail modal's panel box, the ⌘n map, the bottom bar's button budget and its layout.
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

    @Test("A large window caps the panel at 920×680 and centres it both ways")
    func panelCapsAtItsLargestSize() {
        #expect(
            ModalGeometry.panelFrame(in: CGSize(width: 1600, height: 1000))
                == CGRect(x: 340, y: 160, width: 920, height: 680)
        )
    }

    @Test("A short window keeps the 72pt floor and gives up height")
    func panelKeepsItsFloorInAShortWindow() {
        let short = ModalGeometry.panelFrame(in: CGSize(width: 1280, height: 500))
        #expect(short == CGRect(x: 180, y: 72, width: 920, height: 400), Comment(rawValue: "\(short)"))
    }

    @Test("A narrow window keeps 24pt of air on each side")
    func panelNarrows() {
        let narrow = ModalGeometry.panelFrame(in: CGSize(width: 800, height: 600))
        #expect(narrow.minX == 24 && narrow.width == 752, Comment(rawValue: "\(narrow)"))
        #expect(narrow.maxX == 776, Comment(rawValue: "\(narrow)"))
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

    // MARK: Layout

    @Test("No divider over the buttons, ← → beside the preview, no ＋ or … menus, a four-line description")
    func modalLayoutSourceContract() throws {
        let modal = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Library/WallpaperModal.swift")
        // Read leniently: before the shared layout exists this must fail on an expectation, not a missing file.
        let layout = (try? RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Library/WallpaperDetailLayout.swift")) ?? ""
        #expect(!modal.contains("Divider()"), "a divider still separates the buttons from the body")
        #expect(!modal.contains("ModalGlyphMenu"), "the ＋ / … glyph menus are still drawn")
        #expect(modal.contains("WallpaperDetailLayout("), "the modal lays itself out instead of using the shared layout")
        #expect(modal.contains("collapsedLineLimit: 4"), "the description is not cut to four lines")
        #expect(!layout.contains("Divider()"))
        let back = layout.range(of: #"GlassIconButton("chevron.left""#)
        let preview = layout.range(of: "preview()")
        let forward = layout.range(of: #"GlassIconButton("chevron.right""#)
        #expect(back != nil && preview != nil && forward != nil, "the arrows or the preview slot are missing")
        if let back, let preview, let forward {
            #expect(back.lowerBound < preview.lowerBound && preview.lowerBound < forward.lowerBound, "← and → do not flank the preview")
        }
    }

    @Test("The backdrop blur is 8% of the panel width, so a 160px bitmap blurs by 12.7")
    func backdropBlurScales() {
        #expect(near(ModalBackdrop.blurRadius(forWidth: 880), 70))
        #expect(
            near(ModalBackdrop.blurRadius(forWidth: 160), 12.727, 0.001),
            Comment(rawValue: "\(ModalBackdrop.blurRadius(forWidth: 160))")
        )
    }
}
