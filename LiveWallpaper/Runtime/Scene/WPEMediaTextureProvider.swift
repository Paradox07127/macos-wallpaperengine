#if !LITE_BUILD
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import LiveWallpaperProWPE
import Metal

// `$mediaThumbnail` / `$mediaPreviousThumbnail`: the album-art bitmap a Scene wallpaper
// receives as a system texture bound into a shader slot. Unlike the Web API's
// `mediaThumbnailChanged`, the Scene-side event carries no bitmap — only the palette
// (`WPEMediaArtworkPalette`) — so this is the only path the cover reaches a scene. Corpus shape
// (12 of 54 installed scenes): `usertextures` is positional against the sibling `textures`
// array, `null` in unoverridden slots, and the override entry is a real authored placeholder
// (`util/black`, `workshop/<id>/placeholder`, an author bitmap) — the no-music rendering, so an
// absent cover must leave the slot alone, not bind an empty texture.

enum WPEMediaTextureDemand {
    /// Merged slot map for one pass. Precedence is override > pass > material, matching how
    /// the static `textures`/`combos` merge already resolves an `objects[].instance` over its
    /// base material — no installed scene declares two different `$media*` names for the same
    /// slot across those loci, so the ordering is currently unobservable.
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

    /// The demand gate. Empty for every scene that declares no `$media*` user
    /// texture, which is what keeps the feature free for them: no subscription,
    /// no store, and one optional-chained lookup per pass in the dispatcher.
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

/// Owns the uploaded album-art textures for one scene. `@unchecked Sendable`: every stored
/// property is read and written only inside `lock`. Two threads touch this object —
/// `@MainActor` now-playing delivery calls `ingest`, the per-display render thread calls
/// `declarations(forPassID:)`/`substituting(_:slot:declarations:)` mid-encode — serialised by
/// `NSLock`, mirroring `WPESceneMediaEventMailbox` (WPESceneMediaEvents.swift). `MTLTexture`
/// isn't `Sendable`, ruling out `OSAllocatedUnfairLock` (its state must be); the texture is
/// fully written by `replaceRegion` before ever published under the lock, then immutable, so a
/// render thread only sees a finished texture.
final class WPEMediaTextureStore: @unchecked Sendable {
    /// WPE's own guidance to authors is 100×100–256×256 square covers, and
    /// Apple Music / Spotify deliver roughly 300px anyway. A 4K wallpaper gains
    /// nothing from a full-resolution cover.
    static let maximumEdge = 256

    private let device: MTLDevice
    private let lock = NSLock()
    private let slotsByPassID: [String: [Int: WPEMediaSystemTexture]]

    private var currentTexture: MTLTexture?
    private var previousTexture: MTLTexture?
    /// Digest of the bytes currently uploaded, so a re-delivered unchanged cover
    /// never decodes. Same identity function as the palette cache — `trackID`
    /// alone is not enough (a player can replace the art for one track) and
    /// `Data`'s own hash is not stable across launches.
    private var currentKey: String?
    private var uploads = 0

    init(device: MTLDevice, slotsByPassID: [String: [Int: WPEMediaSystemTexture]] = [:]) {
        self.device = device
        self.slotsByPassID = slotsByPassID
    }

    /// Decoded-and-uploaded covers so far. Test-facing: "a frame never decodes"
    /// is only assertable against a counter, not against timing.
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

    /// Called on the main actor from the now-playing delivery, never per frame.
    /// Returns whether a texture actually changed, so the caller can wake a
    /// parked frame loop — a static scene otherwise keeps the old song's cover.
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

    /// The substitution itself. `authored` is whatever the normal slot
    /// resolution produced — the placeholder the author baked in — and is
    /// returned unchanged both for slots nobody declared and for a declared slot
    /// with no artwork behind it yet.
    func substituting(
        _ authored: MTLTexture?,
        slot: Int,
        declarations: [Int: WPEMediaSystemTexture]
    ) -> MTLTexture? {
        guard let kind = declarations[slot] else { return authored }
        return texture(for: kind) ?? authored
    }

    // MARK: - Upload

    /// ImageIO produces the downsampled thumbnail directly, so the full-size
    /// cover is never decoded. sRGB to match how authored scene albedo textures
    /// are sampled.
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

/// Owns one scene's now-playing subscription for the texture path, separately from
/// `WPESceneMediaEventDispatcher`: a scene can declare `$mediaThumbnail` without exporting a
/// single media script handler (3632513108 and 3660962877 only bind it in
/// `materials/workshop/3449579583/placeholder.json`), and can export handlers without declaring the texture.
@MainActor
final class WPEMediaTextureSubscription {
    private let id = UUID()
    private let store: WPEMediaTextureStore
    private let source: any WPENowPlayingEventSource
    private var isSubscribed = false
    private var lastOrdinal: UInt64?
    /// Fired when an ingest actually swapped a texture. A static scene's frame
    /// loop is parked; without a wake the desktop keeps the old song's cover
    /// until something else demands a frame.
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
        // The ordinal drops a late hop rather than rewinding the cover, and
        // matters more here than for the palette: an out-of-order delivery would
        // also corrupt `$mediaPreviousThumbnail`.
        if let lastOrdinal, ordinal < lastOrdinal { return }
        lastOrdinal = ordinal
        if store.ingest(artwork: state.artwork) { onTextureChange?() }
    }
}
#endif
