import CoreGraphics
import Foundation
@testable import LiveWallpaper
import Testing

/// One panel box for the library and Workshop detail modals, whatever window they open in.
@Suite("Modal geometry — the one panel box both detail modals share")
struct ModalGeometryTests {
    @Test("The panel is at most 920×680, centred, and never above the 72pt floor")
    func panelRectanglesPerWindow() {
        let cases: [(window: CGSize, panel: CGRect)] = [
            (CGSize(width: 1040, height: 896), CGRect(x: 60, y: 108, width: 920, height: 680)),
            (CGSize(width: 1280, height: 820), CGRect(x: 180, y: 72, width: 920, height: 680)),
            (CGSize(width: 1040, height: 700), CGRect(x: 60, y: 72, width: 920, height: 600)),
            // Narrower than the Edit Desk window allows: the panel gives up width so ← and → keep their gutter.
            (CGSize(width: 800, height: 600), CGRect(x: 60, y: 72, width: 680, height: 500)),
        ]
        for (window, expected) in cases {
            let panel = ModalGeometry.panelFrame(in: window)
            #expect(panel == expected, Comment(rawValue: "\(window) → \(panel), expected \(expected)"))
        }
    }

    @Test("The preview is fitted into a 340×255 box: 4:3 crops neither a square Workshop preview nor a 16:9 video")
    func previewBoxIsFourByThree() {
        #expect(ModalGeometry.previewSize == CGSize(width: 340, height: 255))
    }

    @Test("A preview is drawn whole and enlarged at most 2×; one that would need more stays at 2× and reads low-resolution")
    func previewFitCapsTheEnlargement() {
        let cases: [(pixels: CGSize, scale: CGFloat, drawn: CGSize, lowResolution: Bool)] = [
            (CGSize(width: 192, height: 192), 2, CGSize(width: 192, height: 192), true),
            (CGSize(width: 1024, height: 1024), 2, CGSize(width: 255, height: 255), false),
            (CGSize(width: 680, height: 382), 2, CGSize(width: 340, height: 191), false),
            (CGSize(width: 256, height: 256), 2, CGSize(width: 255, height: 255), false),
            (CGSize(width: 1024, height: 576), 2, CGSize(width: 340, height: 191.25), false),
            (CGSize(width: 160, height: 90), 2, CGSize(width: 160, height: 90), true),
            // The same 192 px on a 1× display fills the box at 1.33×, inside the cap.
            (CGSize(width: 192, height: 192), 1, CGSize(width: 255, height: 255), false),
        ]
        for (pixels, scale, drawn, lowResolution) in cases {
            let fit = ModalGeometry.previewFit(pixels: pixels, scale: scale)
            let label = "\(pixels) @\(scale)× → \(fit.size) low=\(fit.isLowResolution), expected \(drawn) low=\(lowResolution)"
            #expect(abs(fit.size.width - drawn.width) < 0.001 && abs(fit.size.height - drawn.height) < 0.001, Comment(rawValue: label))
            #expect(fit.isLowResolution == lowResolution, Comment(rawValue: label))
        }
    }

    @Test("The left column hugs the preview down to the fact rows' floor, and the right column takes what it gives up")
    func columnsFollowThePreview() {
        let cases: [(preview: CGSize, left: CGFloat, right: CGFloat)] = [
            (CGSize(width: 192, height: 192), 304, 544),
            (CGSize(width: 255, height: 255), 304, 544),
            (CGSize(width: 340, height: 191.25), 340, 508),
            // The Workshop modal's fixed box.
            (ModalGeometry.previewSize, 340, 508),
        ]
        for window in [CGSize(width: 1040, height: 700), CGSize(width: 1280, height: 820)] {
            let panel = ModalGeometry.panelFrame(in: window)
            for (preview, left, right) in cases {
                let leading = ModalGeometry.leadingColumnWidth(preview: preview)
                let trailing = panel.width - 2 * ModalGeometry.horizontalPadding - leading - ModalGeometry.columnSpacing
                let label = "\(window) \(preview): left \(leading) right \(trailing), expected \(left) / \(right)"
                #expect(leading == left && trailing == right, Comment(rawValue: label))
            }
        }
    }

    @Test("← and → sit on the scrim beside the panel, level with its middle, inside the window")
    func arrowsFlankThePanel() {
        let cases: [(window: CGSize, previous: CGRect, next: CGRect)] = [
            (CGSize(width: 1040, height: 700), CGRect(x: 16, y: 358, width: 28, height: 28), CGRect(x: 996, y: 358, width: 28, height: 28)),
            (CGSize(width: 1280, height: 820), CGRect(x: 136, y: 398, width: 28, height: 28), CGRect(x: 1116, y: 398, width: 28, height: 28)),
            (CGSize(width: 800, height: 600), CGRect(x: 16, y: 308, width: 28, height: 28), CGRect(x: 756, y: 308, width: 28, height: 28)),
        ]
        for (window, previous, next) in cases {
            let panel = ModalGeometry.panelFrame(in: window)
            let arrows = ModalGeometry.arrowFrames(beside: panel)
            #expect(arrows.previous == previous && arrows.next == next, Comment(rawValue: "\(window) → \(arrows), expected \(previous) \(next)"))
            for arrow in [arrows.previous, arrows.next] {
                #expect(!arrow.intersects(panel), Comment(rawValue: "\(window): \(arrow) overlaps the panel \(panel)"))
                #expect(CGRect(origin: .zero, size: window).contains(arrow), Comment(rawValue: "\(window): \(arrow) leaves the window"))
                #expect(arrow.midY == panel.midY, Comment(rawValue: "\(window): \(arrow) is not level with the panel's middle"))
            }
        }
    }

    @Test("With no display leading, the first three are plain buttons in ⌘ order and the fourth on overflow")
    func applyButtonsWithoutALeadKeepTheirPlaces() {
        func target(_ id: CGDirectDisplayID, leads: Bool = false) -> ModalDisplayTarget {
            ModalDisplayTarget(id: id, name: "\(id)", shortcutIndex: Int(id), aspectRatio: 16.0 / 9, isPrimary: leads)
        }
        let plain = ModalGeometry.applyButtons(targets: (1 ... 5).map { target($0) })
        #expect(plain.primary == nil)
        #expect(plain.secondary.map(\.id) == [1, 2, 3], Comment(rawValue: "\(plain.secondary.map(\.id))"))
        #expect(plain.overflow.map(\.id) == [4, 5])
        // Control: one leading display keeps the library modal's one prominent and two plain buttons.
        let led = ModalGeometry.applyButtons(targets: [target(1), target(2, leads: true), target(3), target(4)])
        #expect(led.primary?.id == 2)
        #expect(led.secondary.map(\.id) == [1, 3])
        #expect(led.overflow.map(\.id) == [4])
    }

    @Test("Only the library hangs the strip, from the one geometry constant; the Workshop modal has none")
    func onlyTheLibraryHangsTheStrip() throws {
        let library = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Library/LibraryDragController.swift")
        #expect(!library.contains("floatTop: CGFloat = 14"), "the library's drag overlay keeps its own copy of the strip's top")
        #expect(library.contains("FloatLayerGeometry.panelTop"))
        let workshop = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Workshop/WorkshopModalHost.swift")
        #expect(!workshop.contains("DisplayFloatLayer("), "the Workshop host still hangs a target strip over its modal")
    }
}
