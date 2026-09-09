#if !LITE_BUILD
import CoreGraphics
import Foundation
import LiveWallpaperProWPE
import Metal

/// Plan describing how a static layer's composites are cached: every named
/// target the layer produces (FBO/layerComposite) mapped to the index of its
/// last producer pass. ALL of them are cached + re-seeded, because skipping the
/// layer's compose/effect passes means a downstream consumer of ANY of them
/// (not just the final one) must still resolve to frame-invariant pixels.
struct WPEMetalStaticLayerCachePlan: Equatable, Sendable {
    let cachedTargets: [String: Int]
    let targetTypes: [String: WPERenderTarget]
    let compositePassCount: Int
}

/// Decides whether a layer's composites are provably frame-invariant so they can be
/// rendered once and reused. Exact by construction only for a pure function of static
/// inputs, so this is deliberately ULTRA-conservative: anything unprovable falls back
/// to the normal per-frame path (slower, never wrong).
///
/// A layer qualifies only when EVERY pass: uses a BUILTIN shader (a custom material
/// shader could sample g_Time/g_Pointer/g_AudioSpectrum/g_ModelMatrix even outside
/// effects/); is not an effects/ or workshop/ animated shader; carries no animated
/// authored constant; reads only frame-invariant textures (a non-dynamic image/asset,
/// or an FBO this layer already produced — never `.previous` feedback, never a
/// scene-alias FBO like `_rt_FullFrameBuffer`). The layer itself must also have no
/// puppet, no `animationLayers`, no animated alpha/color on any geometry (base,
/// local, group-local), exactly one `.scene` pass, and ≥2 composite passes (the cost
/// gate).
enum WPEMetalStaticLayerClassifier {
    static func cachePlan(
        for layer: WPEPreparedRenderLayer,
        dynamicTextureNames: Set<String>,
        dynamicLayerIDs: Set<String> = []
    ) -> WPEMetalStaticLayerCachePlan? {
        guard !dynamicLayerIDs.contains(layer.graphLayer.objectID) else { return nil }
        guard layer.puppetModel == nil,
              layer.graphLayer.animationLayers.isEmpty,
              layer.graphLayer.geometry.alphaAnimation == nil,
              layer.graphLayer.geometry.colorAnimation == nil,
              layer.graphLayer.localGeometry?.alphaAnimation == nil,
              layer.graphLayer.localGeometry?.colorAnimation == nil,
              layer.graphLayer.groupLocalGeometry?.alphaAnimation == nil,
              layer.graphLayer.groupLocalGeometry?.colorAnimation == nil,
              !layer.passes.isEmpty else { return nil }

        var produced: Set<String> = []
        var lastProducer: [String: Int] = [:]
        var targetTypes: [String: WPERenderTarget] = [:]
        var compositePassCount = 0
        var scenePassCount = 0

        for (index, pass) in layer.passes.enumerated() {
            guard let program = pass.shader,
                  program.isBuiltin,
                      // A script-gated pass turns on and off at runtime, so the layer's
                      // composite is not frame-invariant even when every input is.
                      pass.pass.visibilityGate == nil,
                  !usesAnimatedShader(pass),
                  !hasAnimatedConstant(pass) else { return nil }

            for reference in pass.textureReferences {
                switch reference {
                case .previous:
                    return nil
                case .image(let name), .asset(let name):
                    if dynamicTextureNames.contains(name) { return nil }
                case .fbo(let name):
                    if WPETextureReference.isSceneAliasName(name) { return nil }
                    // An FBO this layer hasn't produced yet is another (possibly
                    // dynamic) layer's output → not invariant from here.
                    if !produced.contains(name) { return nil }
                }
            }

            switch pass.pass.target {
            case .scene:
                scenePassCount += 1
            case .layerComposite(let name), .fbo(let name):
                compositePassCount += 1
                produced.insert(name)
                lastProducer[name] = index
                targetTypes[name] = pass.pass.target
            }
        }

        guard scenePassCount == 1,
              compositePassCount >= 2,
              !lastProducer.isEmpty else { return nil }
        return WPEMetalStaticLayerCachePlan(
            cachedTargets: lastProducer,
            targetTypes: targetTypes,
            compositePassCount: compositePassCount
        )
    }

