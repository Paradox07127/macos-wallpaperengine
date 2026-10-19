#if !LITE_BUILD
import CoreGraphics
@testable import LiveWallpaper
import Metal
import Testing

struct WPEMetalFrameSubmissionTests {
    @Test("Frame submission slots stay owned until the logical frame is sealed")
    func frameSubmissionWaitsForSealAndEveryCompletion() throws {
        let pool = WPEMetalFrameSubmissionPool(slotCount: 1)
        let submission = try #require(pool.tryAcquire())
        let firstCompletion = submission.registerSubmission()

        firstCompletion.complete()
        #expect(pool.tryAcquire() == nil)

        let secondCompletion = submission.registerSubmission()
        submission.seal()
        #expect(pool.tryAcquire() == nil)

        secondCompletion.complete()
        let recycled = try #require(pool.tryAcquire())
        #expect(recycled.slot == submission.slot)
        recycled.seal()
    }

    @Test("Frame submission completion and seal are idempotent")
    func frameSubmissionReleasesExactlyOnce() throws {
        let pool = WPEMetalFrameSubmissionPool(slotCount: 1)
        let submission = try #require(pool.tryAcquire())
        let completion = submission.registerSubmission()

        submission.seal()
        submission.seal()
        completion.complete()
        completion.complete()

        let recycled = try #require(pool.tryAcquire())
        #expect(pool.tryAcquire() == nil)
        recycled.seal()
    }

    @Test("A frame without a committed command buffer returns its slot when sealed")
    func emptyFrameSubmissionReturnsSlot() throws {
        let pool = WPEMetalFrameSubmissionPool(slotCount: 2)
        let first = try #require(pool.tryAcquire())
        let second = try #require(pool.tryAcquire())
        #expect(first.slot != second.slot)
        #expect(pool.tryAcquire() == nil)

        first.seal()
        let recycled = try #require(pool.tryAcquire())
        #expect(recycled.slot == first.slot)
        recycled.seal()
        second.seal()
    }

    @Test("Span output textures stay owned by consumers and shed stall allocations after release")
    func spanOutputOwnershipAndRecovery() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalPresenter(device: device)
        executor.spanOutputTextureLimit = 8
        let size = CGSize(width: 64, height: 64)
        var held: [MTLTexture] = []
        for _ in 0 ..< 8 {
            let texture = try executor.makeOutputTexture(size: size)
            #expect(!held.contains { $0 === texture }, "A consumer's texture was reused before release")
            executor.presentTracker.increment(ObjectIdentifier(texture))
            held.append(texture)
        }
        #expect(throws: WPEMetalFrameInFlightBudgetExhausted.self) {
            _ = try executor.makeOutputTexture(size: size)
        }
        for texture in held {
            executor.presentTracker.decrement(ObjectIdentifier(texture))
        }
        for _ in 0 ..< 8 {
            _ = try executor.makeOutputTexture(size: size)
        }
        #expect(executor.outputTexturePool.count <= 4, "A temporary span stall permanently retained its output allocations")
    }
}
#endif
