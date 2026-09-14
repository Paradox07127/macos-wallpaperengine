import Foundation
import Testing
@testable import LiveWallpaper

@Suite("lwmem:// data-request byte ranges")
struct InMemoryVideoAssetLoaderRangeTests {

    private static let windowLength = 60 * 1024 * 1024

    /// AVAssetResourceLoader.h 要求:`requestsAllDataToEndOfResource` 置位时
    /// 必须无视 `requestedLength`。
    @Test("A to-EOF request with a finite hint still runs to the end of the window")
    func toEndOfResourceIgnoresFiniteHint() {
        let range = InMemoryVideoAssetLoader.logicalRange(
            currentOffset: 0,
            requestedLength: 2 * 1024 * 1024,
            requestsAllDataToEndOfResource: true,
            windowLength: Self.windowLength
        )
        #expect(range == 0..<Self.windowLength)
    }

    @Test("A to-EOF request resumed mid-window runs from the current offset to the end")
    func toEndOfResourceResumesFromCurrentOffset() {
        let range = InMemoryVideoAssetLoader.logicalRange(
            currentOffset: 8 * 1024 * 1024,
            requestedLength: 65536,
            requestsAllDataToEndOfResource: true,
            windowLength: Self.windowLength
        )
        #expect(range == (8 * 1024 * 1024)..<Self.windowLength)
    }

    /// NSIntegerMax is what AVFoundation sends before contentLength is reported.
    @Test("An Int.max length is still treated as to-EOF")
    func integerMaxLengthReachesEnd() {
        let range = InMemoryVideoAssetLoader.logicalRange(
            currentOffset: 0,
            requestedLength: Int.max,
            requestsAllDataToEndOfResource: false,
            windowLength: Self.windowLength
        )
        #expect(range == 0..<Self.windowLength)
    }

    @Test("An ordinary bounded range is served exactly")
    func boundedRangeIsExact() {
        let range = InMemoryVideoAssetLoader.logicalRange(
            currentOffset: 1024,
            requestedLength: 4096,
            requestsAllDataToEndOfResource: false,
            windowLength: Self.windowLength
        )
        #expect(range == 1024..<5120)
    }

    @Test("A bounded range past the window clamps instead of over-reading")
    func boundedRangeClampsToWindow() {
        let range = InMemoryVideoAssetLoader.logicalRange(
            currentOffset: Int64(Self.windowLength - 1024),
            requestedLength: 1024 * 1024,
            requestsAllDataToEndOfResource: false,
            windowLength: Self.windowLength
        )
        #expect(range == (Self.windowLength - 1024)..<Self.windowLength)
    }

    @Test("A to-EOF request whose length is also Int.max still reaches the end")
    func toEndOfResourceWithIntegerMaxLength() {
        let range = InMemoryVideoAssetLoader.logicalRange(
            currentOffset: 0,
            requestedLength: Int.max,
            requestsAllDataToEndOfResource: true,
            windowLength: Self.windowLength
        )
        #expect(range == 0..<Self.windowLength)
    }

    @Test("An offset past the window yields an empty range instead of an invalid one")
    func offsetPastWindowIsEmpty() {
        let toEnd = InMemoryVideoAssetLoader.logicalRange(
            currentOffset: Int64(Self.windowLength + 4096),
            requestedLength: 65536,
            requestsAllDataToEndOfResource: true,
            windowLength: Self.windowLength
        )
        let bounded = InMemoryVideoAssetLoader.logicalRange(
            currentOffset: Int64(Self.windowLength + 4096),
            requestedLength: 65536,
            requestsAllDataToEndOfResource: false,
            windowLength: Self.windowLength
        )
        #expect(toEnd.isEmpty)
        #expect(bounded.isEmpty)
    }

    @Test("A zero or negative length yields an empty range at the current offset")
    func nonPositiveLengthIsEmpty() {
        let zero = InMemoryVideoAssetLoader.logicalRange(
            currentOffset: 4096,
            requestedLength: 0,
            requestsAllDataToEndOfResource: false,
            windowLength: Self.windowLength
        )
        let negative = InMemoryVideoAssetLoader.logicalRange(
            currentOffset: 4096,
            requestedLength: -4096,
            requestsAllDataToEndOfResource: false,
            windowLength: Self.windowLength
        )
        #expect(zero == 4096..<4096)
        #expect(negative == 4096..<4096)
    }

    @Test("A negative offset is treated as the start of the window")
    func negativeOffsetClampsToZero() {
        let range = InMemoryVideoAssetLoader.logicalRange(
            currentOffset: -1,
            requestedLength: 4096,
            requestsAllDataToEndOfResource: false,
            windowLength: Self.windowLength
        )
        #expect(range == 0..<4096)
    }

    @Test("An empty window never yields a non-empty range")
    func emptyWindowServesNothing() {
        let range = InMemoryVideoAssetLoader.logicalRange(
            currentOffset: 0,
            requestedLength: 65536,
            requestsAllDataToEndOfResource: true,
            windowLength: 0
        )
        #expect(range.isEmpty)
    }

    @Test("An ordinary local file counts as mappable")
    func localFileIsMappable() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lwmem-volume-probe.bin")
        try Data(repeating: 0, count: 1024).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(InMemoryVideoAssetLoader.isVolumeMappable(url))
    }

    /// `offset &+ requestedLength` 在这里会回绕成负数,使 chunk 循环服务
    /// 零字节后直接 finish。
    @Test("A length that overflows the offset falls back to the end of the window")
    func overflowingLengthDoesNotServeNothing() {
        let range = InMemoryVideoAssetLoader.logicalRange(
            currentOffset: 4096,
            requestedLength: Int.max - 8,
            requestsAllDataToEndOfResource: false,
            windowLength: Self.windowLength
        )
        #expect(range == 4096..<Self.windowLength)
    }
}
