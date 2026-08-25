#if !LITE_BUILD
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Testing
import os
@testable import LiveWallpaper

@Suite("Workshop preview disk cache")
struct WorkshopPreviewDiskCacheTests {

    // MARK: - Criterion 1: a disk hit makes no network request

    @Test("A cold-memory loader reads the preview off disk without fetching again")
    @MainActor
    func diskHitMakesNoSecondFetch() async throws {
        let directory = Fixtures.makeDirectory()
        defer { Fixtures.remove(directory) }
        let disk = WorkshopPreviewDiskCache(directoryURL: directory)
        let counter = FetchCounter()
        let bytes = GIFTestFixtures.png(width: 32, height: 18)
        let fetch: WorkshopPreviewByteFetch = { _ in
            await counter.increment()
            return bytes
        }

        let first = WorkshopPreviewImageLoader(diskCache: disk, fetch: fetch)
        #expect(await first.load(Fixtures.url, size: .tile) != nil)
        #expect(await counter.count == 1)

        // A separate instance: its `NSCache` is empty, so only the disk layer
        // can serve this without going back to `fetch`.
        let second = WorkshopPreviewImageLoader(diskCache: disk, fetch: fetch)
        #expect(await second.load(Fixtures.url, size: .tile) != nil)
        #expect(await counter.count == 1)
    }

    // MARK: - Criterion 2: the key separates WorkshopPreviewSize

    @Test("Tile and hero are separate disk entries for one URL")
    func sizeIsPartOfTheDiskKey() async {
        let directory = Fixtures.makeDirectory()
        defer { Fixtures.remove(directory) }
        let cache = WorkshopPreviewDiskCache(directoryURL: directory)
        let tileBytes = GIFTestFixtures.png(width: 32, height: 18)

        #expect(
            WorkshopPreviewDiskCache.fileName(for: Fixtures.url, size: .tile)
                != WorkshopPreviewDiskCache.fileName(for: Fixtures.url, size: .hero)
        )

