#if !LITE_BUILD
import Foundation
import Metal
import Testing
@testable import LiveWallpaper

@MainActor
@Suite("WPE Metal texture cache budget")
struct WPEMetalTextureCacheBudgetTests {
    @Test("Memory tiers map physical RAM to the expected bucket")
    func memoryTierMapping() {
        let gib: UInt64 = 1_073_741_824
        #expect(WPEMemoryTier.tier(forPhysicalMemoryBytes: 8 * gib) == .constrained)
        #expect(WPEMemoryTier.tier(forPhysicalMemoryBytes: 12 * gib) == .standard)
        #expect(WPEMemoryTier.tier(forPhysicalMemoryBytes: 16 * gib) == .standard)
        #expect(WPEMemoryTier.tier(forPhysicalMemoryBytes: 18 * gib) == .standard)
        #expect(WPEMemoryTier.tier(forPhysicalMemoryBytes: 24 * gib) == .expansive)
        #expect(WPEMemoryTier.tier(forPhysicalMemoryBytes: 64 * gib) == .expansive)
    }

    @Test("Perspective native-res pixel budget bounds the FBO blow-up")
    func perspectiveRenderPixelBudget() {
        let base = 1920.0 * 1080.0
        #expect(WPEMemoryTier.constrained.perspectiveRenderPixelBudget(hdr: false) == base)
        #expect(WPEMemoryTier.constrained.perspectiveRenderPixelBudget(hdr: true) == base * 0.5)
        #expect(WPEMemoryTier.standard.perspectiveRenderPixelBudget(hdr: false) == base * 2.25)
        #expect(WPEMemoryTier.standard.perspectiveRenderPixelBudget(hdr: true) == base * 2.25 * 0.5)
        #expect(WPEMemoryTier.expansive.perspectiveRenderPixelBudget(hdr: false) == base * 4.0)
        #expect(WPEMemoryTier.expansive.perspectiveRenderPixelBudget(hdr: true) == base * 2.0)
        for tier in [WPEMemoryTier.constrained, .standard, .expansive] {
            #expect(tier.perspectiveRenderPixelBudget(hdr: true)
                < tier.perspectiveRenderPixelBudget(hdr: false))
        }
    }

    @Test("Memory tiers carry the intended renderer defaults")
    func memoryTierDefaults() {
        #expect(WPEMemoryTier.constrained.defaultTextureCacheBudgetBytes == 256 * 1_048_576)
        #expect(WPEMemoryTier.standard.defaultTextureCacheBudgetBytes == 512 * 1_048_576)
        #expect(WPEMemoryTier.expansive.defaultTextureCacheBudgetBytes == 768 * 1_048_576)
        #expect(WPEMemoryTier.constrained.lazyAnimationRawByteThreshold == 100_000_000)
        #expect(WPEMemoryTier.standard.lazyAnimationRawByteThreshold == 200_000_000)
        #expect(WPEMemoryTier.expansive.lazyAnimationRawByteThreshold == 200_000_000)
        #expect(WPEMemoryTier.constrained.videoDecoderLimit == 2)
        #expect(WPEMemoryTier.standard.videoDecoderLimit == 4)
        #expect(WPEMemoryTier.expansive.videoDecoderLimit == 6)
    }

    @Test("Budget resolution: unset follows the tier, manual value always wins")
    func budgetResolutionPrecedence() {
        for tier in [WPEMemoryTier.constrained, .standard, .expansive] {
            #expect(WPEMetalSceneRenderer.resolvedTextureCacheBudgetBytes(manualValue: nil, tier: tier)
                == tier.defaultTextureCacheBudgetBytes)
            #expect(WPEMetalSceneRenderer.resolvedTextureCacheBudgetBytes(manualValue: 0, tier: tier) == nil)
            #expect(WPEMetalSceneRenderer.resolvedTextureCacheBudgetBytes(manualValue: -5, tier: tier) == nil)
            #expect(WPEMetalSceneRenderer.resolvedTextureCacheBudgetBytes(manualValue: "junk", tier: tier) == nil)
            #expect(WPEMetalSceneRenderer.resolvedTextureCacheBudgetBytes(manualValue: 64, tier: tier)
                == 64 * 1_048_576)
        }
    }

    @Test("Budget defaults-key round-trip matches the resolution rules")
    func textureCacheBudgetDefaultsRoundTrip() {
        let defaults = UserDefaults.standard
        let key = WPEMetalSceneRenderer.textureCacheBudgetMiBDefaultsKey
        let previous = defaults.object(forKey: key)
        defer {
            if let previous { defaults.set(previous, forKey: key) } else { defaults.removeObject(forKey: key) }
        }

        defaults.removeObject(forKey: key)
        #expect(WPEMetalSceneRenderer.textureCacheBudgetBytes
            == WPEMemoryTier.current.defaultTextureCacheBudgetBytes)
        defaults.set(0, forKey: key)
        #expect(WPEMetalSceneRenderer.textureCacheBudgetBytes == nil)
        defaults.set(64, forKey: key)
        #expect(WPEMetalSceneRenderer.textureCacheBudgetBytes == 64 * 1_048_576)
    }

    @Test("Reload throttle backs off exponentially and gives up at the cap")
    func reloadThrottleBackoff() {
        var throttle = WPEStaticTextureReloadThrottle()
        #expect(throttle.allowsAttempt(at: 0))

        throttle.recordFailure(at: 100)
        #expect(!throttle.allowsAttempt(at: 100.5))
        #expect(throttle.allowsAttempt(at: 101))
        throttle.recordFailure(at: 101)
        #expect(!throttle.allowsAttempt(at: 102.5))
        #expect(throttle.allowsAttempt(at: 103))
        throttle.recordFailure(at: 103)
        #expect(throttle.allowsAttempt(at: 107))
        throttle.recordFailure(at: 107)
        #expect(throttle.allowsAttempt(at: 115))
        #expect(!throttle.isExhausted)

        throttle.recordFailure(at: 115)
        #expect(throttle.isExhausted)
        #expect(!throttle.allowsAttempt(at: 10_000))
        #expect(throttle.failureCount == WPEStaticTextureReloadThrottle.maxAttempts)
    }

    @Test("Resident-byte estimate covers the mip chain when one exists")
    func residentBytesCountMipChain() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        func makeTexture(mipmapped: Bool) throws -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm,
                width: 64,
                height: 64,
                mipmapped: mipmapped
            )
            descriptor.usage = [.shaderRead]
            return try #require(device.makeTexture(descriptor: descriptor))
        }
        let flat = try makeTexture(mipmapped: false)
        let mipped = try makeTexture(mipmapped: true)
        let base = 64 * 64 * 4
        // Exact per-level sum for the 7-level chain, not the old x4/3 shortcut.
        let mipChain = (64 * 64 + 32 * 32 + 16 * 16 + 8 * 8 + 4 * 4 + 2 * 2 + 1) * 4
        #expect(WPEMetalSceneRenderer.textureResidentBytes(for: flat) == base)
        #expect(WPEMetalSceneRenderer.textureResidentBytes(for: mipped) == mipChain)
    }

    @Test("LRU evicts least-recently-used inactive entries")
    func lruEvictsOldestInactive() {
        var lru = WPEMetalTextureCacheLRU(budgetBytes: 100)
        lru.admit("a", bytes: 40)
        lru.admit("b", bytes: 40)
        lru.touch("a")
        lru.admit("c", bytes: 40)

        let evicted = lru.evictOverBudget(protecting: [])

        #expect(evicted == ["b"])
        #expect(lru.entries["a"] != nil)
        #expect(lru.entries["b"] == nil)
        #expect(lru.entries["c"] != nil)
        #expect(lru.totalBytes == 80)
    }

    @Test("LRU never evicts protected active paths")
    func lruProtectsActivePaths() {
        var lru = WPEMetalTextureCacheLRU(budgetBytes: 100)
        lru.admit("hidden-old", bytes: 60)
        lru.admit("visible-new", bytes: 60)

        let evicted = lru.evictOverBudget(protecting: ["visible-new"])

        #expect(evicted == ["hidden-old"])
        #expect(lru.entries["visible-new"] != nil)
        #expect(lru.totalBytes == 60)
    }

    @Test("LRU stays over budget rather than evict an active entry")
    func lruKeepsAllProtected() {
        var lru = WPEMetalTextureCacheLRU(budgetBytes: 50)
        lru.admit("visible", bytes: 80)

        let evicted = lru.evictOverBudget(protecting: ["visible"])

        #expect(evicted.isEmpty)
        #expect(lru.entries["visible"] != nil)
        #expect(lru.totalBytes == 80)
    }
    @Test("Static snapshots reserve the whole layer before any allocation")
    func staticSnapshotReservationIncludesPendingWork() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let producer = try #require(queue.makeCommandBuffer())
        let other = try #require(queue.makeCommandBuffer())
        let cache = WPEMetalStaticLayerCompositeCache(budgetBytes: 100)
        #expect(cache.reserve(layerID: "a", targetBytes: ["first": 30, "second": 30], commandBuffer: producer))
        #expect(cache.accountedBytes == 60)
        #expect(cache.allocatedBytes == 0)
        #expect(!cache.reserve(layerID: "b", targetBytes: ["next": 50], commandBuffer: other))
        #expect(!cache.reserve(layerID: "oversized", targetBytes: ["first": 70, "second": 40], commandBuffer: other))
        #expect(!cache.reserve(layerID: "overflow", targetBytes: ["first": Int.max, "second": 1], commandBuffer: other))
        cache.discardUnsubmittedWork(for: producer)
        #expect(cache.accountedBytes == 0)
        #expect(cache.reserve(layerID: "b", targetBytes: ["next": 50], commandBuffer: other))
        cache.discardUnsubmittedWork(for: other)
    }

    @Test("Static cache only publishes complete successful GPU work")
    func staticSnapshotPublicationRequiresSuccess() {
        let incompleteStatuses: [MTLCommandBufferStatus] = [.notEnqueued, .enqueued, .committed, .scheduled, .error]
        for status in incompleteStatuses {
            #expect(!WPEMetalStaticLayerCompositeCache.mayPublish(producerStatus: status, hasEveryTarget: true))
        }
        #expect(!WPEMetalStaticLayerCompositeCache.mayPublish(producerStatus: .completed, hasEveryTarget: false))
        #expect(WPEMetalStaticLayerCompositeCache.mayPublish(producerStatus: .completed, hasEveryTarget: true))
    }

    @Test("Invalidation retains reader resources and budget until GPU use ends")
    func staticSnapshotInvalidationPreservesInFlightBudget() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let producer = try #require(queue.makeCommandBuffer())
        let reader = try #require(queue.makeCommandBuffer())
        let next = try #require(queue.makeCommandBuffer())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: 16, height: 16, mipmapped: false
        )
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead]
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        let bytes = max(1, texture.allocatedSize)
        let cache = WPEMetalStaticLayerCompositeCache(budgetBytes: bytes)
        cache.setOutputFormat(.rgba16Float)
        #expect(cache.reserve(layerID: "a", targetBytes: ["target": bytes], commandBuffer: producer))
        #expect(cache.recordSnapshot(texture, target: "target", layerID: "a", commandBuffer: producer))
        #expect(cache.cachedLayer(for: "a", requiredTargets: ["target"], commandBuffer: reader) == nil)
        producer.commit()
        producer.waitUntilCompleted()
        #expect(producer.status == .completed)
        #expect(cache.cachedLayer(for: "a", requiredTargets: ["target"], commandBuffer: reader) != nil)
        cache.setOutputFormat(.bgra8Unorm)
        #expect(cache.cachedLayer(for: "a", requiredTargets: ["target"], commandBuffer: next) == nil)
        #expect(cache.accountedBytes == bytes)
        #expect(cache.allocatedBytes == texture.allocatedSize)
        #expect(!cache.reserve(layerID: "b", targetBytes: ["target": bytes], commandBuffer: next))
        reader.commit()
        reader.waitUntilCompleted()
        #expect(reader.status == .completed)
        #expect(cache.reserve(layerID: "b", targetBytes: ["target": bytes], commandBuffer: next))
        #expect(cache.accountedBytes == bytes)
        cache.discardUnsubmittedWork(for: next)
        #expect(cache.accountedBytes == 0)
    }

    @Test("Abandoned and partially produced layers release reservations without publishing")
    func staticSnapshotIncompleteAndCancelledWork() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let producer = try #require(queue.makeCommandBuffer())
        let reader = try #require(queue.makeCommandBuffer())
        let cache = WPEMetalStaticLayerCompositeCache(budgetBytes: 100)
        #expect(cache.reserve(layerID: "partial", targetBytes: ["a": 30, "b": 30], commandBuffer: producer))
        cache.abandon(layerID: "partial", commandBuffer: producer)
        // No allocation was made: unused reservation is released immediately.
        #expect(cache.accountedBytes == 0)
        cache.updateBudget(10)
        cache.discardUnsubmittedWork(for: producer)
        #expect(cache.accountedBytes == 0)
        #expect(cache.reserve(layerID: "incomplete", targetBytes: ["a": 10], commandBuffer: reader))
        reader.commit()
        reader.waitUntilCompleted()
        #expect(reader.status == .completed)
        cache.updateBudget(10)
        #expect(cache.accountedBytes == 0)
        let next = try #require(queue.makeCommandBuffer())
        #expect(cache.cachedLayer(for: "incomplete", requiredTargets: ["a"], commandBuffer: next) == nil)
    }

    @Test("Unexpected allocation size never enters a cache copy or publication")
    func staticSnapshotRejectsUnderestimatedAllocation() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let producer = try #require(queue.makeCommandBuffer())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: 64, height: 64, mipmapped: false
        )
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead]
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        #expect(texture.allocatedSize > 1)
        let cache = WPEMetalStaticLayerCompositeCache(budgetBytes: 1)
        #expect(cache.reserve(layerID: "a", targetBytes: ["target": 1], commandBuffer: producer))
        #expect(!cache.recordSnapshot(texture, target: "target", layerID: "a", commandBuffer: producer))
        #expect(cache.allocatedBytes == 0)
        cache.abandon(layerID: "a", commandBuffer: producer)
        #expect(cache.accountedBytes == 0)
        cache.discardUnsubmittedWork(for: producer)
    }

    private func retirementTexture(_ device: MTLDevice) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: 16, height: 16, mipmapped: false
        )
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead]
        return try #require(device.makeTexture(descriptor: descriptor))
    }

    /// Observe actual texture lifetime without calling any cache method that could
    /// reap retired entries. Metal status can become completed before callbacks run.
    private func expectTextureReleased(_ texture: () -> MTLTexture?) {
        let deadline = Date().addingTimeInterval(2)
        while texture() != nil, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.001)
        }
        #expect(texture() == nil)
    }

    @Test("An invalidated producer releases its texture after completion without another frame")
    func retiredProducerReleasesWithoutOwnerReaping() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let producer = try #require(queue.makeCommandBuffer())
        let cache = WPEMetalStaticLayerCompositeCache(budgetBytes: 1_048_576)
        weak var observedTexture: MTLTexture?
        try autoreleasepool {
            let texture = try retirementTexture(device)
            observedTexture = texture
            #expect(cache.reserve(layerID: "a", targetBytes: ["target": texture.allocatedSize], commandBuffer: producer))
            #expect(cache.recordSnapshot(texture, target: "target", layerID: "a", commandBuffer: producer))
            cache.removeAll()
        }
        #expect(observedTexture != nil)
        producer.commit()
        producer.waitUntilCompleted()
        #expect(producer.status == .completed)
        expectTextureReleased { observedTexture }
        // This getter does not reap. Budget may remain conservative until the
        // next owner operation, but the GPU allocation must already be gone.
        #expect(cache.allocatedBytes == 0)
    }

    @Test("Retired cache textures survive the first reader and release after the last reader")
    func retiredReadersReleaseWithoutOwnerReaping() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let producer = try #require(queue.makeCommandBuffer())
        let first = try #require(queue.makeCommandBuffer())
        let last = try #require(queue.makeCommandBuffer())
        let cache = WPEMetalStaticLayerCompositeCache(budgetBytes: 1_048_576)
        weak var observedTexture: MTLTexture?
        try autoreleasepool {
            let texture = try retirementTexture(device)
            observedTexture = texture
            #expect(cache.reserve(layerID: "a", targetBytes: ["target": texture.allocatedSize], commandBuffer: producer))
            #expect(cache.recordSnapshot(texture, target: "target", layerID: "a", commandBuffer: producer))
            producer.commit()
            producer.waitUntilCompleted()
            #expect(producer.status == .completed)
            #expect(cache.cachedLayer(for: "a", requiredTargets: ["target"], commandBuffer: first) != nil)
            #expect(cache.cachedLayer(for: "a", requiredTargets: ["target"], commandBuffer: last) != nil)
            cache.removeAll()
        }
        first.commit()
        first.waitUntilCompleted()
        #expect(first.status == .completed)
        #expect(observedTexture != nil)
        last.commit()
        last.waitUntilCompleted()
        #expect(last.status == .completed)
        expectTextureReleased { observedTexture }
        #expect(cache.allocatedBytes == 0)
    }

    @Test("Cancelling an unsubmitted retired reader does not release another reader's texture")
    func retiredReaderCancellationAndCompletionAreIndependent() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let producer = try #require(queue.makeCommandBuffer())
        let submitted = try #require(queue.makeCommandBuffer())
        let cancelled = try #require(queue.makeCommandBuffer())
        let cache = WPEMetalStaticLayerCompositeCache(budgetBytes: 1_048_576)
        weak var observedTexture: MTLTexture?
        try autoreleasepool {
            let texture = try retirementTexture(device)
            observedTexture = texture
            #expect(cache.reserve(layerID: "a", targetBytes: ["target": texture.allocatedSize], commandBuffer: producer))
            #expect(cache.recordSnapshot(texture, target: "target", layerID: "a", commandBuffer: producer))
            producer.commit()
            producer.waitUntilCompleted()
            #expect(producer.status == .completed)
            #expect(cache.cachedLayer(for: "a", requiredTargets: ["target"], commandBuffer: submitted) != nil)
            #expect(cache.cachedLayer(for: "a", requiredTargets: ["target"], commandBuffer: cancelled) != nil)
            cache.removeAll()
        }
        cache.discardUnsubmittedWork(for: cancelled)
        cache.discardUnsubmittedWork(for: cancelled)
        #expect(observedTexture != nil)
        submitted.commit()
        submitted.waitUntilCompleted()
        #expect(submitted.status == .completed)
        expectTextureReleased { observedTexture }
        #expect(cache.allocatedBytes == 0)
    }

    @Test("Partial allocation failure frees unused reservation but retains encoded resources")
    func staticSnapshotPartialAllocationRetainsOnlyAllocatedTargets() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let producer = try #require(queue.makeCommandBuffer())
        let next = try #require(queue.makeCommandBuffer())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 16, height: 16, mipmapped: false
        )
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead]
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        let bytes = max(1, texture.allocatedSize)
        let cache = WPEMetalStaticLayerCompositeCache(budgetBytes: bytes * 2)
        #expect(cache.reserve(layerID: "partial", targetBytes: ["a": bytes, "b": bytes], commandBuffer: producer))
        #expect(cache.recordSnapshot(texture, target: "a", layerID: "partial", commandBuffer: producer))
        cache.abandon(layerID: "partial", commandBuffer: producer)
        #expect(cache.accountedBytes == bytes)
        #expect(cache.allocatedBytes == texture.allocatedSize)
        #expect(!cache.reserve(layerID: "next", targetBytes: ["a": bytes * 2], commandBuffer: next))
        cache.updateBudget(0)
        #expect(cache.accountedBytes == bytes)
        cache.discardUnsubmittedWork(for: producer)
        #expect(cache.accountedBytes == 0)
        #expect(cache.allocatedBytes == 0)
    }
}
#endif
