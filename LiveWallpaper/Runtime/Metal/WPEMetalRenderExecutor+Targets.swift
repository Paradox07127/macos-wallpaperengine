#if !LITE_BUILD
import CoreGraphics
import Foundation
import LiveWallpaperCore
import LiveWallpaperProWPE
import Metal
import MetalKit
import os
import simd
extension WPEMetalRenderExecutor {
    /// Everything whose identity includes a PIXEL dimension. Split out because a
    /// mid-scene render-scale change invalidates exactly this set and nothing else: the
    /// pool, bootstrap and hazard caches are keyed by width/height, so new keys would
    /// strand the old allocations for the scene's life. Worse, `previousFrameHistory` is
    /// validated against the WORLD size — unchanged by a scale change — so its
    /// old-resolution textures would keep being served to `.previous` reads.
    /// Shader/pipeline caches are deliberately NOT dropped here: re-transpiling every
    /// pass is by far the biggest load cost, and a scale change does not invalidate any
    /// of it.
    func releaseRenderScaleDependentResources() {
        targetPool.releaseAll()
        releaseBloomLevels()
        previousFrameHistory = nil
        invalidateStaticLayerCache()
        // NOT `refractionBackground`: it re-allocates itself whenever the output
        // size changes, and it is on the reload-persistent list (AF-06).
        outputTexturePool.removeAll()
        recentOutputTextureIDs.removeAll()
        bootstrapPreviousTextureCache.removeAll()
        sceneReadHazardSnapshotCache.removeAll()
        metalFXUpscaler?.releaseCachedScaler()
    }

    func releaseTransientResources() {
        releaseRenderScaleDependentResources()
        resetShaderFrameTime()
        // Clip-role detection + activation diagnostics are keyed by objectID, which a reload can reuse
        // for a different puppet/material/animation, so drop them when the graph is rebuilt.
        puppetClipPairsCache.removeAll()
        loggedClipActivation.removeAll()
        loggedClipBail.removeAll()
        loggedComponentMapResolveFailures.removeAll()
        characterSheetWarnedReasonByObjectID.removeAll()
        puppetBoundScanDetailByObjectID.removeAll()
        puppetPaletteCacheByObjectID.removeAll()
        lastLoggedPuppetSkinningReason.removeAll()
        bonePaletteBufferPool.drain()
        puppetMeshBufferCache.removeAll()
        // Pass-id keyed; a reload can reuse an id for a different shader. The
        // content-keyed translatedShaderCache is safe to persist and is not cleared.
        compiledShaderResultByPassID.removeAll()
        untranslatableShaderReasonByPassID.removeAll()
        invalidateUniformKeyIndexes()
        invalidateUniformPlans()
        fboAliasIntervalScratch.removeAll(keepingCapacity: false)
        cachedFBOAliasTopology = nil
        invalidatePassPipelineStates()
        // Pass ids are reused across scenes; the dispatcher throttles the
        // unresolved-slot warning on this set, so a reload must forget it.
        loggedUnresolvedTextureSlots.removeAll()
    }

    /// Drops every cached static-layer composite. Called on scene reload /
    /// pipeline rebuild / sceneSize change so a new scene never reads stale pixels.
    func invalidateStaticLayerCache() {
        staticLayerCompositeCache.removeAll()
        staticLayerCacheSceneSize = nil
        loggedStaticLayerCacheHits.removeAll(keepingCapacity: false)
    }

    // MARK: - FBO memory diagnostic (read-only)