        await cache.store(tileBytes, for: Fixtures.url, size: .tile)
        #expect(await cache.data(for: Fixtures.url, size: .tile) == tileBytes)
        // The point of the assertion: a tile-sized entry must never be handed
        // out for a hero request.
        #expect(await cache.data(for: Fixtures.url, size: .hero) == nil)
    }

    /// Paired with `diskHitMakesNoSecondFetch`, which is the control: that test
    /// fails if the disk layer stops being read at all, so this one is free to
    /// assert that a *differently sized* request does go back to the network.
    @Test("A hero request after a tile request still fetches")
    @MainActor
    func loaderCarriesSizeIntoTheDiskKey() async throws {
        let directory = Fixtures.makeDirectory()
        defer { Fixtures.remove(directory) }
        let disk = WorkshopPreviewDiskCache(directoryURL: directory)
        let counter = FetchCounter()
        let bytes = GIFTestFixtures.png(width: 64, height: 36)
        let loader = WorkshopPreviewImageLoader(
            diskCache: disk,
            fetch: { _ in
                await counter.increment()
                return bytes
            }
        )

        #expect(await loader.load(Fixtures.url, size: .tile) != nil)
        #expect(await counter.count == 1)
        #expect(await loader.load(Fixtures.url, size: .hero) != nil)
        #expect(await counter.count == 2)
    }

    // MARK: - Criterion 3: atomic writes, concurrent writers

    /// A stress test, not a proof: it catches an implementation that writes
    /// straight to the destination with high probability, not with certainty.
    /// Measured against exactly that mutation: unmutated, 3130 concurrent reads
    /// were all whole; writing to the destination made all 3083 of them short.
    ///
    /// Separate instances throughout, because one instance serialises its own
    /// queue — a single reader could never have more than one read in flight.
    @Test("Concurrent writes of one key never leave a spliced or partial file")
    func concurrentWritesOfOneKeyStayIntact() async throws {
        let directory = Fixtures.makeDirectory()
        defer { Fixtures.remove(directory) }
        let writerA = WorkshopPreviewDiskCache(directoryURL: directory)
        let writerB = WorkshopPreviewDiskCache(directoryURL: directory)
        let readers = (0..<8).map { _ in WorkshopPreviewDiskCache(directoryURL: directory) }
        let payloadA = Data(repeating: 0xAA, count: 4_000_000)
        let payloadB = Data(repeating: 0xBB, count: 8_000_000)

        let observed = await withTaskGroup(of: [Data].self) { group in
            for index in 0..<24 {
                group.addTask {
                    if index.isMultiple(of: 2) {
                        await writerA.store(payloadA, for: Fixtures.url, size: .tile)
                    } else {
                        await writerB.store(payloadB, for: Fixtures.url, size: .tile)
                    }
                    return []
                }
            }
            for reader in readers {
                group.addTask {
                    var seen: [Data] = []
                    for _ in 0..<400 {
                        if let sample = await reader.data(for: Fixtures.url, size: .tile) {
                            seen.append(sample)
                        }
                    }
                    return seen
                }
            }
            var all: [Data] = []
            for await batch in group { all.append(contentsOf: batch) }
            return all
        }

        // `!isEmpty` is load-bearing: a torn read is dropped by the read path
        // rather than returned, so "no bad samples" over zero samples is how
        // this assertion would pass while proving nothing.
        #expect(!observed.isEmpty)
        #expect(observed.allSatisfy { $0 == payloadA || $0 == payloadB })

        let settled = try #require(await readers[0].data(for: Fixtures.url, size: .tile))
        #expect(settled == payloadA || settled == payloadB)

        let leftovers = try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "tmp" }
        #expect(leftovers.isEmpty)
    }

    // MARK: - Criterion 4: bounded, and it cleans up

    @Test("Writing past the byte cap evicts least-recently-used entries")
    func capEvictsRatherThanGrowing() async {
        let directory = Fixtures.makeDirectory()
        defer { Fixtures.remove(directory) }
        let clock = TestClock()
        let cache = WorkshopPreviewDiskCache(
            directoryURL: directory, capBytes: 300_000, now: clock.reader
        )
        let payload = Data(repeating: 0xCD, count: 100_000)
        let urls = (0..<5).map { Fixtures.url(index: $0) }

        for url in urls {
            await cache.store(payload, for: url, size: .tile)
            clock.advance(1)
        }

        #expect(await cache.sizeBytes() <= 300_000)
        // Three 100 KB entries fit; the two oldest were pushed out.
        #expect(await cache.data(for: urls[0], size: .tile) == nil)
        #expect(await cache.data(for: urls[1], size: .tile) == nil)
        #expect(await cache.data(for: urls[4], size: .tile) == payload)
        #expect(await cache.data(for: urls[3], size: .tile) == payload)
    }

    @Test("An entry expires on its age, not on how recently it was read")
    func expiryRunsOnCreationNotOnLastUse() async {
        let directory = Fixtures.makeDirectory()
        defer { Fixtures.remove(directory) }
        let clock = TestClock()
        let cache = WorkshopPreviewDiskCache(
            directoryURL: directory, timeToLive: 100, now: clock.reader
        )
        let payload = Data(repeating: 0xEF, count: 4_096)

        await cache.store(payload, for: Fixtures.url, size: .tile)
        clock.advance(90)
        // This read bumps the LRU stamp. If expiry shared that clock, the entry
        // below would survive — Steam reuses a `preview_url` for a replaced
        // image, so a viewed preview that never expires is a stale preview.
        #expect(await cache.data(for: Fixtures.url, size: .tile) == payload)
        clock.advance(60)
        #expect(await cache.data(for: Fixtures.url, size: .tile) == nil)
    }

    // MARK: - Criterion 5: the decode is unchanged

    @Test("A preview decoded from disk is pixel-identical to one decoded from the response")
    func diskRoundTripDecodesIdentically() async throws {
        let directory = Fixtures.makeDirectory()
        defer { Fixtures.remove(directory) }
        let cache = WorkshopPreviewDiskCache(directoryURL: directory)
        let original = GIFTestFixtures.png(width: 120, height: 68)

        await cache.store(original, for: Fixtures.url, size: .tile)
        let roundTripped = try #require(await cache.data(for: Fixtures.url, size: .tile))
        #expect(roundTripped == original)

        let fromResponse = try #require(
            WorkshopAnimatedGIF.make(from: original, size: .tile)?.posterFrame
        )
        let fromDisk = try #require(
            WorkshopAnimatedGIF.make(from: roundTripped, size: .tile)?.posterFrame
        )
        #expect(fromResponse.width == fromDisk.width)
        #expect(fromResponse.height == fromDisk.height)
        // `#require` on both sides: two `nil`s comparing equal would make this
        // pass without having compared a single pixel.
        let responsePixels = try #require(Fixtures.pixels(of: fromResponse))
        let diskPixels = try #require(Fixtures.pixels(of: fromDisk))
        #expect(responsePixels == diskPixels)
    }

    // MARK: - Criterion 6: bytes that are not an image never reach the disk

    /// Pins: the disk entry is written after the decode has passed judgement,
    /// not before it. Moving the `store` back ahead of the decode turns the
    /// second expectation red; the control group underneath is what stops it
    /// from passing on a loader that stopped writing to disk at all.
    @Test("A 200 image/* body that will not decode is not written to disk")
    @MainActor
    func undecodableBytesAreNotPersisted() async throws {
        let directory = Fixtures.makeDirectory()
        defer { Fixtures.remove(directory) }
        let disk = WorkshopPreviewDiskCache(directoryURL: directory)
        let junk = Data("passed every network check and still is not an image".utf8)
        let loader = WorkshopPreviewImageLoader(diskCache: disk, fetch: { _ in junk })

        #expect(await loader.load(Fixtures.url, size: .tile) == nil)
        #expect(await disk.sizeBytes() == 0)

        // Control group.
        let good = GIFTestFixtures.png(width: 24, height: 14)
        let working = WorkshopPreviewImageLoader(diskCache: disk, fetch: { _ in good })
        #expect(await working.load(Fixtures.url(index: 1), size: .tile) != nil)
        #expect(await disk.data(for: Fixtures.url(index: 1), size: .tile) == good)
    }

    /// The user-visible half of the same defect: a card that came back blank
    /// once used to stay blank, because the bytes that would not decode were on
    /// disk and every later visit hit them instead of the network.
    @Test("A preview that failed to decode is fetched again rather than served from disk")
    @MainActor
    func undecodableBytesDoNotPoisonTheNextVisit() async throws {
        let directory = Fixtures.makeDirectory()
        defer { Fixtures.remove(directory) }
        let disk = WorkshopPreviewDiskCache(directoryURL: directory)
        let script = ScriptedFetch([
            Data("not an image".utf8),
            GIFTestFixtures.png(width: 24, height: 14)
        ])
        let fetch: WorkshopPreviewByteFetch = { _ in await script.next() }

        let first = WorkshopPreviewImageLoader(diskCache: disk, fetch: fetch)
        #expect(await first.load(Fixtures.url, size: .tile) == nil)

        // A separate instance, so its `NSCache` is empty and only the disk layer
        // could answer this without going back to `fetch`.
        let second = WorkshopPreviewImageLoader(diskCache: disk, fetch: fetch)
        #expect(await second.load(Fixtures.url, size: .tile) != nil)
        #expect(await script.calls == 2)
    }

    // MARK: - Criterion 7: the directory is tidied without a write happening

    /// Pins: expiry no longer waits for the next `store`. Deleting the
    /// `sweepOnce()` call from `data(for:size:)` leaves the planted entry in
    /// place and turns the second expectation red.
    @Test("A first read drops an entry that expired since the last session")
    func firstUseSweepRemovesExpiredEntries() async throws {
        let directory = Fixtures.makeDirectory()
        defer { Fixtures.remove(directory) }
        try Fixtures.plant(
            Data(repeating: 0x01, count: 50_000),
            named: "expired.bin",
            in: directory,
            created: Date(timeIntervalSinceNow: -10_000)
        )
        let cache = WorkshopPreviewDiskCache(directoryURL: directory, timeToLive: 100)

        // A miss on an unrelated key: this session stores nothing whatsoever.
        #expect(await cache.data(for: Fixtures.url(index: 99), size: .tile) == nil)
        // `sizeBytes` runs on the same serial queue as the sweep and was
        // enqueued after it, so this observes the swept directory.
        #expect(await cache.sizeBytes() == 0)
    }

    /// Pins the "exited between the rename and the cap check" case: a directory
    /// that is already over the cap comes back under it without a new write.
    @Test("A first read brings an over-cap directory back under the cap")
    func firstUseSweepEnforcesTheCapWithoutAWrite() async throws {
        let directory = Fixtures.makeDirectory()
        defer { Fixtures.remove(directory) }
        let payload = Data(repeating: 0x02, count: 100_000)
        for index in 0..<5 {
            try Fixtures.plant(
                payload,
                named: "entry-\(index).bin",
                in: directory,
                created: Date(timeIntervalSinceNow: -Double(100 - index))
            )
        }
        let cache = WorkshopPreviewDiskCache(directoryURL: directory, capBytes: 250_000)

        // Not a formality: without it, a sweep that deleted everything and a
        // sweep that never saw the files would both satisfy the last line.
        #expect(await cache.sizeBytes() == 500_000)
        #expect(await cache.data(for: Fixtures.url(index: 99), size: .tile) == nil)
        let remaining = await cache.sizeBytes()
        #expect(remaining <= 250_000)
        #expect(remaining > 0)
    }

    /// Pins the crash case: a `.tmp` no total ever counted is removed once it is
    /// older than any write that could still be in flight — and one younger than
    /// that grace is left alone, which is the control group.
    @Test("A first read removes a scratch file a crash left behind and spares a fresh one")
    func firstUseSweepRemovesOrphanedTempFiles() async throws {
        let directory = Fixtures.makeDirectory()
        defer { Fixtures.remove(directory) }
        try Fixtures.plant(
            Data(repeating: 0x03, count: 1_024),
            named: "orphan.bin.\(UUID().uuidString).tmp",
            in: directory,
            created: Date(timeIntervalSinceNow: -3_600)
        )
        try Fixtures.plant(
            Data(repeating: 0x04, count: 1_024),
            named: "fresh.bin.\(UUID().uuidString).tmp",
            in: directory
        )
        let cache = WorkshopPreviewDiskCache(directoryURL: directory)

        #expect(await cache.data(for: Fixtures.url(index: 99), size: .tile) == nil)
        // Barrier only: same serial queue, enqueued behind the sweep.
        _ = await cache.sizeBytes()

        let temps = try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "tmp" }
            .map(\.lastPathComponent)
        #expect(temps.count == 1)
        #expect(temps.allSatisfy { $0.hasPrefix("fresh.bin.") })
    }

    // MARK: - Criterion 8: the privacy posture the ephemeral session bought

    @Test("A cache file is the image bytes verbatim and its name does not disclose the URL")
    func entriesCarryNoHTTPMetadataAndNoURL() async throws {
        let directory = Fixtures.makeDirectory()
        defer { Fixtures.remove(directory) }
        let cache = WorkshopPreviewDiskCache(directoryURL: directory)
        let payload = GIFTestFixtures.png(width: 40, height: 24)

        await cache.store(payload, for: Fixtures.url, size: .tile)

        let files = try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        #expect(files.count == 1)
        let file = try #require(files.first)

        // Byte-for-byte: any envelope carrying headers, a status line, a
        // `Set-Cookie`, or even the URL itself would make this fail.
        let onDisk = try Data(contentsOf: file)
        #expect(onDisk == payload)

        let name = file.lastPathComponent
        #expect(name.range(of: "^[a-f0-9]{64}\\.bin$", options: .regularExpression) != nil)
        #expect(!name.contains("steamuserimages"))
        #expect(!name.contains("akamaihd"))
        #expect(!name.contains("ugc"))

        let permissions = try #require(
            FileManager.default.attributesOfItem(
                atPath: file.path(percentEncoded: false)
            )[.posixPermissions] as? NSNumber
        )
        #expect(permissions.intValue == 0o600)
    }

    @Test("The preview session still refuses cookies and still has no URL cache")
    func sessionStaysCookielessAndUncached() {
        let config = WorkshopPreviewImageLoader.makeSessionConfiguration()
        #expect(config.httpCookieAcceptPolicy == .never)
        #expect(config.httpShouldSetCookies == false)
        // The disk layer is `WorkshopPreviewDiskCache`, which stores image bytes
        // only. Turning `urlCache` on to get one would persist response headers.
        #expect(config.urlCache == nil)
        #expect(config.requestCachePolicy == .reloadIgnoringLocalAndRemoteCacheData)
    }
}

