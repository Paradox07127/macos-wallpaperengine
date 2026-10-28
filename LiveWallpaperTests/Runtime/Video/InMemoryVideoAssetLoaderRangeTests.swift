import Foundation
@testable import LiveWallpaper
import os
import Testing

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

@Suite("lwmem:// teardown and served-chunk lifetime", .timeLimit(.minutes(1)))
struct InMemoryVideoAssetLoaderTeardownTests {
    private static let chunkSize = 2 * 1024 * 1024

    private final class Probe: Sendable {}

    private func makeLoader(byteCount: Int) -> InMemoryVideoAssetLoader {
        let bytes = Data(repeating: 0x5A, count: byteCount)
        return InMemoryVideoAssetLoader(data: bytes, mimeType: "video/mp4", windowStart: 0, windowLength: byteCount)
    }

    private func waitUntil(seconds: Double, _ condition: () -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < deadline else { return false }
            try await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    @Test("A request cancelled mid-range gets no further chunks and is not finished")
    func cancelledRequestStopsServing() {
        let loader = makeLoader(byteCount: 3 * Self.chunkSize)
        var responded = 0
        let outcome = loader.serve(
            range: 0 ..< (3 * Self.chunkSize),
            isCancelled: { responded >= 1 },
            respond: { _ in responded += 1 }
        )
        #expect(responded == 1)
        #expect(outcome == .cancelled)
    }

    @Test("A closed loader serves nothing")
    func closedLoaderServesNothing() {
        let loader = makeLoader(byteCount: Self.chunkSize)
        loader.close()
        var responded = 0
        let outcome = loader.serve(range: 0 ..< 4096, isCancelled: { false }, respond: { _ in responded += 1 })
        #expect(responded == 0)
        #expect(outcome == .closed)
    }

    @Test("Closing between chunks stops the rest of the range and reports the close")
    func closeMidRangeStopsServing() {
        let loader = makeLoader(byteCount: 3 * Self.chunkSize)
        var responded = 0
        let outcome = loader.serve(range: 0 ..< (3 * Self.chunkSize), isCancelled: { false }, respond: { _ in
            responded += 1
            loader.close()
        })
        #expect(responded == 1)
        #expect(outcome == .closed)
    }

    @Test("Served chunks count as in flight until the receiver releases them")
    func heldChunksKeepTheLoaderUndrained() {
        let loader = makeLoader(byteCount: Self.chunkSize + 4096)
        var held: [Data] = []
        let outcome = loader.serve(
            range: 0 ..< (Self.chunkSize + 4096),
            isCancelled: { false },
            respond: { held.append($0) }
        )
        #expect(outcome == .finished)
        #expect(held.count == 2)
        #expect(!loader.isDrained)
        held.removeLast()
        #expect(!loader.isDrained)
        held.removeAll()
        #expect(loader.isDrained)
    }

    @Test("A drain handler waits for the last held chunk")
    func drainHandlerWaitsForHeldChunk() async throws {
        let loader = makeLoader(byteCount: 4096)
        var held: Data?
        _ = loader.serve(range: 0 ..< 4096, isCancelled: { false }, respond: { held = $0 })
        let fired = OSAllocatedUnfairLock(initialState: false)
        loader.notifyWhenDrained(timeout: 30) { fired.withLock { $0 = true } }
        try await Task.sleep(for: .milliseconds(100))
        #expect(!fired.withLock { $0 })
        #expect(held?.count == 4096)
        held = nil
        #expect(try await waitUntil(seconds: 5) { fired.withLock { $0 } })
    }

    @Test("Retired objects outlive the call until the held chunk is released")
    func retireKeepsObjectsUntilDrained() async throws {
        let loader = makeLoader(byteCount: 4096)
        var held: Data?
        weak var probe: Probe?
        do {
            let object = Probe()
            probe = object
            _ = loader.serve(range: 0 ..< 4096, isCancelled: { false }, respond: { held = $0 })
            loader.retire([object], timeout: 30)
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(probe != nil)
        #expect(held?.count == 4096)
        held = nil
        #expect(try await waitUntil(seconds: 5) { probe == nil })
    }

    @Test("Retired objects are released after the timeout when a chunk is never returned")
    func retireFallsBackToTimeout() async throws {
        let loader = makeLoader(byteCount: 4096)
        var held: Data?
        weak var probe: Probe?
        do {
            let object = Probe()
            probe = object
            _ = loader.serve(range: 0 ..< 4096, isCancelled: { false }, respond: { held = $0 })
            loader.retire([object], timeout: 0.1)
        }
        #expect(try await waitUntil(seconds: 5) { probe == nil })
        #expect(held != nil)
    }

    @Test("Chunks served from a mapped file are copies outside the mapping")
    func chunksDoNotAliasTheMapping() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lwmem-chunk-copy-\(UUID().uuidString).bin")
        try Data(repeating: 0x33, count: Self.chunkSize + 65536).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let mapped = try Data(contentsOf: url, options: .alwaysMapped)
        let loader = InMemoryVideoAssetLoader(
            data: mapped, mimeType: "video/mp4", windowStart: 0, windowLength: mapped.count
        )
        var chunks: [Data] = []
        _ = loader.serve(range: 0 ..< mapped.count, isCancelled: { false }, respond: { chunks.append($0) })
        #expect(chunks.count == 2)
        mapped.withUnsafeBytes { mapping in
            let low = UInt(bitPattern: mapping.baseAddress)
            let high = low + UInt(mapping.count)
            for chunk in chunks {
                chunk.withUnsafeBytes { bytes in
                    let address = UInt(bitPattern: bytes.baseAddress)
                    #expect(address < low || address >= high)
                }
            }
        }
        #expect(chunks.reduce(0) { $0 + $1.count } == mapped.count)
    }
}
