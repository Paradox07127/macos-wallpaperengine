#if !LITE_BUILD
import CoreGraphics
import Foundation
import LiveWallpaperProWPE
import Metal

private func wpeRenderTargetDimension(_ base: CGFloat, scale: Double) -> Int {
    // WPE effect FBO scale is a downsample divisor: scale 4 means one quarter size.
    let divisor = scale.isFinite && scale > 0 ? scale : 1
    // TRUNCATE, don't round.
    let pixels = Double(base) / divisor
    guard !pixels.isNaN, pixels > 1 else { return 1 }
    // An unrepresentable edge remains oversized, so the shared descriptor
    // validation rejects it before either allocation or alias-heap queries.
    return Int(min(pixels, Double(wpeMaxRenderTargetEdge)))
}

/// Ceiling so Int conversion cannot trap; Metal still rejects a genuinely impossible size.
private let wpeMaxRenderTargetEdge = 1 << 20

/// WPE effect FBO `fit`: preserve aspect ratio and make the longest edge equal
/// to the authored pixel value. Unlike `scale`, this path rounds both axes.
private func wpeFitRenderTargetExtent(_ base: CGSize, fit: Double?) -> (width: Int, height: Int)? {
    guard let fit, fit.isFinite, fit > 0 else { return nil }
    let width = Double(base.width)
    let height = Double(base.height)
    let longest = max(width, height)
    guard width.isFinite, height.isFinite, longest > 0 else { return nil }
    let ratio = fit / longest
    guard ratio.isFinite else { return nil }
    // `Int(_:)` traps rather than saturating; clamp in Double first so Metal still reports an oversize allocation.
    func pixels(_ value: Double) -> Int {
        let rounded = (value * ratio).rounded()
        guard rounded.isFinite else { return 1 }
        return Int(min(max(rounded, 1), Double(wpeMaxRenderTargetEdge)))
    }
    return (pixels(width), pixels(height))
}

struct WPEMetalRenderTargetKey: Hashable {
    let name: String
    let width: Int
    let height: Int
    let format: String
    let pixelFormat: MTLPixelFormat

    init(name: String, width: Int, height: Int, format: String, pixelFormat: MTLPixelFormat) {
        self.name = name
        self.width = max(width, 1)
        self.height = max(height, 1)
        self.format = format.lowercased()
        self.pixelFormat = pixelFormat
    }
}

final class WPEMetalRenderTargetPool {
    /// Set per scene by the executor: HDR scenes promote 8-bit FBOs to
    /// half-float (see `pixelFormat(forFBOFormat:promoteLDRToHDR:)`).
    var promotesLDRFormatsToHDR = false

    /// 1 = bit-identical to the pre-scaling pool. Partial scaling is forbidden.
    var pixelScale: Double = 1

    /// Register the WORLD size; without this the registry reports scaled physical size and identity-less layers shrink by the pixel scale. Identity at scale 1.
    private func registerWorldSize(of texture: MTLTexture) {
        guard pixelScale < 1 else {
            WPEMetalTextureMetadataRegistry.shared.register(texture: texture)
            return
        }
        WPEMetalTextureMetadataRegistry.shared.register(
            texture: texture,
            worldWidth: Int((Double(texture.width) / pixelScale).rounded()),
            worldHeight: Int((Double(texture.height) / pixelScale).rounded())
        )
    }

    private struct Allocation {
        let texture: MTLTexture
        let heap: MTLHeap?
    }

    private final class Slot {
        var primary: Allocation?
        var secondary: Allocation?
    }

    /// Last use is never under-estimated, so a target is only made aliasable AFTER its real last GPU use.
    struct AliasInterval: Equatable {
        let key: WPEMetalRenderTargetKey
        let firstPass: Int
        let lastPass: Int
    }

