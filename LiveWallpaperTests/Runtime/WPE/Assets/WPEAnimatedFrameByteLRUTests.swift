#if !LITE_BUILD
import Foundation
import Testing
@testable import LiveWallpaper

@Suite("WPEAnimatedFrameByteCache byte LRU")
struct WPEAnimatedFrameByteLRUTests {

    private func makeCache(budget: Int = 1_000, admissionCap: Int = 1_000) -> WPEAnimatedFrameByteCache {
        WPEAnimatedFrameByteCache(budgetBytes: budget, admissionByteCap: admissionCap)
    }

    private func bytes(_ count: Int, fill: UInt8 = 0xAB) -> Data {
        Data(repeating: fill, count: count)
    }

    @Test("Store and lookup round-trips per source")
    func storeLookupRoundTrip() {
        let cache = makeCache()
        let a = cache.registerSource()
        let b = cache.registerSource()

        cache.store(bytes(10, fill: 1), source: a, imageID: 0, speculative: false)
        cache.store(bytes(10, fill: 2), source: b, imageID: 0, speculative: false)

        #expect(cache.lookup(source: a, imageID: 0) == bytes(10, fill: 1))
        #expect(cache.lookup(source: b, imageID: 0) == bytes(10, fill: 2))
        #expect(cache.lookup(source: a, imageID: 1) == nil)
        #expect(cache.totalBytes == 20)
    }

    @Test("Over-budget prune evicts speculative entries before consumed ones")
    func speculativeEvictsFirst() {
        let cache = makeCache(budget: 100)
        let source = cache.registerSource()

        // Entry 0: consumed, UNPINNED, and least-recently used. Entry 1:
        // speculative but more recent. A plain LRU sweep would take 0;
        // speculative-first must take 1 instead — this ordering is what
        // discriminates the policy from generic LRU.
        cache.store(bytes(40), source: source, imageID: 0, speculative: false)
        cache.store(bytes(40), source: source, imageID: 1, speculative: true)
        cache.store(bytes(40), source: source, imageID: 2, speculative: false)

        #expect(!cache.contains(source: source, imageID: 1))
        #expect(cache.contains(source: source, imageID: 0))
        #expect(cache.contains(source: source, imageID: 2))
    }

    @Test("Prune applies hysteresis down to 80% of budget")
    func pruneHysteresisTo80Percent() {
        let cache = makeCache(budget: 100)
        let source = cache.registerSource()

        // 6 speculative entries of 20B = 120B > 100B budget triggers a prune
        // that must continue to ≤80B, not stop at 100B.
        for imageID in 0..<6 {
            cache.store(bytes(20), source: source, imageID: imageID, speculative: true)
        }
        #expect(cache.totalBytes <= 80)
    }

    @Test("Pinned current frame survives critical trim; speculative trim keeps consumed entries")
    func pinnedSurvivesTrims() {
        let cache = makeCache()
        let source = cache.registerSource()

        cache.store(bytes(10), source: source, imageID: 0, speculative: false)
        _ = cache.lookup(source: source, imageID: 0) // pins imageID 0
        cache.store(bytes(10), source: source, imageID: 1, speculative: true)
        cache.store(bytes(10), source: source, imageID: 2, speculative: false)

        cache.removeSpeculative()
        #expect(!cache.contains(source: source, imageID: 1))
        #expect(cache.contains(source: source, imageID: 0))
        #expect(cache.contains(source: source, imageID: 2))

        cache.removeAllUnpinned()
        #expect(cache.contains(source: source, imageID: 0))
        #expect(!cache.contains(source: source, imageID: 2))
    }

    @Test("Frames above the admission cap are never stored")
    func oversizeFramesBypassCache() {
        let cache = makeCache(budget: 1_000, admissionCap: 64)
        let source = cache.registerSource()

        #expect(!cache.store(bytes(65), source: source, imageID: 0, speculative: false))
        #expect(!cache.contains(source: source, imageID: 0))
        #expect(cache.totalBytes == 0)

        #expect(cache.store(bytes(64), source: source, imageID: 1, speculative: false))
        #expect(cache.contains(source: source, imageID: 1))
    }

    @Test("Unregistering a source returns its lease")
    func unregisterReturnsLease() {
        let cache = makeCache()
        let a = cache.registerSource()
        let b = cache.registerSource()
        cache.store(bytes(30), source: a, imageID: 0, speculative: false)
        _ = cache.lookup(source: a, imageID: 0)
        cache.store(bytes(30), source: b, imageID: 0, speculative: false)

        cache.unregisterSource(a)
        #expect(!cache.contains(source: a, imageID: 0))
        #expect(cache.contains(source: b, imageID: 0))
        #expect(cache.totalBytes == 30)

        // The dropped pin must not shield anything from a later trim: b was
        // never looked up, so nothing is pinned and the trim must empty the cache.
        cache.removeAllUnpinned()
        #expect(cache.totalBytes == 0)
        #expect(!cache.contains(source: b, imageID: 0))
    }

    @Test("A live pin survives another source's unregistration and a trim")
    func pinSurvivesUnregisterAndTrim() {
        let cache = makeCache()
        let a = cache.registerSource()
        let b = cache.registerSource()
        cache.store(bytes(30), source: a, imageID: 0, speculative: false)
        cache.store(bytes(30), source: b, imageID: 0, speculative: false)
        _ = cache.lookup(source: b, imageID: 0)

        cache.unregisterSource(a)
        cache.removeAllUnpinned()
        #expect(cache.contains(source: b, imageID: 0))
        #expect(cache.totalBytes == 30)
    }

    @Test("Lookup consumes the speculative flag")
    func lookupConsumesSpeculativeFlag() {
        let cache = makeCache()
        let source = cache.registerSource()
        cache.store(bytes(10), source: source, imageID: 0, speculative: true)
        _ = cache.lookup(source: source, imageID: 0)
        cache.store(bytes(10), source: source, imageID: 1, speculative: false)

        cache.removeSpeculative()
        // Once consumed, the former speculative entry must survive the trim.
        #expect(cache.contains(source: source, imageID: 0))
        #expect(cache.contains(source: source, imageID: 1))
    }
}
#endif
