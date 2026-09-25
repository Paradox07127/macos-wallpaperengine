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
            (CGSize(width: 800, height: 600), CGRect(x: 24, y: 72, width: 752, height: 500)),
        ]
        for (window, expected) in cases {
            let panel = ModalGeometry.panelFrame(in: window)
            #expect(panel == expected, Comment(rawValue: "\(window) → \(panel), expected \(expected)"))
        }
    }

    @Test("The preview is a 340×255 box: 4:3 crops neither a square Workshop preview nor a 16:9 video")
    func previewBoxIsFourByThree() {
        #expect(ModalGeometry.previewSize == CGSize(width: 340, height: 255))
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
        let library = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Library/LibraryModalHost.swift")
        #expect(!library.contains("floatTop: CGFloat = 14"), "the library host keeps its own copy of the strip's top")
        #expect(library.contains("FloatLayerGeometry.panelTop"))
        let workshop = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Workshop/WorkshopModalHost.swift")
        #expect(!workshop.contains("DisplayFloatLayer("), "the Workshop host still hangs a target strip over its modal")
    }
}
