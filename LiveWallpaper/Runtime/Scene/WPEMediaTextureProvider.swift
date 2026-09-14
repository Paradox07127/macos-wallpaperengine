#if !LITE_BUILD
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import LiveWallpaperProWPE
import Metal

// Absent cover must leave the $media* slot alone, not bind an empty texture.

enum WPEMediaTextureDemand {
    /// Slot map precedence is override > pass > material.
    static func slots(in bindings: WPERenderUserTextureBindings) -> [Int: WPEMediaSystemTexture] {
        var result: [Int: WPEMediaSystemTexture] = [:]
        for locus in [bindings.material, bindings.pass, bindings.override] {
            for binding in locus {
                guard let slot = binding.slot,
                      let kind = WPEMediaSystemTexture(bindingName: binding.name) else { continue }
                result[slot] = kind
            }
        }
        return result
    }

    static func byPassID(in pipeline: WPEPreparedRenderPipeline) -> [String: [Int: WPEMediaSystemTexture]] {
        var result: [String: [Int: WPEMediaSystemTexture]] = [:]
        for layer in pipeline.layers {
            for prepared in layer.passes {
                let slots = slots(in: prepared.pass.userTextureBindings)
                guard !slots.isEmpty else { continue }
                result[prepared.pass.id] = slots
            }
        }
        return result
    }
}

/// `@unchecked Sendable`: every stored property is read and written only inside `lock` —
/// `@MainActor` now-playing delivery calls `ingest` while the per-display render thread calls
/// `declarations(forPassID:)`/`substituting(_:slot:declarations:)` mid-encode. `MTLTexture`
/// isn't `Sendable`, which rules out `OSAllocatedUnfairLock`; a texture is fully written by
/// `replaceRegion` before being published under the lock, then immutable.
final class WPEMediaTextureStore: @unchecked Sendable {
    /// Author guidance is 100×100–256×256; a 4K wallpaper gains nothing from a full-resolution cover.
    static let maximumEdge = 256

    private let device: MTLDevice
    private let lock = NSLock()
    private let slotsByPassID: [String: [Int: WPEMediaSystemTexture]]

    private var currentTexture: MTLTexture?
    private var previousTexture: MTLTexture?
    /// Digest of the uploaded bytes: trackID alone is not enough and Data's hash is not stable across launches.
    private var currentKey: String?
    private var uploads = 0

    init(device: MTLDevice, slotsByPassID: [String: [Int: WPEMediaSystemTexture]] = [:]) {
        self.device = device
        self.slotsByPassID = slotsByPassID
    }

    var uploadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return uploads
    }

    /// nil when this pass declares no `$media*` slot, which is every pass of
    /// every scene that does not use the feature.
    func declarations(forPassID passID: String) -> [Int: WPEMediaSystemTexture]? {
        slotsByPassID[passID]
    }

    /// Returns whether a texture actually changed, so the caller can wake a parked frame loop.
    @discardableResult
    func ingest(artwork: Data?) -> Bool {
        guard let artwork, !artwork.isEmpty else {
            lock.lock()
            defer { lock.unlock() }
            let changed = currentTexture != nil || currentKey != nil
            // The cover that was playing stays in the previous slot: A → gap → B
            // must still crossfade from A, not from the placeholder.
            if let current = currentTexture { previousTexture = current }
            currentKey = nil
            currentTexture = nil
            return changed
        }
        let key = WPEMediaArtworkPaletteCache.identity(of: artwork)
        lock.lock()
        let unchanged = key == currentKey
        lock.unlock()
        if unchanged { return false }

        // Decode outside the lock: the render thread must never block behind an
        // ImageIO call, and a stale-by-one-frame cover is invisible.
        let uploaded = Self.makeTexture(from: artwork, device: device)

        lock.lock()
        defer { lock.unlock() }
        guard let uploaded else {
            // Undecodable bytes are "no artwork": the authored placeholder is a
            // better rendering than a hole, and retrying per frame is pointless.
            let changed = currentTexture != nil || currentKey != nil
            if let current = currentTexture { previousTexture = current }
            currentKey = nil
            currentTexture = nil
            return changed
        }
        if let current = currentTexture { previousTexture = current }
        currentTexture = uploaded
        currentKey = key
        uploads += 1
        return true
    }

    func texture(for kind: WPEMediaSystemTexture) -> MTLTexture? {
        lock.lock()
        defer { lock.unlock() }
        switch kind {
        case .thumbnail: return currentTexture
        case .previousThumbnail: return previousTexture
        }
    }

    /// authored is the placeholder from normal slot resolution; returned unchanged for undeclared slots and declared slots with no artwork yet.
    func substituting(
        _ authored: MTLTexture?,
        slot: Int,
        declarations: [Int: WPEMediaSystemTexture]
    ) -> MTLTexture? {
        guard let kind = declarations[slot] else { return authored }
        return texture(for: kind) ?? authored
    }

    // MARK: - Upload

    /// sRGB to match how authored scene albedo textures are sampled.
    private static func makeTexture(from artwork: Data, device: MTLDevice) -> MTLTexture? {
        guard let source = CGImageSourceCreateWithData(artwork as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumEdge
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }

        let width = min(image.width, maximumEdge)
        let height = min(image.height, maximumEdge)
        guard width > 0, height > 0 else { return nil }

        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        let drawn: Bool = bytes.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm_srgb,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: base,
                bytesPerRow: bytesPerRow
            )
        }
        return texture
    }
}

@MainActor
final class WPEMediaTextureSubscription {
    private let id = UUID()
    private let store: WPEMediaTextureStore
    private let source: any WPENowPlayingEventSource
    private var isSubscribed = false
    private var lastOrdinal: UInt64?
    /// Fired when an ingest actually swapped a texture.
    var onTextureChange: (@Sendable () -> Void)?

    init(store: WPEMediaTextureStore, source: any WPENowPlayingEventSource) {
        self.store = store
        self.source = source
    }

    func start() {
        guard !isSubscribed else { return }
        isSubscribed = true
        // `subscribe` replays current state synchronously, so a scene loaded
        // mid-song shows the right cover on its first frame.
        source.subscribe(id: id) { [weak self] ordinal, state in
            MainActor.assumeIsolated {
                self?.ingest(ordinal: ordinal, state: state)
            }
        }
    }

    func stop() {
        guard isSubscribed else { return }
        isSubscribed = false
        source.unsubscribe(id: id)
    }

    private func ingest(ordinal: UInt64, state: MonitorNowPlayingState) {
        // The ordinal drops a late hop rather than rewinding; out-of-order would also corrupt `$mediaPreviousThumbnail`.
        if let lastOrdinal, ordinal < lastOrdinal { return }
        lastOrdinal = ordinal
        if store.ingest(artwork: state.artwork) { onTextureChange?() }
    }
}
#endif