    /// Conservative `[firstPass, lastPass]` per pool-FBO key. Structure is
    /// cached in `FBOAliasTopology`; sizes re-derived every frame. Validated
    /// against the pipeline itself — a missed invalidation corrupts frames.
    func fboAliasIntervals(
        pipeline: WPEPreparedRenderPipeline,
        sceneSize: CGSize
    ) -> [WPEMetalRenderTargetPool.AliasInterval] {
        var topology = validatedFBOAliasTopology(for: pipeline)
        let inputs = FBOAliasTopology.IntervalInputs(
            sceneSize: sceneSize,
            pixelScale: targetPool.pixelScale,
            promotesLDRFormatsToHDR: targetPool.promotesLDRFormatsToHDR,
            sizingGeneration: topology.sizingGeneration
        )
        if let memo = topology.intervalMemo, memo.inputs == inputs {
            return memo.intervals
        }
        let intervals = fboAliasIntervals(topology: topology, pipeline: pipeline, sceneSize: sceneSize)
        topology.intervalMemo = FBOAliasTopology.IntervalMemo(inputs: inputs, intervals: intervals)
        topology.metrics.intervalRebuilds += 1
        cachedFBOAliasTopology = topology
        return intervals
    }

    /// The cached topology for `pipeline`, rebuilt (and `fboAliasTopologyRebuildCount`
    /// bumped) only when the graph itself changed. The counter IS the structural
    /// generation the pool's stable-frame early-out consumes as `pipelineIdentity`,
    /// so it must move on every real graph change and stand still on every
    /// animation / script / uniform frame.
    func validatedFBOAliasTopology(
        for pipeline: WPEPreparedRenderPipeline
    ) -> FBOAliasTopology {
        if var cached = cachedFBOAliasTopology {
            // Same array storage ⇒ same graph, no walk at all.
            if cached.holdsSameLayerStorage(as: pipeline) { return cached }
            cached.metrics.structuralScans += 1
            let survived = cached.matches(pipeline)
            if survived {
                // Structure survived, but this is a freshly built array (an
                // animation/script frame). Adopt it so the NEXT frame that
                // re-presents the same value takes the O(1) path, and re-derive
                // the sizing snapshot the interval memo keys on.
                cached.adopt(layers: pipeline.layers)
            }
            cachedFBOAliasTopology = cached
            if survived { return cached }
        }
        var topology = computeFBOAliasTopology(pipeline: pipeline)
        // Counters and the sizing generation are monotonic across rebuilds: a
        // reset would let a stale interval memo look current after a rebuild.
        topology.carryForward(cachedFBOAliasTopology)
        cachedFBOAliasTopology = topology
        fboAliasTopologyRebuildCount += 1
        return topology
    }

    /// Name/index-level half of the alias-interval scan. Reloads drop it.
    struct FBOAliasTopology {
        struct Item {
            let layerIndex: Int
            let target: WPERenderTarget
            /// nil for `.scene`, which never gets a pool key.
            let spec: WPERenderFBO?
            let readFBONames: [String]
            /// Own-target ping-pong: two textures, stays on the discrete path.
            let marksSecondary: Bool
            let requiresDiscreteSource: Bool
        }

        struct PassSignature: Equatable {
            let id: String
            let target: WPERenderTarget
        }

        struct SignatureEntry: Equatable {
            let objectID: String
            let imagePath: String
            let passes: [PassSignature]
        }

        /// Everything `WPEMetalRenderTargetPool.keyDimensions` reads off a live
        /// layer. Alpha/color/origin never reach a pool key, so an animated tint
        /// or a moved (but unscaled) layer must not invalidate the interval memo.
        struct SizingGeometry: Equatable {
            let size: CGSize?
            let scale: SIMD3<Double>
            let angles: SIMD3<Double>

            init(_ geometry: WPERenderLayerGeometry) {
                size = geometry.size
                scale = geometry.scale
                angles = geometry.angles
            }
        }

        /// Everything outside the topology that can move a pool key. `pixelScale`
        /// and the HDR promotion are pool state the executor sets per frame;
        /// `sizingGeneration` stands in for the per-layer geometry snapshot.
        struct IntervalInputs: Equatable {
            let sceneSize: CGSize
            let pixelScale: Double
            let promotesLDRFormatsToHDR: Bool
            let sizingGeneration: Int
        }