    static func usesAnimatedShader(_ pass: WPEPreparedRenderPass) -> Bool {
        let shader = pass.pass.shader.lowercased()
        return shader.contains("effects/") || shader.contains("workshop/")
    }

    /// An authored `.animated` constant evaluates per frame, so its composite is
    /// not invariant. (Runtime uniforms like g_Time are merged into every pass
    /// but unused by builtin static shaders; authored constants are the signal.)
    private static func hasAnimatedConstant(_ pass: WPEPreparedRenderPass) -> Bool {
        pass.pass.constants.values.contains { value in
            if case .animated = value { return true }
            return false
        }
    }
}

/// LRU bookkeeping for the cache's VRAM budget, separated from the texture
/// store. Eviction policy: reject an oversized single entry outright, else
/// admit and evict inline (unprotected — a static-layer composite has no
/// "active this frame" exemption, unlike `WPEMetalTextureCacheLRU`).
/// Bookkeeping itself lives in the shared `WPEMetalLRUByteBudget` core.
struct WPEMetalStaticLayerCacheLRU: Equatable, Sendable {
    private var core: WPEMetalLRUByteBudget<String>

    var budgetBytes: Int { core.budgetBytes }
    var totalBytes: Int { core.totalBytes }
    var entries: [String: WPEMetalLRUByteBudget<String>.Entry] { core.entries }

    init(budgetBytes: Int) {
        core = WPEMetalLRUByteBudget(budgetBytes: budgetBytes)
    }

    mutating func touch(_ key: String) {
        core.touch(key)
    }

    @discardableResult
    mutating func admit(_ key: String, bytes: Int) -> [String] {
        guard bytes > 0, bytes <= core.budgetBytes else {
            core.remove(key)
            return []
        }
        core.record(key, bytes: bytes)
        return core.evictOverBudget(protecting: [])
    }

    mutating func removeAll() {
        core.removeAll()
    }
}

/// Completion callbacks only mutate this lease; the cache dictionaries remain
/// render-owner-only. Retired textures are freed even if rendering never resumes.
private final class WPEMetalStaticCacheCompletionLease: @unchecked Sendable { // NSLock protects every field shared with Metal completion callbacks.
    private let lock = NSLock()
    private var pendingBuffers: Set<ObjectIdentifier> = []
    private var retiredTextures: [MTLTexture] = []

    var isComplete: Bool {
        lock.withLock { pendingBuffers.isEmpty }
    }

    var allocatedBytes: Int {
        lock.withLock { retiredTextures.reduce(0) { $0 + $1.allocatedSize } }
    }

    /// Called by the render owner before commit. No command buffer is retained
    /// here: keeping a completed buffer can also keep its encoded resources alive.
    func track(_ commandBuffer: MTLCommandBuffer) -> Bool {
        guard commandBuffer.status == .notEnqueued || commandBuffer.status == .enqueued else { return false }
        let id = ObjectIdentifier(commandBuffer)
        let inserted = lock.withLock { pendingBuffers.insert(id).inserted }
        if inserted {
            commandBuffer.addCompletedHandler { @Sendable [self] _ in finish(id) }
        }
        return true
    }

    func retire(textures: [MTLTexture]) {
        lock.withLock {
            if !pendingBuffers.isEmpty {
                retiredTextures = textures
            }
        }
    }

    /// Cancellation is only issued by the owner for a buffer it will not commit.
    func cancel(_ commandBuffer: MTLCommandBuffer) {
        finish(ObjectIdentifier(commandBuffer))
    }

