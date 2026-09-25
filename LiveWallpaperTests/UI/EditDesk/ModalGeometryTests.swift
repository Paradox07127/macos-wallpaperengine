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

    @Test("Only the library hangs the strip, from the one geometry constant; the Workshop modal has none")
    func onlyTheLibraryHangsTheStrip() throws {
        let library = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Library/LibraryModalHost.swift")
        #expect(!library.contains("floatTop: CGFloat = 14"), "the library host keeps its own copy of the strip's top")
        #expect(library.contains("FloatLayerGeometry.panelTop"))
        let workshop = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Workshop/WorkshopModalHost.swift")
        #expect(!workshop.contains("DisplayFloatLayer("), "the Workshop host still hangs a target strip over its modal")
    }
}