        struct IntervalMemo {
            let inputs: IntervalInputs
            let intervals: [WPEMetalRenderTargetPool.AliasInterval]
        }

        /// Test seams: how often each cached stage ran its body. Carried across
        /// rebuilds so a test can count over a whole scene's life.
        struct Metrics: Equatable {
            var structuralScans = 0
            var intervalRebuilds = 0
            var depthRebuilds = 0
        }

        let items: [Item]
        let itemIndicesByKeyName: [String: [Int]]
        let signature: [SignatureEntry]
        /// Layers that own at least one pooled target, so their geometry can move
        /// a key. Deliberately not narrowed further (e.g. by `spec.pixelSize`):
        /// under-listing a layer here silently serves stale intervals, which is
        /// the one failure mode that aliases two live FBOs together.
        let sizingLayerIndices: [Int]

        /// The exact array this topology was built or validated against, RETAINED.
        /// Retention is what makes `holdsSameLayerStorage` sound: while we hold
        /// the buffer, no later array can be allocated at the same address, so
        /// equal base addresses mean the same buffer rather than a recycled one.
        private(set) var validatedLayers: [WPEPreparedRenderLayer]
        private(set) var sizingGeometry: [SizingGeometry]
        /// Bumped whenever `sizingGeometry` actually changes value, so the
        /// interval memo compares one Int instead of walking the snapshot.
        private(set) var sizingGeneration = 0
        var intervalMemo: IntervalMemo?
        /// Purely structural (`depthWrite`/`depthTest` on the authored pass), so
        /// it needs no input beyond the topology itself.
        var persistentDepthTargetIDs: Set<WPEMetalTargetID>?
        var metrics = Metrics()

        init(
            items: [Item],
            itemIndicesByKeyName: [String: [Int]],
            signature: [SignatureEntry],
            sizingLayerIndices: [Int],
            layers: [WPEPreparedRenderLayer]
        ) {
            self.items = items
            self.itemIndicesByKeyName = itemIndicesByKeyName
            self.signature = signature
            self.sizingLayerIndices = sizingLayerIndices
            validatedLayers = layers
            sizingGeometry = sizingLayerIndices.map {
                SizingGeometry(layers[$0].graphLayer.geometry)
            }
        }

        /// O(1) and exact — see `validatedLayers`. Two empty arrays compare equal
        /// (both have no layers, so the empty topology is valid for both).
        func holdsSameLayerStorage(as pipeline: WPEPreparedRenderPipeline) -> Bool {
            guard validatedLayers.count == pipeline.layers.count else { return false }
            return validatedLayers.withUnsafeBufferPointer { mine in
                pipeline.layers.withUnsafeBufferPointer { theirs in
                    mine.baseAddress == theirs.baseAddress
                }
            }
        }

        /// Take over a structurally identical but freshly built layer array.
        mutating func adopt(layers: [WPEPreparedRenderLayer]) {
            validatedLayers = layers
            let geometry = sizingLayerIndices.map {
                SizingGeometry(layers[$0].graphLayer.geometry)
            }
            guard geometry != sizingGeometry else { return }
            sizingGeometry = geometry
            sizingGeneration += 1
        }

        /// Monotonic hand-off from the topology this one replaces.
        mutating func carryForward(_ previous: FBOAliasTopology?) {
            guard let previous else { return }
            metrics = previous.metrics
            sizingGeneration = previous.sizingGeneration + 1
        }

        /// Ordered (objectID, imagePath, pass id/target). Texture refs / localFBOs
        /// are load-invariant; a reload clears the cache.
        func matches(_ pipeline: WPEPreparedRenderPipeline) -> Bool {
            guard signature.count == pipeline.layers.count else { return false }
            for (index, layer) in pipeline.layers.enumerated() {
                let entry = signature[index]
                if entry.objectID != layer.graphLayer.objectID
                    || entry.imagePath != layer.graphLayer.imagePath
                    || entry.passes.count != layer.passes.count {
                    return false
                }
                for (passIndex, pass) in layer.passes.enumerated() {
                    let passEntry = entry.passes[passIndex]
                    if passEntry.id != pass.pass.id || passEntry.target != pass.pass.target {
                        return false
                    }
                }
            }
            return true
        }
    }