    /// nil → keep the full-scene default; only `layer.localFBOs` entries qualify.
    static func layerLocalFBOPixelSize(
        fboName: String,
        layer: WPERenderLayer,
        sceneSize: CGSize,
        memo: WPESceneCaptureOutputGeometryMemo? = nil
    ) -> CGSize? {
        let localFBOName = WPERenderTargetNames.PuppetClip.baseName(of: fboName) ?? fboName
        guard !WPETextureReference.isSceneAliasName(fboName),
              layer.localFBOs.contains(where: { $0.name == localFBOName }) else { return nil }
        return layerCompositeSize(for: layer, sceneSize: sceneSize, memo: memo)
    }

    let sceneCaptureGeometryMemo = WPESceneCaptureOutputGeometryMemo()

    private let device: MTLDevice
    private let maximumTextureDimension2D: Int
    private var slots: [WPEMetalRenderTargetKey: Slot] = [:]
    private var declaredFBOs: [String: WPERenderFBO] = [:]
    /// WPE treats a freshly created RT as all-zero, so the first read must see zero rather than fail the scene.
    private var zeroPlaceholderTextures: [String: MTLTexture] = [:]

    private var aliasHeap: MTLHeap?
    private var aliasLastPassByKey: [WPEMetalRenderTargetKey: Int] = [:]
    private var aliasFrameTextures: [WPEMetalRenderTargetKey: (texture: MTLTexture, lastPass: Int)] = [:]
    /// What `aliasHeap` was sized for. Keys are deliberately absent: the same size/lifetime
    /// sequence under different keys reuses the heap but must still refresh `aliasLastPassByKey`.
    private struct AliasPlanInputs: Equatable {
        let intervals: [WPEMetalFBOAliasPlanner.Interval]
        let alignment: Int
    }

    private var aliasPlanInputs: AliasPlanInputs?

    /// Compare INPUTS, not the post-descriptor plan signature. Full equality (not a hash) so a collision cannot serve a stale plan.
    private struct PrepareInputs: Equatable {
        let pipelineIdentity: Int
        /// Neither field is fully encoded in the interval keys: an already-float FBO keeps the same key across an HDR toggle.
        let pixelScale: Double
        let promotesLDRFormatsToHDR: Bool
        let aliasIntervals: [AliasInterval]
    }

    private var lastPrepareInputs: PrepareInputs?

    /// Test seam: how many times `prepare` ran its body instead of early-exiting.
    private(set) var prepareRebuildCount = 0
    /// Test seam: `heapTextureSizeAndAlign` calls issued by the alias planner.
    private(set) var aliasPlanDeviceQueryCount = 0

    init(device: MTLDevice, maximumTextureDimension2D: Int? = nil) {
        self.device = device
        self.maximumTextureDimension2D = maximumTextureDimension2D
            ?? WPEMetalTextureLimits.maximum2DTextureDimension(for: device)
    }

    /// nil = the caller cannot vouch, so nothing is skipped.
    func prepare(
        pipeline: WPEPreparedRenderPipeline,
        aliasIntervals: [AliasInterval] = [],
        pipelineIdentity: Int? = nil
    ) {
        let inputs = pipelineIdentity.map {
            PrepareInputs(
                pipelineIdentity: $0,
                pixelScale: pixelScale,
                promotesLDRFormatsToHDR: promotesLDRFormatsToHDR,
                aliasIntervals: aliasIntervals
            )
        }
        if let inputs, inputs == lastPrepareInputs { return }

        prepareRebuildCount += 1
        declaredFBOs.removeAll(keepingCapacity: true)
        for layer in pipeline.layers {
            for fbo in layer.graphLayer.localFBOs {
                declaredFBOs[fbo.name] = fbo
            }
        }

        guard !aliasIntervals.isEmpty else {
            releaseAliasState()
            lastPrepareInputs = inputs
            return
        }
        prepareAliasPlan(aliasIntervals)
        // Assigned last: `prepareAliasPlan` clears this via `releaseAliasState`
        // mid-rebuild. A planner that produced no heap (allocation failure) is
        // NOT stable — leave the cache empty so the next frame retries.
        lastPrepareInputs = aliasPlanInputs == nil ? nil : inputs
    }

