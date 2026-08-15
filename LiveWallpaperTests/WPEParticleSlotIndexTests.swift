import Testing
@testable import LiveWallpaper

/// The slot index must reproduce the old linear pool scans exactly: lowest-free
/// selection and ascending live iteration preserve RNG consumption order, draw
/// order, and spawn-event order.
struct WPEParticleSlotIndexTests {

    @Test("Lowest free slot matches a linear scan, across word boundaries")
    func lowestFreeSelection() {
        var index = WPEParticleSlotIndex(capacity: 200)
        #expect(index.lowestFreeSlot == 0)
        for slot in 0..<200 { index.markLive(slot) }
        #expect(index.lowestFreeSlot == nil)
        index.markDead(137)
        #expect(index.lowestFreeSlot == 137)
        index.markDead(64)  // first bit of the second word
        #expect(index.lowestFreeSlot == 64)
        index.markDead(63)  // last bit of the first word
        #expect(index.lowestFreeSlot == 63)
        index.markLive(63)
        index.markLive(64)
        #expect(index.lowestFreeSlot == 137)
    }

    @Test("Live iteration is ascending and crosses word boundaries")
    func ascendingIteration() {
        var index = WPEParticleSlotIndex(capacity: 200)
        let slots = [0, 5, 63, 64, 65, 127, 128, 199]
        for slot in slots.shuffled() { index.markLive(slot) }
        var seen: [Int] = []
        index.forEachLiveSlot { seen.append($0) }
        #expect(seen == slots)
    }

    @Test("markDead removes exactly one slot")
    func deathClearsOneSlot() {
        var index = WPEParticleSlotIndex(capacity: 128)
        for slot in [3, 64, 66] { index.markLive(slot) }
        index.markDead(64)
        var seen: [Int] = []
        index.forEachLiveSlot { seen.append($0) }
        #expect(seen == [3, 66])
        #expect(!index.isLive(64))
        #expect(index.isLive(66))
    }

    @Test("Capacity not divisible by 64 never yields a phantom free slot")
    func partialTailWord() {
        var index = WPEParticleSlotIndex(capacity: 70)
        for slot in 0..<70 { index.markLive(slot) }
        #expect(index.lowestFreeSlot == nil)
        index.markDead(69)
        #expect(index.lowestFreeSlot == 69)
    }

    @Test("8192-capacity edge: last slot allocates, frees, and iterates")
    func absoluteCapEdge() {
        let cap = WPEParticleSystem.absoluteCap
        var index = WPEParticleSlotIndex(capacity: cap)
        for slot in 0..<cap { index.markLive(slot) }
        #expect(index.lowestFreeSlot == nil)
        index.markDead(cap - 1)
        #expect(index.lowestFreeSlot == cap - 1)
        var count = 0
        var last = -1
        index.forEachLiveSlot { slot in
            #expect(slot > last)
            last = slot
            count += 1
        }
        #expect(count == cap - 1)
        #expect(last == cap - 2)
    }

    @Test("removeAll clears every word")
    func removeAllClears() {
        var index = WPEParticleSlotIndex(capacity: 8192)
        for slot in stride(from: 0, to: 8192, by: 61) { index.markLive(slot) }
        index.removeAll()
        var seen = 0
        index.forEachLiveSlot { _ in seen += 1 }
        #expect(seen == 0)
        #expect(index.lowestFreeSlot == 0)
    }
}