    func computeFBOAliasTopology(pipeline: WPEPreparedRenderPipeline) -> FBOAliasTopology {
        var declaredFBOs: [String: WPERenderFBO] = [:]
        for layer in pipeline.layers {
            for fbo in layer.graphLayer.localFBOs {
                declaredFBOs[fbo.name] = fbo
            }
        }

        var items: [FBOAliasTopology.Item] = []
        var itemIndicesByKeyName: [String: [Int]] = [:]
        var writtenTargets: Set<WPEMetalTargetID> = []
        var signature: [FBOAliasTopology.SignatureEntry] = []
        signature.reserveCapacity(pipeline.layers.count)
        var sizingLayerIndices: [Int] = []

        for (layerIndex, layer) in pipeline.layers.enumerated() {
            signature.append(FBOAliasTopology.SignatureEntry(
                objectID: layer.graphLayer.objectID,
                imagePath: layer.graphLayer.imagePath,
                passes: layer.passes.map {
                    FBOAliasTopology.PassSignature(id: $0.pass.id, target: $0.pass.target)
                }
            ))
            for pass in layer.passes {
                let targetID = WPEMetalTargetID(target: pass.pass.target)
                let spec: WPERenderFBO?
                switch pass.pass.target {
                case .scene:
                    spec = nil
                case .fbo, .layerComposite:
                    spec = targetPool.diagnosticSpec(
                        for: pass.pass.target,
                        layer: layer.graphLayer,
                        declaredFBOs: declaredFBOs
                    )
                }
                var readFBONames: [String] = []
                for reference in textureReferences(for: pass) {
                    if case .fbo(let name) = reference { readFBONames.append(name) }
                }
                let index = items.count
                items.append(FBOAliasTopology.Item(
                    layerIndex: layerIndex,
                    target: pass.pass.target,
                    spec: spec,
                    readFBONames: readFBONames,
                    marksSecondary: spec != nil
                        && writtenTargets.contains(targetID)
                        && passReadsCurrentTarget(pass, targetID: targetID),
                    requiresDiscreteSource: Self.requiresDiscreteDestinationForSourceAliasing(pass)
                ))
                if let spec {
                    itemIndicesByKeyName[spec.name, default: []].append(index)
                    if sizingLayerIndices.last != layerIndex {
                        sizingLayerIndices.append(layerIndex)
                    }
                }
                writtenTargets.insert(targetID)
            }
        }

        return FBOAliasTopology(
            items: items,
            itemIndicesByKeyName: itemIndicesByKeyName,
            signature: signature,
            sizingLayerIndices: sizingLayerIndices,
            layers: pipeline.layers
        )
    }

