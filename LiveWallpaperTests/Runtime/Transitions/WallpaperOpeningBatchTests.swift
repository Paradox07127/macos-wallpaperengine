import CoreGraphics
@testable import LiveWallpaper
import Testing

@Suite("Wallpaper opening batch")
@MainActor
struct WallpaperOpeningBatchTests {
    @Test("Each display in the batch claims the opening exactly once")
    func eachDisplayClaimsOnce() {
        let batch = WallpaperOpeningBatch(displayIDs: [1, 2], effect: .frame)
        #expect(batch.claim(1) == .frame)
        #expect(batch.claim(1) == nil)
        #expect(batch.claim(2) == .frame)
        #expect(batch.claim(2) == nil)
    }

    @Test("A display outside the batch claims nothing")
    func outsiderClaimsNothing() {
        let batch = WallpaperOpeningBatch(displayIDs: [1], effect: .loom)
        #expect(batch.claim(7) == nil)
        #expect(batch.claim(1) == .loom)
    }

    @Test("Nothing is claimed once the lifetime has passed")
    func expiresAfterLifetime() {
        var now = ContinuousClock.now
        let batch = WallpaperOpeningBatch(displayIDs: [1, 2], effect: .dawn, lifetime: .seconds(60), now: { now })
        now = now.advanced(by: .seconds(59))
        #expect(batch.claim(1) == .dawn)
        now = now.advanced(by: .seconds(2))
        #expect(batch.claim(2) == nil)
    }

    @Test("Every display in one batch gets the same effect", arguments: WallpaperOpeningEffect.allCases)
    func everyDisplaySharesTheEffect(effect: WallpaperOpeningEffect) {
        let ids: Set<CGDirectDisplayID> = [3, 4, 5]
        let batch = WallpaperOpeningBatch(displayIDs: ids, effect: effect)
        #expect(ids.map { batch.claim($0) } == Array(repeating: effect, count: ids.count))
    }
}