    private func finish(_ id: ObjectIdentifier) {
        let released: [MTLTexture] = lock.withLock {
            pendingBuffers.remove(id)
            guard pendingBuffers.isEmpty else { return [] }
            let textures = retiredTextures
            retiredTextures = []
            return textures
        }
        // Release Metal objects after unlocking; their deinitializers do not run
        // while the lease's synchronization primitive is held.
        withExtendedLifetime(released) {}
    }
}

/// Render-thread owned. Reservations include pending producers and invalidated
/// entries still referenced by GPU work; LRU residency alone is not a peak budget.
final class WPEMetalStaticLayerCompositeCache {
    struct CachedLayer {
        var texturesByTarget: [String: MTLTexture]
        let bytes: Int
    }

    private struct Entry {
        var targetBytes: [String: Int]
        var producer: MTLCommandBuffer?
        var textures: [String: MTLTexture] = [:]
        var readers: [MTLCommandBuffer] = []
        let completionLease = WPEMetalStaticCacheCompletionLease()
        var bytes: Int {
            targetBytes.values.reduce(0, +)
        }

        var producerStatus: MTLCommandBufferStatus {
            producer?.status ?? .completed
        }

        var inFlight: Bool {
            producer.map { !Self.finished($0) } == true || readers.contains { !Self.finished($0) }
        }

        mutating func releaseFinishedBuffers() {
            if let producer, Self.finished(producer) {
                self.producer = nil
            }
            readers.removeAll { Self.finished($0) }
        }

        static func finished(_ buffer: MTLCommandBuffer) -> Bool {
            buffer.status == .completed || buffer.status == .error
        }
    }

    private struct RetiredEntry {
        let bytes: Int
        let completionLease: WPEMetalStaticCacheCompletionLease
    }

    private var outputFormat: MTLPixelFormat?
    private var entries: [String: Entry] = [:]
    private var retired: [RetiredEntry] = []
    private var lru: WPEMetalLRUByteBudget<String>
    var accountedBytes: Int {
        lru.totalBytes + retired.reduce(0) { $0 + $1.bytes }
    }

    var allocatedBytes: Int {
        entries.values.reduce(0) { total, entry in
            total + entry.textures.values.reduce(0) { $0 + $1.allocatedSize }
        } + retired.reduce(0) { $0 + $1.completionLease.allocatedBytes }
    }

    init(budgetBytes: Int) {
        lru = WPEMetalLRUByteBudget(budgetBytes: budgetBytes)
    }

    func updateBudget(_ budgetBytes: Int) {
        reapCompletedWork()
        guard lru.budgetBytes != max(0, budgetBytes) else { return }
        removeAll()
        lru = WPEMetalLRUByteBudget(budgetBytes: budgetBytes)
    }

    func setOutputFormat(_ format: MTLPixelFormat) {
        guard outputFormat != format else { return }
        removeAll()
        outputFormat = format
    }

    static func mayPublish(producerStatus: MTLCommandBufferStatus, hasEveryTarget: Bool) -> Bool {
        producerStatus == .completed && hasEveryTarget
    }

    func cachedLayer(
        for layerID: String, requiredTargets: Set<String>, commandBuffer: MTLCommandBuffer
    ) -> CachedLayer? {
        reapCompletedWork()
        guard var entry = entries[layerID],
              Self.mayPublish(producerStatus: entry.producerStatus,
                              hasEveryTarget: requiredTargets == Set(entry.textures.keys)) else { return nil }
        entry.readers.removeAll { Entry.finished($0) }
        if !entry.readers.contains(where: { $0 === commandBuffer }) {
            guard entry.completionLease.track(commandBuffer) else { return nil }
            entry.readers.append(commandBuffer)
        }
        entries[layerID] = entry
        lru.touch(layerID)
        return CachedLayer(texturesByTarget: entry.textures, bytes: entry.bytes)
    }