    /// Per-frame size mapping onto a cached topology. `topology` must match `pipeline`.
    func fboAliasIntervals(
        topology: FBOAliasTopology,
        pipeline: WPEPreparedRenderPipeline,
        sceneSize: CGSize
    ) -> [WPEMetalRenderTargetPool.AliasInterval] {
        let scratch = fboAliasIntervalScratch
        scratch.removeAll(keepingCapacity: true)

        scratch.keys.reserveCapacity(topology.items.count)
        for item in topology.items {
            scratch.keys.append(item.spec.map { spec in
                targetPool.diagnosticKey(
                    for: item.target,
                    spec: spec,
                    layer: pipeline.layers[item.layerIndex].graphLayer,
                    sceneSize: sceneSize
                )
            })
        }

        func touch(_ key: WPEMetalRenderTargetKey, _ index: Int) {
            if scratch.firstPassByKey[key] == nil { scratch.firstPassByKey[key] = index }
            scratch.lastPassByKey[key] = max(scratch.lastPassByKey[key] ?? index, index)
        }

        for (index, item) in topology.items.enumerated() {
            if let key = scratch.keys[index] {
                touch(key, index)
                if item.marksSecondary { scratch.secondaryKeys.insert(key) }
            }
            for name in item.readFBONames {
                guard let indices = topology.itemIndicesByKeyName[name] else { continue }
                for namedIndex in indices {
                    guard let namedKey = scratch.keys[namedIndex] else { continue }
                    touch(namedKey, index)
                    if item.requiresDiscreteSource {
                        scratch.nonAliasKeys.insert(namedKey)
                    }
                }
            }
        }

        return scratch.firstPassByKey.compactMap { key, first in
            guard !scratch.secondaryKeys.contains(key),
                  !scratch.nonAliasKeys.contains(key),
                  let last = scratch.lastPassByKey[key] else { return nil }
            return WPEMetalRenderTargetPool.AliasInterval(key: key, firstPass: first, lastPass: last)
        }
    }

    /// Snapshots every composite whose last producer is `passIndex` into a persistent texture,
    /// redirects `frameState` so this frame already reads the snapshot (identical pixels), and
    /// — once all of the plan's targets are captured — commits them to the cache as one layer
    /// entry. If the layer's total exceeds the budget, partial snapshots are discarded and the layer keeps re-rendering (slower, never wrong).
    func captureStaticLayerSnapshots(
        at passIndex: Int,
        plan: WPEMetalStaticLayerCachePlan,
        layer: WPERenderLayer,
        commandBuffer: MTLCommandBuffer,
        frameState: inout WPEMetalFrameState,
        snapshots: inout [String: MTLTexture],
        bytes: inout Int
    ) {
        for (targetName, producerIndex) in plan.cachedTargets where producerIndex == passIndex {
            guard snapshots[targetName] == nil,
                  let source = frameState.latestNamedTextures[targetName] else { continue }
            do {
                let cached = try targetPool.persistentTexture(
                    matching: source,
                    label: "WPE static layer cache \(layer.objectID) \(targetName)"
                )
                try copyTexture(source, to: cached, commandBuffer: commandBuffer)
                frameState.seedPreviousTexture(cached, targetID: .named(targetName))
                frameState.markInitialized(cached)
                snapshots[targetName] = cached
                bytes += WPEMetalTextureByteEstimator.estimatedBytes(of: source)
            } catch {
                Logger.warning(
                    "[WPE.static-layer-cache] snapshot failed layer=\(layer.objectID) target=\(targetName): \(error)",
                    category: .wpeRender
                )
            }
        }

        // Commit only once every planned target is captured this frame.
        guard snapshots.count == plan.cachedTargets.count else { return }
        guard staticLayerCompositeCache.canAdmit(bytes: bytes) else {
            Logger.info(
                "[WPE.static-layer-cache] skip cache layer=\(layer.objectID) bytes=\(bytes) over budget",
                category: .wpeRender
            )
            return
        }
        let evicted = staticLayerCompositeCache.insert(
            layerID: layer.objectID,
            texturesByTarget: snapshots,
            bytes: bytes
        )
        Logger.info(
            "[WPE.static-layer-cache] cached layer=\(layer.objectID) targets=\(snapshots.count) passes=\(plan.compositePassCount) bytes=\(bytes)",
            category: .wpeRender
        )
        for layerID in evicted where layerID != layer.objectID {
            loggedStaticLayerCacheHits.remove(layerID)
            Logger.info("[WPE.static-layer-cache] evicted layer=\(layerID)", category: .wpeRender)
        }
    }

