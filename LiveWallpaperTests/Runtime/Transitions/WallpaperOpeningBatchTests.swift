import CoreGraphics
@testable import LiveWallpaper
import Testing

@Suite("Wallpaper opening batch")
@MainActor
struct WallpaperOpeningBatchTests {
    @Test("Each display in the batch claims the opening exactly once")
    func eachDisplayClaimsOnce() {
        let batch = WallpaperOpeningBatch(displayIDs: [1, 2], effect: .frame)
        #expect(batch.claim(1)?.effect == .frame)
        #expect(batch.claim(1)?.effect == nil)
        #expect(batch.claim(2)?.effect == .frame)
        #expect(batch.claim(2)?.effect == nil)
    }

    @Test("A display outside the batch claims nothing")
    func outsiderClaimsNothing() {
        let batch = WallpaperOpeningBatch(displayIDs: [1], effect: .loom)
        #expect(batch.claim(7)?.effect == nil)
        #expect(batch.claim(1)?.effect == .loom)
    }

    @Test("Nothing is claimed once the lifetime has passed")
    func expiresAfterLifetime() {
        var now = ContinuousClock.now
        let batch = WallpaperOpeningBatch(displayIDs: [1, 2], effect: .dawn, lifetime: .seconds(60), now: { now })
        now = now.advanced(by: .seconds(59))
        #expect(batch.claim(1)?.effect == .dawn)
        now = now.advanced(by: .seconds(2))
        #expect(batch.claim(2)?.effect == nil)
    }

    @Test("Every display in one batch shares the batch's start barrier; another batch has its own")
    func displaysShareTheBatchBarrier() throws {
        let batch = WallpaperOpeningBatch(displayIDs: [1, 2], effect: .loom)
        let other = WallpaperOpeningBatch(displayIDs: [1], effect: .loom)
        let first = try #require(batch.claim(1))
        let second = try #require(batch.claim(2))
        let elsewhere = try #require(other.claim(1))
        #expect(first.barrier === batch.barrier)
        #expect(second.barrier === first.barrier)
        #expect(elsewhere.barrier !== first.barrier)
    }

    @Test("Every display in one batch gets the same effect", arguments: WallpaperOpeningEffect.allCases)
    func everyDisplaySharesTheEffect(effect: WallpaperOpeningEffect) {
        let ids: Set<CGDirectDisplayID> = [3, 4, 5]
        let batch = WallpaperOpeningBatch(displayIDs: ids, effect: effect)
        #expect(ids.map { batch.claim($0)?.effect } == Array(repeating: effect, count: ids.count))
    }
}
