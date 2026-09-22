import CoreGraphics
import Foundation
@testable import LiveWallpaper
import Testing

/// R-24 ⑤: the float strip and the modal panel share the top of the window, so the panel's top is
/// a clearance under the strip rather than a centring that walks into it.
@Suite("Modal geometry — the panel box against the float strip")
struct ModalGeometryTests {
    private static let tiers = [
        CGSize(width: 1280, height: 820),
        CGSize(width: 1040, height: 700),
        CGSize(width: 1280, height: 500),
    ]

    @Test("No window tier lets the panel climb under the float strip")
    func panelClearsTheStripInEveryTier() {
        for size in Self.tiers {
            let panel = ModalGeometry.panelFrame(in: size)
            let stripBottom = FloatLayerGeometry.panelTop + FloatLayerGeometry.panelHeight
            #expect(
                panel.minY >= stripBottom + 12,
                Comment(rawValue: "\(size): panel \(panel) starts above strip bottom \(stripBottom) + 12")
            )
            #expect(
                panel.maxY <= size.height - ModalGeometry.edgeMargin,
                Comment(rawValue: "\(size): panel \(panel) runs past the \(ModalGeometry.edgeMargin)pt bottom margin")
            )
        }
    }

    @Test("820 hangs the panel at 150; 700 drops it to 130 and pays in height, not in margin")
    func panelRectanglesPerTier() {
        let tall = ModalGeometry.panelFrame(in: CGSize(width: 1280, height: 820))
        #expect(tall == CGRect(x: 200, y: 150, width: 880, height: 560), Comment(rawValue: "\(tall)"))
        let short = ModalGeometry.panelFrame(in: CGSize(width: 1040, height: 700))
        #expect(short == CGRect(x: 80, y: 130, width: 880, height: 554), Comment(rawValue: "\(short)"))
        let shorter = ModalGeometry.panelFrame(in: CGSize(width: 1280, height: 500))
        #expect(shorter == CGRect(x: 200, y: 130, width: 880, height: 354), Comment(rawValue: "\(shorter)"))
    }

    @Test("The preview takes whatever the margin and the bottom bar leave in that tier")
    func previewTakesTheRemainingHeight() {
        let tall = ModalGeometry.previewSize(inPanel: ModalGeometry.panelFrame(in: CGSize(width: 1280, height: 820)))
        #expect(tall == CGSize(width: 856, height: 360), Comment(rawValue: "\(tall)"))
        let short = ModalGeometry.previewSize(inPanel: ModalGeometry.panelFrame(in: CGSize(width: 1040, height: 700)))
        #expect(short == CGSize(width: 856, height: 354), Comment(rawValue: "\(short)"))
    }

    @Test("Both hosts hang the strip from the one geometry constant")
    func bothHostsShareTheStripTop() throws {
        for path in [
            "LiveWallpaper/Views/EditDesk/Library/LibraryModalHost.swift",
            "LiveWallpaper/Views/EditDesk/Workshop/WorkshopModalHost.swift",
        ] {
            let source = try RepositoryRoot.source(path)
            #expect(
                !source.contains("floatTop: CGFloat = 14"),
                Comment(rawValue: "\(path) keeps its own copy of the strip's top")
            )
            #expect(source.contains("FloatLayerGeometry.panelTop"), Comment(rawValue: path))
        }
    }
}