    /// Targets used by more than one depth pass (depth-write OR depth-test) — a later pass can
    /// `.load` an earlier pass's depth (e.g. `depthTest:less` across encoders), so their depth
    /// must stay persistent rather than transient/memoryless. Derived from the authored
    /// `depthWrite`/`depthTest` and the pass target only — no per-frame input — so it's memoized on the structural topology and recomputed exactly when the graph is rebuilt.
    func computePersistentDepthTargetIDs(
        for pipeline: WPEPreparedRenderPipeline
    ) -> Set<WPEMetalTargetID> {
        var topology = validatedFBOAliasTopology(for: pipeline)
        if let cached = topology.persistentDepthTargetIDs { return cached }
        let ids = persistentDepthTargetIDsScan(for: pipeline)
        topology.persistentDepthTargetIDs = ids
        topology.metrics.depthRebuilds += 1
        cachedFBOAliasTopology = topology
        return ids
    }

    private func persistentDepthTargetIDsScan(
        for pipeline: WPEPreparedRenderPipeline
    ) -> Set<WPEMetalTargetID> {
        var depthPassCounts: [WPEMetalTargetID: Int] = [:]
        for layer in pipeline.layers {
            for pass in layer.passes where depthCache.needsAttachment(for: pass) {
                depthPassCounts[WPEMetalTargetID(target: pass.pass.target), default: 0] += 1
            }
        }
        return Set(depthPassCounts.compactMap { $0.value > 1 ? $0.key : nil })
    }

    func makeOutputTexture(size: CGSize) throws -> MTLTexture {
        let width = max(Int(size.width), 1)
        let height = max(Int(size.height), 1)
        let pixelFormat = currentOutputPixelFormat
        outputTexturePool.removeAll {
            $0.width != width || $0.height != height || $0.pixelFormat != pixelFormat
        }
        if let recycled = outputTexturePool.first(where: isOutputTextureReusable) {
            noteVendedOutputTexture(recycled)
            return recycled
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        // `.private`: GPU-exclusive storage keeps lossless framebuffer
        // compression on Apple Silicon; `.shared` forced CPU-coherent,
        // uncompressed stores on the hot path. Every CPU read-back consumer
        // (snapshotter, visual stats, trace hashes, PNG dumps) blits into its
        // own CPU-visible staging instead of reading this texture directly.
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw WPEMetalTextureLoaderError.textureAllocationFailed
        }
        texture.label = "WPE Metal executor output"
        outputTexturePool.append(texture)
        // Steady state needs 3 (in-render + re-presented latest + history);
        // anything beyond that came from transient stalls — let ARC reap
        // the dropped one once its holders release it.
        if outputTexturePool.count > 4 {
            outputTexturePool.removeFirst()
        }
        noteVendedOutputTexture(texture)
        return texture
    }

    private func isOutputTextureReusable(_ texture: MTLTexture) -> Bool {
        let id = ObjectIdentifier(texture)
        if recentOutputTextureIDs.contains(id) {
            return false
        }
        if let history = previousFrameHistory?.sceneTexture, history === texture {
            return false
        }
        return !presentTracker.isInFlight(id)
    }

    private func noteVendedOutputTexture(_ texture: MTLTexture) {
        let id = ObjectIdentifier(texture)
        recentOutputTextureIDs.removeAll { $0 == id }
        recentOutputTextureIDs.append(id)
        // Keep the last `maxFramesInFlight` vended targets out of the reuse set:
        // under async submission their render may still be running, and the
        // in-flight semaphore guarantees it has finished by the time the target
        // ages out of this window. Keep at least 2 for the static-scene re-present
        // + `previousFrameHistory` reads even when only 1 frame is in flight.
        let retain = max(2, Self.maxFramesInFlight)
        if recentOutputTextureIDs.count > retain {
            recentOutputTextureIDs.removeFirst(recentOutputTextureIDs.count - retain)
        }
    }