    /// Reserve the entire planned layer before making its first snapshot.
    /// Eviction only recovers bytes after every producer/reader has finished.
    func reserve(layerID: String, targetBytes: [String: Int], commandBuffer: MTLCommandBuffer) -> Bool {
        reapCompletedWork()
        if let entry = entries[layerID] {
            return entry.producer === commandBuffer
        }
        var bytes = 0
        for amount in targetBytes.values {
            guard amount > 0, amount <= lru.budgetBytes - bytes else { return false }
            bytes += amount
        }
        guard bytes > 0 else { return false }
        while bytes > lru.budgetBytes - accountedBytes {
            let protected = Set(entries.compactMap { $0.value.inFlight ? $0.key : nil })
            guard let victim = lru.lruVictim(protecting: protected) else { return false }
            entries.removeValue(forKey: victim)
            lru.remove(victim)
        }
        let entry = Entry(targetBytes: targetBytes, producer: commandBuffer)
        guard entry.completionLease.track(commandBuffer) else { return false }
        entries[layerID] = entry
        lru.record(layerID, bytes: bytes)
        return true
    }

    /// Called before encoding the copy. An unexpected allocation larger than the
    /// preflight estimate is rejected immediately, never added to GPU work.
    func recordSnapshot(_ texture: MTLTexture, target: String, layerID: String,
                        commandBuffer: MTLCommandBuffer) -> Bool {
        guard var entry = entries[layerID], entry.producer === commandBuffer,
              let reserved = entry.targetBytes[target], texture.allocatedSize <= reserved else { return false }
        entry.textures[target] = texture
        entries[layerID] = entry
        return true
    }

    func abandon(layerID: String, commandBuffer: MTLCommandBuffer) {
        guard let entry = entries[layerID], entry.producer === commandBuffer else { return }
        entries.removeValue(forKey: layerID)
        lru.remove(layerID)
        retire(entry)
    }

    /// A render that throws before commit has no future GPU completion. Its
    /// reservation and reader leases must be cancelled at the render boundary.
    func discardUnsubmittedWork(for commandBuffer: MTLCommandBuffer) {
        guard commandBuffer.status == .notEnqueued || commandBuffer.status == .enqueued else { return }
        for key in Array(entries.keys) {
            entries[key]?.completionLease.cancel(commandBuffer)
            if entries[key]?.producer === commandBuffer {
                entries.removeValue(forKey: key)
                lru.remove(key)
            } else {
                entries[key]?.readers.removeAll { $0 === commandBuffer }
            }
        }
        for entry in retired {
            entry.completionLease.cancel(commandBuffer)
        }
        reapCompletedWork()
    }

    func removeAll() {
        for entry in entries.values {
            retire(entry)
        }
        entries.removeAll(keepingCapacity: false)
        lru.removeAll()
        reapCompletedWork()
    }

    private func retire(_ entry: Entry) {
        guard !entry.textures.isEmpty else { return }
        entry.completionLease.retire(textures: Array(entry.textures.values))
        guard !entry.completionLease.isComplete else { return }
        let bytes = entry.targetBytes.reduce(0) { total, item in
            total + (entry.textures[item.key] == nil ? 0 : item.value)
        }
        retired.append(RetiredEntry(bytes: bytes, completionLease: entry.completionLease))
    }

    private func reapCompletedWork() {
        retired.removeAll { $0.completionLease.isComplete }
        for key in Array(entries.keys) {
            guard var entry = entries[key] else { continue }
            let failed = entry.producerStatus == .error || entry.readers.contains { $0.status == .error }
            let incomplete = entry.producerStatus == .completed
                && entry.textures.count != entry.targetBytes.count
            if failed || incomplete {
                entries.removeValue(forKey: key)
                lru.remove(key)
                retire(entry)
            } else {
                entry.releaseFinishedBuffers()
                entries[key] = entry
            }
        }
    }
}
#endif