// MARK: - Helpers

private actor FetchCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

/// Hands back one canned response per call, so a test can make the first visit
/// fail to decode and the second one succeed.
private actor ScriptedFetch {
    private var responses: [Data]
    private(set) var calls = 0

    init(_ responses: [Data]) { self.responses = responses }

    func next() -> Data? {
        calls += 1
        return responses.isEmpty ? nil : responses.removeFirst()
    }
}

/// `Sendable`: the one stored property is an `OSAllocatedUnfairLock`, which
/// serialises every read and write of the date it wraps.
private final class TestClock: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_000_000))

    var reader: @Sendable () -> Date {
        { [state] in state.withLock { $0 } }
    }

    func advance(_ seconds: TimeInterval) {
        state.withLock { $0 = $0.addingTimeInterval(seconds) }
    }
}

private enum Fixtures {
    static let url = url(index: 0)

    static func url(index: Int) -> URL {
        URL(string: "https://steamuserimages-a.akamaihd.net/ugc/\(index)/preview.jpg")!
    }

    static func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("workshop-preview-disk-\(UUID().uuidString)", isDirectory: true)
    }

    static func remove(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Puts a file straight into the cache directory, bypassing `store`, so a
    /// test can stage the state an earlier run or a crash would have left and
    /// then assert on what happens with no write at all.
    static func plant(
        _ bytes: Data,
        named name: String,
        in directory: URL,
        created: Date = Date()
    ) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name, isDirectory: false)
        try bytes.write(to: url)
        try fileManager.setAttributes(
            [.creationDate: created, .modificationDate: created],
            ofItemAtPath: url.path(percentEncoded: false)
        )
    }

    static func pixels(of image: CGImage) -> Data? {
        guard let data = image.dataProvider?.data else { return nil }
        return data as Data
    }
}
#endif