    func targetTexture(
        for target: WPERenderTarget,
        layer: WPERenderLayer,
        frameState: inout WPEMetalFrameState,
        avoiding textureToAvoid: MTLTexture? = nil
    ) throws -> (id: WPEMetalTargetID, texture: MTLTexture) {
        let targetID = WPEMetalTargetID(target: target)
        switch target {
        case .scene:
            return (targetID, frameState.output)
        case .fbo, .layerComposite:
            let texture = try targetPool.texture(
                for: target,
                layer: layer,
                sceneSize: frameState.sceneSize,
                avoiding: textureToAvoid
            )
            return (targetID, texture)
        }
    }

    func previousTextureForRead(
        targetID: WPEMetalTargetID,
        matching destination: MTLTexture,
        commandBuffer: MTLCommandBuffer,
        frameState: inout WPEMetalFrameState
    ) throws -> MTLTexture {
        if let texture = frameState.latestTexture(for: targetID) {
            return texture
        }
        let texture = try makeClearedPreviousTexture(
            matching: destination,
            targetID: targetID,
            commandBuffer: commandBuffer
        )
        frameState.seedPreviousTexture(texture, targetID: targetID)
        frameState.markInitialized(texture)
        return texture
    }

    /// A stable snapshot of the live scene `output` for a pass that reads
    /// `.previous` while also writing the scene (see the read-write hazard note at
    /// the call site). Copies the scene-so-far into a cached scratch (one per
    /// size/format, reused every frame since it's re-copied before each read) so
    /// `.previous` binds to a frozen image instead of the texture being drawn.
    func sceneReadHazardSnapshot(
        matching source: MTLTexture,
        commandBuffer: MTLCommandBuffer
    ) throws -> MTLTexture {
        let key = BootstrapPreviousKey(
            targetID: .scene,
            width: source.width,
            height: source.height,
            pixelFormat: source.pixelFormat
        )
        let snapshot: MTLTexture
        if let cached = sceneReadHazardSnapshotCache[key] {
            snapshot = cached
        } else {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: source.pixelFormat,
                width: source.width,
                height: source.height,
                mipmapped: false
            )
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .private
            guard let made = device.makeTexture(descriptor: descriptor) else {
                throw WPEMetalTextureLoaderError.textureAllocationFailed
            }
            made.label = "WPE Metal scene .previous read snapshot"
            sceneReadHazardSnapshotCache[key] = made
            snapshot = made
        }
        try copyTexture(source, to: snapshot, commandBuffer: commandBuffer)
        return snapshot
    }

    private func makeClearedPreviousTexture(
        matching texture: MTLTexture,
        targetID: WPEMetalTargetID,
        commandBuffer: MTLCommandBuffer
    ) throws -> MTLTexture {
        // Bootstrap textures are read-only for their whole life (writes go to
        // the pool/output, never to the seeded `.previous` source), so one
        // cleared allocation per (target, size, format) serves every frame —
        // previously this allocated + cleared a scene-sized texture per frame.
        let key = BootstrapPreviousKey(
            targetID: targetID,
            width: texture.width,
            height: texture.height,
            pixelFormat: texture.pixelFormat
        )
        if let cached = bootstrapPreviousTextureCache[key] {
            return cached
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: texture.pixelFormat,
            width: texture.width,
            height: texture.height,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        guard let cleared = device.makeTexture(descriptor: descriptor) else {
            throw WPEMetalTextureLoaderError.textureAllocationFailed
        }
        cleared.label = "WPE Metal bootstrap previous"

        let renderPass = MTLRenderPassDescriptor()
        renderPass.colorAttachments[0].texture = cleared
        renderPass.colorAttachments[0].loadAction = .clear
        renderPass.colorAttachments[0].storeAction = .store
        renderPass.colorAttachments[0].clearColor = clearColor(for: targetID)
        gpuPassProfiler?.attach(renderPass, to: commandBuffer, label: "bootstrapClear")
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass) else {
            throw WPEMetalRenderExecutorError.commandBufferFailed
        }
        WPEFrameOccupancyMeter.count(.helperEncoder)
        encoder.endEncoding()
        bootstrapPreviousTextureCache[key] = cleared
        return cleared
    }

}
#endif
