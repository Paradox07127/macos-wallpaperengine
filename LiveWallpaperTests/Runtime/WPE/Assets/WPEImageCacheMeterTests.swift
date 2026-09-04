import Foundation
import Testing
@testable import LiveWallpaper

/// A plain, non-`NSObject` final class — the same shape as the real cached
/// values (`WPEPreviewDecodedImage`, `CGImageBox`), so these tests also exercise
/// identity surviving the round trip out through `NSCacheDelegate`'s `Any`.
private final class Box {}

@Suite("WPEImageCacheMeter")
struct WPEImageCacheMeterTests {

    private static func makeCache(countLimit: Int) -> NSCache<NSString, Box> {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = countLimit
        return cache
    }

    /// Pins: live bytes are the exact sum of the costs handed to `recordInsert`.
    @Test("Live bytes equal the sum of the inserted costs")
    func liveBytesEqualTheSumOfInsertedCosts() {
        let accountant = WPEImageCacheAccountant()
        let cache = Self.makeCache(countLimit: 100)
        accountant.attach(cache, as: .scenePreviewDecoded)

        let costs = [1_111, 22_222, 333_333, 4]
        var boxes: [Box] = []
        for (index, cost) in costs.enumerated() {
            let box = Box()
            boxes.append(box)
            accountant.recordInsert(box, cost: cost, in: .scenePreviewDecoded)
            cache.setObject(box, forKey: "k\(index)" as NSString, cost: cost)
        }

        let stats = accountant.stats(for: .scenePreviewDecoded)
        #expect(stats.liveBytes == costs.reduce(0, +))
        #expect(stats.liveCount == costs.count)
        #expect(stats.inserted == costs.count)
        #expect(stats.evicted == 0)
        withExtendedLifetime(boxes) {}
    }

    /// Pins: after `NSCache` evicts, live bytes equal the costs of exactly the
    /// entries still in the cache. Policy-independent — it reads the real
    /// survivors rather than assuming which ones `NSCache` kept — so it catches
    /// both a missed subtraction and a subtraction of the wrong entry's cost.
    @Test("Eviction subtracts exactly the cost that was inserted")
    func evictionSubtractsExactlyWhatWasInserted() {
        let accountant = WPEImageCacheAccountant()
        let cache = Self.makeCache(countLimit: 2)
        accountant.attach(cache, as: .scenePreviewDecoded)

        // Distinct, non-round costs: subtracting the wrong entry cannot land on
        // the right total by coincidence.
        let costs = [1_000, 20_000, 300_000, 4_000_000, 50_000_000]
        var boxes: [Box] = []
        for (index, cost) in costs.enumerated() {
            let box = Box()
            boxes.append(box)
            accountant.recordInsert(box, cost: cost, in: .scenePreviewDecoded)
            cache.setObject(box, forKey: "k\(index)" as NSString, cost: cost)
        }

        let survivors = costs.indices.filter { cache.object(forKey: "k\($0)" as NSString) != nil }
        #expect(survivors.count < costs.count, "nothing was evicted — this test would prove nothing")

        let stats = accountant.stats(for: .scenePreviewDecoded)
        #expect(stats.liveBytes == survivors.map { costs[$0] }.reduce(0, +))
        #expect(stats.liveCount == survivors.count)
        #expect(stats.evicted == costs.count - survivors.count)
        #expect(stats.unattributedEvictions == 0)
        #expect(stats.duplicateInserts == 0)
        withExtendedLifetime(boxes) {}
    }

    /// Pins the two removal paths the accounting depends on. Apple's wording is
    /// only "about to be evicted or removed"; that both explicit paths report
    /// was measured on macOS 27. If a future macOS stops reporting one of them,
    /// live bytes silently become an upper bound — this test is that canary.
    @Test("Explicit removal reports through the eviction delegate")
    func explicitRemovalReportsThroughTheDelegate() {
        let accountant = WPEImageCacheAccountant()
        let cache = Self.makeCache(countLimit: 10)
        accountant.attach(cache, as: .wallpaperThumbnail)

        let costs = [700, 8_000, 90_000]
        var boxes: [Box] = []
        for (index, cost) in costs.enumerated() {
            let box = Box()
            boxes.append(box)
            accountant.recordInsert(box, cost: cost, in: .wallpaperThumbnail)
            cache.setObject(box, forKey: "k\(index)" as NSString, cost: cost)
        }

        cache.removeObject(forKey: "k1")
        let afterRemoveOne = accountant.stats(for: .wallpaperThumbnail)
        #expect(afterRemoveOne.liveBytes == 700 + 90_000)
        #expect(afterRemoveOne.liveCount == 2)
        #expect(afterRemoveOne.evicted == 1)

        cache.removeAllObjects()
        let afterRemoveAll = accountant.stats(for: .wallpaperThumbnail)
        #expect(afterRemoveAll.liveBytes == 0)
        #expect(afterRemoveAll.liveCount == 0)
        #expect(afterRemoveAll.evicted == 3)
        #expect(afterRemoveAll.unattributedEvictions == 0)
        withExtendedLifetime(boxes) {}
    }

