import CoreGraphics
import Foundation
@testable import LiveWallpaper
import Testing

@Suite("DisplayFloatLayer — thumbnail geometry, strip width and drop wording")
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

    @Test("Strip width grows 160pt per display over the caption and its 40pt of gutters")
    func stripWidthGrowsWithCount() {
        #expect(FloatLayerGeometry.stripWidth(count: 1, windowWidth: 1280, captionWidth: 70) == 270)
        #expect(FloatLayerGeometry.stripWidth(count: 2, windowWidth: 1280, captionWidth: 70) == 430)
        #expect(FloatLayerGeometry.stripWidth(count: 5, windowWidth: 1280, captionWidth: 70) == 910)
    }

    @Test("A wider caption widens the run-in by exactly its own growth")
    func stripWidthFollowsTheCaption() {
        let narrow = FloatLayerGeometry.stripWidth(count: 5, windowWidth: 4000, captionWidth: 70)
        let wide = FloatLayerGeometry.stripWidth(count: 5, windowWidth: 4000, captionWidth: 130)
        #expect(wide - narrow == 60, Comment(rawValue: "\(narrow) → \(wide)"))
    }

    @Test("A window narrower than the display count demands caps the strip at W − 48")
    func stripWidthCapsOnNarrowWindow() {
        #expect(FloatLayerGeometry.stripWidth(count: 5, windowWidth: 700, captionWidth: 70) == 652)
    }

    @Test("The caption box is 70pt at the floor and the text's own width above it")
    func captionWidthIsAFloor() {
        #expect(FloatLayerGeometry.captionWidth(ofCaption: "拖到屏幕\n即应用") == 70)
        let english = FloatLayerGeometry.captionWidth(ofCaption: "Drag to a display\nto apply")
        #expect(english > 100, Comment(rawValue: "\(english)"))
        // The widest line sizes the box; the second line is not added to it.
        #expect(
            FloatLayerGeometry.captionWidth(ofCaption: "Drag to a display\nto apply")
                == FloatLayerGeometry.captionWidth(ofCaption: "Drag to a display"),
            Comment(rawValue: "\(english)")
        )
    }

    @Test("Four displays still fit; the fifth turns the thumbnail run into a scroller")
    func scrollThreshold() {
        #expect(FloatLayerGeometry.needsScroll(count: 4) == false)
        #expect(FloatLayerGeometry.needsScroll(count: 5) == true)
    }

    @Test("The strip only takes drops: its caption, highlight and thumbnails all say so")
    func dropWording() {
        #expect(FloatLayerGeometry.captionKey == "Drag to a display\nto apply")
        #expect(FloatLayerGeometry.highlightLabel == String(localized: "Drop to replace", bundle: .appLanguage))
        let name = "MacBook"
        #expect(FloatLayerGeometry.thumbnailAccessibilityLabel(displayName: name) == String(localized: "Drop target: \(name)", bundle: .appLanguage))
    }

    @Test("The drag ghost is the 140×79 card MOTION 7 specifies")
    func ghostSize() {
        #expect(ModalDragGhost.size == CGSize(width: 140, height: 79))
    }

    @Test("The All Displays tile takes a drop; a thumbnail scrolled out of the run does not")
    @MainActor
    func applyAllTileTakesADrop() {
        let thumbnails: [CGDirectDisplayID: CGRect] = [
            1: CGRect(x: 100, y: 24, width: 149, height: 84),
            2: CGRect(x: 520, y: 24, width: 149, height: 84),
        ]
        // Display 2 sits past the run's right edge, scrolled out of view.
        let run = CGRect(x: 90, y: 24, width: 400, height: 84)
        let applyAll = CGRect(x: 700, y: 51, width: 120, height: 30)
        func target(_ point: CGPoint) -> ModalDropTarget? {
            LibraryModalHost.dropTarget(at: point, thumbnails: thumbnails, run: run, applyAll: applyAll)
        }
        #expect(target(CGPoint(x: 150, y: 60)) == .display(1))
        #expect(target(CGPoint(x: 760, y: 66)) == .allDisplays)
        #expect(target(CGPoint(x: 600, y: 60)) == nil)
    }

    @Test("The strip has one mode: no target picking, no click, no Workshop caption")
    func stripOnlyTakesDrops() throws {
        let source = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Library/DisplayFloatLayer.swift")
        #expect(!source.contains("selectTarget"), "the strip still has a target-picking mode")
        #expect(!source.contains("After downloading"), "the strip still carries the Workshop caption")
        #expect(!source.contains("onSelect"), "the strip still takes clicks")
        #expect(!source.contains("FloatLayerMode"), "the strip still switches on a mode")
        #expect(source.contains("FloatLayerGeometry.thumbnailAccessibilityLabel(displayName:"))
        let contract = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Library/WallpaperModalContract.swift")
        #expect(!contract.contains("enum FloatLayerMode"), "the mode enum outlived its second case")
    }

    @Test("The caption box is a floor the text can push, not a 70pt cap that clips it")
    func captionBoxFollowsItsText() throws {
        let source = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Library/DisplayFloatLayer.swift")
        #expect(!source.contains(".frame(width: 70"), "the caption is still pinned to a 70pt box")
        #expect(source.contains("minWidth: FloatLayerGeometry.captionMinWidth"))
        #expect(source.contains("captionWidth: FloatLayerGeometry.captionWidth"))
        #expect(!source.contains("captionWidth(for:"), "the strip still measures a caption per mode")
    }
}