    func releaseAll() {
        slots.removeAll(keepingCapacity: true)
        declaredFBOs.removeAll(keepingCapacity: true)
        zeroPlaceholderTextures.removeAll(keepingCapacity: true)
        // A reload can reuse an objectID for a different layer; the memo is
        // keyed by objectID, so it must not survive the pool's scene.
        sceneCaptureGeometryMemo.removeAll()
        releaseAliasState()
    }

    /// Removes obsolete dimension variants for targets whose live text layout
    /// changed. Command buffers retain resources they already reference, so
    /// dropping the pool's ownership here is safe for frames still in flight.
    func discardTextures(named names: Set<String>) {
        guard !names.isEmpty else { return }
        slots = slots.filter { !names.contains($0.key.name) }
        for name in names { zeroPlaceholderTextures[name] = nil }
        // The alias plan includes dimensions in its signature and must be
        // rebuilt alongside the discrete slots.
        releaseAliasState()
    }

    /// Non-nil ONLY when `name` is a declared local FBO; undeclared names return nil so the caller still raises `missingTexture`.
    func zeroFilledPlaceholderTexture(forDeclaredFBO name: String) -> MTLTexture? {
        let lookupName = WPERenderTargetNames.PuppetClip.baseName(of: name) ?? name
        guard let spec = declaredFBOs[lookupName] else { return nil }
        if let cached = zeroPlaceholderTextures[name] { return cached }

        let pixelFormat = Self.pixelFormat(forFBOFormat: spec.format, promoteLDRToHDR: promotesLDRFormatsToHDR)
        // 1×1: a zero texture samples to (0,0,0,0) at every UV, so the stand-in's
        // literal size is irrelevant to a normalized read; a scene-sized `.shared`
        // allocation would pin tens of MB for a dummy history buffer.
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: 1,
            height: 1,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        // CPU-written via `replace`, so it can't be `.private`; discrete GPUs
        // reject `.shared` for textures, so pick `.managed` there.
        descriptor.storageMode = device.hasUnifiedMemory ? .shared : .managed
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.label = "WPE \(name) zero placeholder"
        let bytesPerRow = Self.bytesPerTexel(pixelFormat)
        let zero = [UInt8](repeating: 0, count: bytesPerRow)
        zero.withUnsafeBytes { raw in
            texture.replace(
                region: MTLRegionMake2D(0, 0, 1, 1),
                mipmapLevel: 0,
                withBytes: raw.baseAddress!,
                bytesPerRow: bytesPerRow
            )
        }
        registerWorldSize(of: texture)
        zeroPlaceholderTextures[name] = texture
        return texture
    }

    private static func bytesPerTexel(_ format: MTLPixelFormat) -> Int {
        switch format {
        case .r8Unorm: return 1
        case .rgba16Float: return 8
        default: return 4 // rgba8Unorm(_srgb) / bgra8Unorm
        }
    }

