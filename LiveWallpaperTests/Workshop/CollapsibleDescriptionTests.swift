#if !LITE_BUILD
import CoreGraphics
import Foundation
@testable import LiveWallpaper
import Testing

@Suite("Workshop description collapse")
struct CollapsibleDescriptionTests {
    private let collapsedHeight: CGFloat = 116

    @Test("Without a line limit the crop is the 116pt box, as the detail sheet has always shown it")
    func heightCropDecidesExpandability() {
        #expect(CollapsibleDescription.isExpandable(
            fullHeight: 240, limitedHeight: 240, collapsedHeight: collapsedHeight, lineLimit: nil
        ))
        #expect(CollapsibleDescription.isExpandable(
            fullHeight: 80, limitedHeight: 80, collapsedHeight: collapsedHeight, lineLimit: nil
        ) == false)
        // A text exactly as tall as the box is not worth a toggle.
        #expect(CollapsibleDescription.isExpandable(
            fullHeight: collapsedHeight, limitedHeight: collapsedHeight, collapsedHeight: collapsedHeight, lineLimit: nil
        ) == false)
    }

    @Test("With a line limit the toggle follows the lines the limit drops, not the 116pt box")
    func lineLimitDecidesExpandability() {
        // Three lines of a six-line description: shorter than the box, yet still clipped.
        #expect(CollapsibleDescription.isExpandable(
            fullHeight: 96, limitedHeight: 48, collapsedHeight: collapsedHeight, lineLimit: 3
        ))
        // Taller than the box but within the limit: nothing is hidden, so no toggle.
        #expect(CollapsibleDescription.isExpandable(
            fullHeight: 130, limitedHeight: 130, collapsedHeight: collapsedHeight, lineLimit: 8
        ) == false)
    }

    @Test("A line limit crops by lines, so the point crop steps aside")
    func lineLimitReplacesTheHeightCrop() {
        #expect(CollapsibleDescription.cropHeight(
            fullHeight: 240, collapsedHeight: collapsedHeight, collapsed: true, lineLimit: nil
        ) == collapsedHeight)
        #expect(CollapsibleDescription.cropHeight(
            fullHeight: 240, collapsedHeight: collapsedHeight, collapsed: false, lineLimit: nil
        ) == 240)
        #expect(CollapsibleDescription.cropHeight(
            fullHeight: 240, collapsedHeight: collapsedHeight, collapsed: true, lineLimit: 3
        ) == nil)
        // Nothing measured yet: the text sizes itself rather than snapping to a stale box.
        #expect(CollapsibleDescription.cropHeight(
            fullHeight: 0, collapsedHeight: collapsedHeight, collapsed: true, lineLimit: nil
        ) == nil)
    }

    @Test("The measured height follows the width back down, and the expanded text grows in place")
    func measuredHeightIsNotLatched() throws {
        let source = try RepositoryRoot.source("LiveWallpaper/Views/Workshop/DetailSheet.swift")
        let component = try #require(source.range(of: "struct CollapsibleDescription: View {"))
        let body = String(source[component.lowerBound...])
        #expect(!body.contains("max(fullHeight,"), "fullHeight still latches at its tallest measurement")
        #expect(!body.contains("expandedMaxHeight"), "the expanded description is still capped")
        #expect(!body.contains("ScrollView"), "the expanded description scrolls inside a box of its own")
    }
}
#endif