    /// Pins: with the defaults key unset — the shipping state — the static shell
    /// accumulates nothing for any cache.
    @Test("The default-off meter records nothing through the static shell")
    func defaultOffMeterRecordsNothing() throws {
        try #require(!WPEImageCacheMeter.isEnabled)
        let cache = Self.makeCache(countLimit: 10)
        let box = Box()
        WPEImageCacheMeter.attach(cache, as: .systemWallpaperLibrary)
        WPEImageCacheMeter.recordInsert(box, cost: 12_345, in: .systemWallpaperLibrary)
        cache.setObject(box, forKey: "k", cost: 12_345)

        for kind in WPEImageCacheKind.allCases {
            #expect(
                WPEImageCacheMeter.shared.stats(for: kind) == WPEImageCacheStats(),
                Comment(rawValue: kind.label)
            )
        }
        withExtendedLifetime(box) {}
    }

    /// Pins: an untouched accountant produces no line at all, and a line names
    /// only the caches that recorded something.
    @Test("The report names only caches that recorded something")
    func reportNamesOnlyCachesThatRecordedSomething() throws {
        #expect(WPEImageCacheAccountant().report() == nil)

        let accountant = WPEImageCacheAccountant()
        let box = Box()
        accountant.recordInsert(box, cost: 3 * 1024 * 1024, in: .scenePreviewDecoded)

        let line = try #require(accountant.report())
        #expect(line == "[imgcache] scenePreview=3.00MiB/1(in:1 ev:0)")
        for kind in WPEImageCacheKind.allCases where kind != .scenePreviewDecoded {
            #expect(!line.contains(kind.label), Comment(rawValue: kind.label))
        }
        withExtendedLifetime(box) {}
    }

    /// Pins: the four caches keep separate ledgers and separate counters —
    /// draining one leaves the other three untouched.
    @Test("Each cache is accounted separately")
    func eachCacheIsAccountedSeparately() {
        func cost(of kind: WPEImageCacheKind) -> Int {
            switch kind {
            case .workshopPreview: 11
            case .scenePreviewDecoded: 222
            case .wallpaperThumbnail: 3_333
            case .systemWallpaperLibrary: 44_444
            }
        }

        let accountant = WPEImageCacheAccountant()
        var caches: [NSCache<NSString, Box>] = []
        var boxes: [Box] = []
        for kind in WPEImageCacheKind.allCases {
            let cache = Self.makeCache(countLimit: 10)
            accountant.attach(cache, as: kind)
            caches.append(cache)
            for index in 0..<3 {
                let box = Box()
                boxes.append(box)
                accountant.recordInsert(box, cost: cost(of: kind), in: kind)
                cache.setObject(box, forKey: "k\(index)" as NSString, cost: cost(of: kind))
            }
        }

        // Drain exactly one cache; nothing may bleed into the other three.
        caches[WPEImageCacheKind.wallpaperThumbnail.rawValue].removeAllObjects()

        for kind in WPEImageCacheKind.allCases {
            let stats = accountant.stats(for: kind)
            let drained = kind == .wallpaperThumbnail
            #expect(stats.liveBytes == (drained ? 0 : cost(of: kind) * 3), Comment(rawValue: kind.label))
            #expect(stats.liveCount == (drained ? 0 : 3), Comment(rawValue: kind.label))
            #expect(stats.inserted == 3, Comment(rawValue: kind.label))
            #expect(stats.evicted == (drained ? 3 : 0), Comment(rawValue: kind.label))
        }
        withExtendedLifetime(boxes) {}
        withExtendedLifetime(caches) {}
    }

    /// Pins the *flag*, not the byte figure: one instance cached under two keys
    /// is reported by `NSCache` as a single eviction, so the meter marks that
    /// cache's live bytes as an upper bound rather than pretending to be exact.
    @Test("One instance under two keys marks the cache as an upper bound")
    func oneInstanceUnderTwoKeysMarksAnUpperBound() throws {
        let accountant = WPEImageCacheAccountant()
        let cache = Self.makeCache(countLimit: 10)
        accountant.attach(cache, as: .workshopPreview)

        let shared = Box()
        for key in ["a", "b"] {
            accountant.recordInsert(shared, cost: 500, in: .workshopPreview)
            cache.setObject(shared, forKey: key as NSString, cost: 500)
        }

        #expect(accountant.stats(for: .workshopPreview).duplicateInserts == 1)
        let line = try #require(accountant.report())
        #expect(line.contains("dup:1=UPPER-BOUND"))
        withExtendedLifetime(shared) {}
    }
}