    /// Persistent texture outside the per-frame alias plan: a static layer
    /// composite retained across frames must NOT come from the alias heap (whose
    /// textures are made reusable at frame boundaries) — it gets a discrete one.
    func persistentTexture(matching source: MTLTexture, label: String) throws -> MTLTexture {
        try validateTextureDimensions(targetName: label, width: source.width, height: source.height)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: source.pixelFormat,
            width: source.width,
            height: source.height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw WPEMetalTextureLoaderError.textureAllocationFailed
        }
        texture.label = label
        registerWorldSize(of: texture)
        return texture
    }

    /// Safety across in-flight frames is the heap's `.tracked` hazard mode, NOT the serial queue. Drop objects rather than reuse them — reading/writing an already-aliased instance is undefined.
    func beginAliasFrame() {
        guard !aliasFrameTextures.isEmpty else { return }
        for entry in aliasFrameTextures.values {
            entry.texture.makeAliasable()
        }
        aliasFrameTextures.removeAll(keepingCapacity: true)
    }

    /// The driver (tracked automatic heap) inserts the read-before-write barrier.
    func endPass(passIndex: Int) {
        guard !aliasFrameTextures.isEmpty else { return }
        for (key, entry) in aliasFrameTextures where entry.lastPass == passIndex {
            entry.texture.makeAliasable()
            aliasFrameTextures.removeValue(forKey: key)
        }
    }

    func diagnosticKey(
        for target: WPERenderTarget,
        layer: WPERenderLayer,
        sceneSize: CGSize,
        declaredFBOs: [String: WPERenderFBO]
    ) -> WPEMetalRenderTargetKey {
        diagnosticKey(
            for: target,
            spec: diagnosticSpec(for: target, layer: layer, declaredFBOs: declaredFBOs),
            layer: layer,
            sceneSize: sceneSize
        )
    }

    func diagnosticSpec(
        for target: WPERenderTarget,
        layer: WPERenderLayer,
        declaredFBOs: [String: WPERenderFBO]
    ) -> WPERenderFBO {
        switch target {
        case .scene:
            return WPERenderFBO(name: "scene", scale: 1, format: "rgba8888")
        case .layerComposite(let name):
            return WPERenderFBO(name: name, scale: 1, format: "rgba8888")
        case .fbo(let name):
            if WPERenderTargetNames.PuppetClip.isDeferredSource(name) {
                return WPERenderFBO(name: name, scale: 2, format: "rgba8888")
            }
            let lookupName = WPERenderTargetNames.PuppetClip.baseName(of: name) ?? name
            if let inherited = declaredFBOs[lookupName] ?? layer.localFBOs.first(where: { $0.name == lookupName }) {
                return WPERenderFBO(
                    name: name,
                    scale: inherited.scale,
                    fit: inherited.fit,
                    format: inherited.format,
                    unique: inherited.unique,
                    pixelSize: inherited.pixelSize
                )
            }
            return WPERenderFBO(name: name, scale: 1, format: "rgba8888")
        }
    }

    /// `spec` MUST come from `diagnosticSpec` for the same target; a foreign spec would mis-key the alias plan.
    func diagnosticKey(
        for target: WPERenderTarget,
        spec: WPERenderFBO,
        layer: WPERenderLayer,
        sceneSize: CGSize
    ) -> WPEMetalRenderTargetKey {
        let pixelFormat = Self.pixelFormat(forFBOFormat: spec.format, promoteLDRToHDR: promotesLDRFormatsToHDR)
        let dimensions = keyDimensions(
            for: target,
            spec: spec,
            layer: layer,
            sceneSize: sceneSize,
            pixelScale: pixelScale
        )
        return WPEMetalRenderTargetKey(
            name: spec.name,
            width: dimensions.width,
            height: dimensions.height,
            format: spec.format,
            pixelFormat: pixelFormat
        )
    }

    /// `pixelScale` converts each world canvas through `scaledCanvasSize` BEFORE the authored scale-divisor/fit derivation.
    private func keyDimensions(
        for target: WPERenderTarget,
        spec: WPERenderFBO,
        layer: WPERenderLayer,
        sceneSize: CGSize,
        pixelScale: Double
    ) -> (width: Int, height: Int) {
        func canvas(_ size: CGSize) -> CGSize {
            // `minimumEdge: 1` — the 64px floor belongs to the scaler's INPUT,
            // not to pooled targets: an authored 128x16 strip must scale to
            // 64x8, never to 64x64.
            WPEMetalFXSpatialUpscaler.scaledCanvasSize(
                size, pixelScale: pixelScale, minimumEdge: 1
            )
        }
        let fit = pixelScale < 1 ? spec.fit.map { $0 * pixelScale } : spec.fit
        if let pixelSize = spec.pixelSize {
            let scaled = canvas(pixelSize)
            return (
                wpeRenderTargetDimension(scaled.width, scale: spec.scale),
                wpeRenderTargetDimension(scaled.height, scale: spec.scale)
            )
        }
        if case .layerComposite = target {
            let localSize = canvas(Self.layerCompositeSize(
                for: layer,
                sceneSize: sceneSize,
                memo: sceneCaptureGeometryMemo
            ))
            if let fitted = wpeFitRenderTargetExtent(localSize, fit: fit) {
                return fitted
            }
            return (
                wpeRenderTargetDimension(localSize.width, scale: spec.scale),
                wpeRenderTargetDimension(localSize.height, scale: spec.scale)
            )
        }
        if case .fbo(let fboName) = target,
           let localSize = Self.layerLocalFBOPixelSize(
               fboName: fboName,
               layer: layer,
               sceneSize: sceneSize,
               memo: sceneCaptureGeometryMemo
           ) {
            let scaledLocal = canvas(localSize)
            if let fitted = wpeFitRenderTargetExtent(scaledLocal, fit: fit) {
                return fitted
            }
            return (
                wpeRenderTargetDimension(scaledLocal.width, scale: spec.scale),
                wpeRenderTargetDimension(scaledLocal.height, scale: spec.scale)
            )
        }
        let scaledScene = canvas(sceneSize)
        if let fitted = wpeFitRenderTargetExtent(scaledScene, fit: fit) {
            return fitted
        }
        return (
            wpeRenderTargetDimension(scaledScene.width, scale: spec.scale),
            wpeRenderTargetDimension(scaledScene.height, scale: spec.scale)
        )
    }

    /// With scaling active the destination texture is `pixelScale` SMALLER than the world canvas; using texture dimensions would grow content by 1/pixelScale.
    func worldCanvasSize(
        for target: WPERenderTarget,
        layer: WPERenderLayer,
        sceneSize: CGSize
    ) -> CGSize {
        switch target {
        case .scene:
            return sceneSize
        case .fbo, .layerComposite:
            let dimensions = keyDimensions(
                for: target,
                spec: targetSpec(for: target, layer: layer),
                layer: layer,
                sceneSize: sceneSize,
                pixelScale: 1
            )
            return CGSize(width: dimensions.width, height: dimensions.height)
        }
    }

    func texture(
        for target: WPERenderTarget,
        layer: WPERenderLayer,
        sceneSize: CGSize,
        avoiding textureToAvoid: MTLTexture?
    ) throws -> MTLTexture {
        let spec = targetSpec(for: target, layer: layer)
        let pixelFormat = Self.pixelFormat(forFBOFormat: spec.format, promoteLDRToHDR: promotesLDRFormatsToHDR)
        let key = targetKey(
            for: target,
            spec: spec,
            layer: layer,
            sceneSize: sceneSize,
            pixelFormat: pixelFormat
        )

        if textureToAvoid == nil, let lastPass = aliasLastPassByKey[key] {
            return try aliasTexture(for: key, lastPass: lastPass)
        }

        let slot = slots[key] ?? Slot()
        slots[key] = slot

        if slot.primary == nil {
            slot.primary = try makeAllocation(key: key, label: "primary")
        }

        if let textureToAvoid,
           let primary = slot.primary,
           primary.texture === textureToAvoid {
            if slot.secondary == nil {
                slot.secondary = try makeAllocation(key: key, label: "secondary")
            }
            guard let secondary = slot.secondary else {
                throw WPEMetalTextureLoaderError.textureAllocationFailed
            }
            return secondary.texture
        }

        guard let primary = slot.primary else {
            throw WPEMetalTextureLoaderError.textureAllocationFailed
        }
        return primary.texture
    }

    /// `diagnosticSpec` against this pool's own declarations; the executor passes its own.
    private func targetSpec(for target: WPERenderTarget, layer: WPERenderLayer) -> WPERenderFBO {
        diagnosticSpec(for: target, layer: layer, declaredFBOs: declaredFBOs)
    }

    /// Framebuffer fetch or a direct live-scene bind may replace a snapshot only when
    /// the snapshot itself would involve no resizing or format conversion.
    func sceneSnapshotMatches(
        _ texture: MTLTexture, alias: String = WPESceneAliasName.fullFrameBuffer,
        layer: WPERenderLayer, sceneSize: CGSize
    ) -> Bool {
        let target = WPERenderTarget.fbo(name: alias)
        let key = diagnosticKey(for: target, spec: targetSpec(for: target, layer: layer),
                                layer: layer, sceneSize: sceneSize)
        return key.width == texture.width && key.height == texture.height && key.pixelFormat == texture.pixelFormat
    }

    private func targetKey(
        for target: WPERenderTarget,
        spec: WPERenderFBO,
        layer: WPERenderLayer,
        sceneSize: CGSize,
        pixelFormat: MTLPixelFormat
    ) -> WPEMetalRenderTargetKey {
        let dimensions = keyDimensions(
            for: target,
            spec: spec,
            layer: layer,
            sceneSize: sceneSize,
            pixelScale: pixelScale
        )
        return WPEMetalRenderTargetKey(
            name: spec.name,
            width: dimensions.width,
            height: dimensions.height,
            format: spec.format,
            pixelFormat: pixelFormat
        )
    }

    private static func layerCompositeSize(
        for layer: WPERenderLayer,
        sceneSize: CGSize,
        memo: WPESceneCaptureOutputGeometryMemo? = nil
    ) -> CGSize {
        // Fullscreen compose/project layer-composite targets MUST be scene-sized. Local composelayer boxes use their authored local texture size.
        if layer.isUtilityModelLayer,
           layer.groupCompositeSource == nil,
           (memo?.outputGeometry(
               layer: layer,
               geometry: layer.geometry,
               sceneSize: sceneSize
           ) ?? WPEMetalSceneCaptureUtilityModels.outputGeometry(
               kind: layer.utilityModelKind,
               geometry: layer.geometry,
               sceneSize: sceneSize
           )) == .fullscreen {
            return sceneSize
        }

        guard layer.geometry != .identity,
              let size = layer.geometry.size else {
            return sceneSize
        }

        return CGSize(
            width: max(size.width, 1),
            height: max(size.height, 1)
        )
    }

    private func textureDescriptor(for key: WPEMetalRenderTargetKey) throws -> MTLTextureDescriptor {
        try validateTextureDimensions(targetName: key.name, width: key.width, height: key.height)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: key.pixelFormat,
            width: key.width,
            height: key.height,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        return descriptor
    }

    // MARK: - FBO aliasing (placement heap, hazard-tracked by the driver)

    private func aliasTexture(for key: WPEMetalRenderTargetKey, lastPass: Int) throws -> MTLTexture {
        if let existing = aliasFrameTextures[key] {
            return existing.texture
        }
        if let aliasHeap,
           let descriptor = try? textureDescriptor(for: key),
           let texture = aliasHeap.makeTexture(descriptor: descriptor) {
            WPEFrameOccupancyMeter.count(.aliasHeapTextureCreate)
            texture.label = "WPE \(key.name) alias texture"
            registerWorldSize(of: texture)
            aliasFrameTextures[key] = (texture, lastPass)
            return texture
        }
        // Heap exhausted/unavailable: discrete fallback so a planning shortfall
        // degrades gracefully, never a render failure.
        let slot = slots[key] ?? Slot()
        slots[key] = slot
        if slot.primary == nil {
            slot.primary = try makeAllocation(key: key, label: "primary")
        }
        guard let primary = slot.primary else {
            throw WPEMetalTextureLoaderError.textureAllocationFailed
        }
        return primary.texture
    }

    private func prepareAliasPlan(_ intervals: [AliasInterval]) {
        var plannerIntervals: [WPEMetalFBOAliasPlanner.Interval] = []
        var lastPassByKey: [WPEMetalRenderTargetKey: Int] = [:]
        var maxAlignment = 1
        for (index, interval) in intervals.enumerated() {
            guard interval.firstPass <= interval.lastPass,
                  let descriptor = try? textureDescriptor(for: interval.key) else { continue }
            aliasPlanDeviceQueryCount += 1
            let sizeAndAlign = device.heapTextureSizeAndAlign(descriptor: descriptor)
            guard sizeAndAlign.size > 0 else { continue }
            maxAlignment = max(maxAlignment, sizeAndAlign.align)
            plannerIntervals.append(.init(
                id: index,
                size: Self.align(sizeAndAlign.size, to: sizeAndAlign.align),
                firstPass: interval.firstPass,
                lastPass: interval.lastPass
            ))
            lastPassByKey[interval.key] = interval.lastPass
        }

        guard !plannerIntervals.isEmpty else {
            releaseAliasState()
            return
        }

        let planInputs = AliasPlanInputs(intervals: plannerIntervals, alignment: maxAlignment)
        if aliasPlanInputs == planInputs, aliasHeap != nil {
            aliasLastPassByKey = lastPassByKey
            return
        }

        releaseAliasState()

        let plan = WPEMetalFBOAliasPlanner.plan(plannerIntervals, alignment: maxAlignment)
        guard plan.heapSize > 0 else { return }

        let heapDescriptor = MTLHeapDescriptor()
        heapDescriptor.type = .automatic
        heapDescriptor.storageMode = .private
        heapDescriptor.hazardTrackingMode = .tracked
        heapDescriptor.size = Self.align(plan.heapSize + maxAlignment, to: maxAlignment)
        guard let heap = device.makeHeap(descriptor: heapDescriptor) else { return }

        aliasHeap = heap
        aliasLastPassByKey = lastPassByKey
        aliasPlanInputs = planInputs
    }

    private func releaseAliasState() {
        // Single choke point for every invalidation (`releaseAll`,
        // `discardTextures`, empty-interval frames, plan rebuild), so the
        // early-out cache can never outlive the plan it vouches for.
        lastPrepareInputs = nil
        aliasFrameTextures.removeAll(keepingCapacity: false)
        aliasLastPassByKey.removeAll(keepingCapacity: false)
        aliasHeap = nil
        aliasPlanInputs = nil
    }

    private func makeAllocation(key: WPEMetalRenderTargetKey, label: String) throws -> Allocation {
        let descriptor = try textureDescriptor(for: key)

        let sizeAndAlign = device.heapTextureSizeAndAlign(descriptor: descriptor)
        if sizeAndAlign.size > 0 {
            let heapDescriptor = MTLHeapDescriptor()
            heapDescriptor.storageMode = descriptor.storageMode
            heapDescriptor.size = Self.align(sizeAndAlign.size, to: sizeAndAlign.align)
            heapDescriptor.hazardTrackingMode = .tracked
            if let heap = device.makeHeap(descriptor: heapDescriptor),
               let texture = heap.makeTexture(descriptor: descriptor) {
                texture.label = "WPE \(key.name) \(label) heap texture"
                registerWorldSize(of: texture)
                return Allocation(texture: texture, heap: heap)
            }
        }

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw WPEMetalTextureLoaderError.textureAllocationFailed
        }
        texture.label = "WPE \(key.name) \(label) texture"
        registerWorldSize(of: texture)
        return Allocation(texture: texture, heap: nil)
    }

    private func validateTextureDimensions(targetName: String, width: Int, height: Int) throws {
        guard width <= maximumTextureDimension2D,
              height <= maximumTextureDimension2D else {
            throw WPEMetalRenderExecutorError.renderTargetDimensionsExceedDeviceLimit(
                targetName: targetName,
                width: width,
                height: height,
                limit: maximumTextureDimension2D
            )
        }
    }

    static func align(_ size: Int, to alignment: Int) -> Int {
        guard alignment > 0 else { return size }
        let remainder = size % alignment
        return remainder == 0 ? size : size + alignment - remainder
    }

    /// HDR scenes promote 8-bit color targets to `.rgba16Float`; otherwise >1 emissive dies at the first layer-composite copy. Alpha masks (`r8`) stay 8-bit.
    static func pixelFormat(forFBOFormat format: String, promoteLDRToHDR: Bool) -> MTLPixelFormat {
        switch format.lowercased() {
        case "rgba16f", "rgba_half", "rgba16161616f":
            return .rgba16Float
        case "r8", "r8unorm":
            return .r8Unorm
        // Official effects author these (fluidsimulation pressure/velocity
        // buffers); already float, so HDR promotion must not touch them.
        case "r16f":
            return .r16Float
        case "rg1616f":
            return .rg16Float
        default:
            return promoteLDRToHDR ? .rgba16Float : WPEMetalRenderExecutor.outputPixelFormat
        }
    }
}
#endif
