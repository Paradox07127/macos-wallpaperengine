import Testing
import Foundation
@testable import LiveWallpaperCore

@Suite("Marquee on hover")
struct MarqueeMetricsTests {

    @Test("Scrolls only when the text is actually wider than its box")
    func scrollsOnlyOnRealOverflow() {
        // Control: identical inputs except for the overflow itself.
        #expect(MarqueeMetrics.shouldScroll(
            textWidth: 300, containerWidth: 200, isHovering: true, reduceMotion: false
        ))
        #expect(!MarqueeMetrics.shouldScroll(
            textWidth: 180, containerWidth: 200, isHovering: true, reduceMotion: false
        ))
    }

    @Test("Sub-pixel overflow is rounding noise, not hidden text")
    func subPixelOverflowDoesNotScroll() {
        #expect(!MarqueeMetrics.shouldScroll(
            textWidth: 200.4, containerWidth: 200, isHovering: true, reduceMotion: false
        ))
        // Control: one pixel further and it is real.
        #expect(MarqueeMetrics.shouldScroll(
            textWidth: 202, containerWidth: 200, isHovering: true, reduceMotion: false
        ))
    }

    @Test("Pointer away and Reduce Motion both keep the ellipsis")
    func restingStatesDoNotScroll() {
        #expect(!MarqueeMetrics.shouldScroll(
            textWidth: 300, containerWidth: 200, isHovering: false, reduceMotion: false
        ))
        #expect(!MarqueeMetrics.shouldScroll(
            textWidth: 300, containerWidth: 200, isHovering: true, reduceMotion: true
        ))
        // Control: the same overflow does scroll once both gates open.
        #expect(MarqueeMetrics.shouldScroll(
            textWidth: 300, containerWidth: 200, isHovering: true, reduceMotion: false
        ))
    }

    @Test("An unmeasured box never scrolls")
    func unmeasuredBoxDoesNotScroll() {
        #expect(!MarqueeMetrics.shouldScroll(
            textWidth: 300, containerWidth: 0, isHovering: true, reduceMotion: false
        ))
    }

    @Test("The scrolling copy is laid out at full width, not the row's width")
    func scrollingCopyEscapesTheRowWidth() throws {
        let source = try RepositoryRoot.source(
            "Packages/LiveWallpaperCore/Sources/LiveWallpaperCore/UI/Components/MarqueeOnHover.swift"
        )

        // Without `fixedSize` the visible copy stays clamped to the row, so the
        // crawl slides the *truncated* string and the tail never appears. That
        // was the first version's bug, and no amount of metric testing sees it.
        guard let visible = source.range(of: "if shouldScroll {"),
              let rest = source.range(of: "} else {", range: visible.upperBound..<source.endIndex) else {
            Issue.record("Could not find the scrolling branch")
            return
        }
        let scrollingBranch = String(source[visible.upperBound..<rest.lowerBound])
        #expect(scrollingBranch.contains(".fixedSize(horizontal: true, vertical: false)"))
        #expect(scrollingBranch.contains(".offset(x: offset)"))

        // The invisible base keeps truncating, which is what pins the row width
        // an overlay is then free to overflow.
        #expect(source.contains(".truncationMode(truncationMode)\n            .opacity(0)"))
    }

    @Test("Longer text takes proportionally longer, with a floor")
    func durationScalesWithOverflow() {
        let short = MarqueeMetrics.duration(overflow: 45)
        let long = MarqueeMetrics.duration(overflow: 450)
        #expect(long > short)
        // Constant speed: ten times the distance takes ten times as long.
        #expect(abs(long - short * 10) < 0.001)
        // A few stray pixels must not produce a 0.02s twitch.
        #expect(MarqueeMetrics.duration(overflow: 3) >= 0.6)
    }
}
