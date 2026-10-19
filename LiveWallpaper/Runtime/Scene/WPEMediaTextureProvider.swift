#if !LITE_BUILD
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import LiveWallpaperProWPE
import Metal

/// `@unchecked Sendable`: every stored property is read and written only inside `lock` —
/// `@MainActor` now-playing delivery calls `ingest` while the per-display render thread calls
/// `declarations(forPassID:)`/`substituting(_:slot:declarations:)` mid-encode. `MTLTexture`
/// isn't `Sendable`, which rules out `OSAllocatedUnfairLock`; a texture is fully written by
/// `replaceRegion` before being published under the lock, then immutable.
final class WPEMediaTextureStore: @unchecked Sendable {
    /// A fully uploaded pair for one parity input.
    struct ParitySnapshot: @unchecked Sendable { // MTLTexture: fully uploaded before paritySnapshot publishes it, never written after
        let revision: UInt64
        let current: (any MTLTexture)?
        let previous: (any MTLTexture)?
        let currentSystemName: String?
        let previousSystemName: String?

        func texture(for kind: WPEMediaSystemTexture) -> (any MTLTexture)? {
            switch kind {
            case .thumbnail: current
            case .previousThumbnail: previous
            }
        }
    }

    private enum UploadFailure: String, Error {
        case undecodable
        case bitmapContextUnavailable
        case textureAllocationFailed
    }

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

    // The dispatcher owns parity artwork identity even without GPU demand. This cache holds at most its pair.
    private var parityCurrentKey: String?
    private var parityPreviousKey: String?
    private var parityCurrent: (any MTLTexture)?
    private var parityPrevious: (any MTLTexture)?

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
            if let current = currentTexture {
                previousTexture = current
            }
            currentKey = nil
            currentTexture = nil
            return changed
        }
        let key = WPEMediaArtworkPaletteCache.identity(of: artwork)
        lock.lock()
        let unchanged = key == currentKey
        lock.unlock()
        if unchanged {
            return false
        }

        // Decode outside the lock: the render thread must never block behind an
        // ImageIO call, and a stale-by-one-frame cover is invisible.
        let uploaded = Self.makeTexture(from: artwork, device: device)

        lock.lock()
        defer { lock.unlock() }
        guard let uploaded else {
            // Undecodable bytes are "no artwork": the authored placeholder is a
            // better rendering than a hole, and retrying per frame is pointless.
            let changed = currentTexture != nil || currentKey != nil
            if let current = currentTexture {
                previousTexture = current
            }
            currentKey = nil
            currentTexture = nil
            return changed
        }
        if let current = currentTexture {
            previousTexture = current
        }
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

    /// Called on the dispatcher's MainActor after it establishes the source observation's identities.
    /// The same bytes reuse uploaded textures across reload; enabling demand can upload both known covers.
    func paritySnapshot(revision: UInt64, currentArtwork: Data?, previousArtwork: Data?,
                        currentSystemName: String?, previousSystemName: String?)
        -> (snapshot: ParitySnapshot, diagnostics: [String]) {
        let currentKey = currentArtwork.map(WPEMediaArtworkPaletteCache.identity)
        let previousKey = previousArtwork.map(WPEMediaArtworkPaletteCache.identity)
        lock.lock()
        var cached: [String: any MTLTexture] = [:]
        if let parityCurrentKey, let parityCurrent {
            cached[parityCurrentKey] = parityCurrent
        }
        if let parityPreviousKey, let parityPrevious {
            cached[parityPreviousKey] = parityPrevious
        }
        lock.unlock()
        var diagnostics: [String] = []
        var newUploads = 0
        for (key, bytes) in [(previousKey, previousArtwork), (currentKey, currentArtwork)] {
            guard let key, let bytes, cached[key] == nil else { continue }
            do {
                cached[key] = try Self.uploadTexture(from: bytes, device: device)
                newUploads += 1
            } catch {
                diagnostics.append("media.artwork-\(error.rawValue)-native-behavior-unverified")
            }
        }
        if currentArtwork != nil || previousArtwork != nil {
            diagnostics.append("media.artwork-native-sizing-unverified:mac-maximum-edge=\(Self.maximumEdge)")
        }
        lock.lock()
        defer { lock.unlock() }
        parityCurrentKey = currentKey
        parityPreviousKey = previousKey
        parityCurrent = currentKey.flatMap { cached[$0] }
        parityPrevious = previousKey.flatMap { cached[$0] }
        uploads += newUploads
        return (ParitySnapshot(revision: revision, current: parityCurrent, previous: parityPrevious,
                               currentSystemName: currentSystemName, previousSystemName: previousSystemName), diagnostics)
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

    /// A swapped-in cover is a whole image: the placeholder's TEXS sprite transform would crop/rotate it.
    /// Explicit identity, not nil: a nil slot descriptor lets the uniform fall through to pass/authored values.
    static func samplingDescriptor(
        authored: WPETexSpriteSamplingDescriptor?,
        authoredTexture: MTLTexture?,
        boundTexture: MTLTexture?
    ) -> WPETexSpriteSamplingDescriptor? {
        boundTexture === authoredTexture ? authored : .identity
    }

    // MARK: - Upload

    /// sRGB-encoded bytes in a raw UNORM texture, like authored and video textures: shaders get encoded values and present decodes once.
    private static func makeTexture(from artwork: Data, device: MTLDevice) -> MTLTexture? {
        try? uploadTexture(from: artwork, device: device)
    }

    /// Palette analysis can be empty for a valid transparent image. This fallback decodes no GPU resource.
    static func hasDecodableParityArtwork(_ artwork: Data) -> Bool {
        (try? thumbnailImage(from: artwork, maximumEdge: 1)) != nil
    }

    private static func thumbnailImage(from artwork: Data, maximumEdge: Int) throws(UploadFailure) -> CGImage {
        guard let source = CGImageSourceCreateWithData(artwork as CFData, nil) else { throw .undecodable }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumEdge,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw .undecodable }
        return image
    }

    private static func uploadTexture(from artwork: Data, device: MTLDevice) throws(UploadFailure) -> MTLTexture {
        let image = try thumbnailImage(from: artwork, maximumEdge: maximumEdge)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { throw .bitmapContextUnavailable }

        let width = min(image.width, maximumEdge)
        let height = min(image.height, maximumEdge)
        guard width > 0, height > 0 else { throw .undecodable }

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
        guard drawn else { throw .bitmapContextUnavailable }
        // Media slots share the straight external-image contract with authored images.
        WPERasterImageAlpha.unpremultiplyRGBA8(&bytes)

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw .textureAllocationFailed }
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
                guard let self, self.isSubscribed else { return }
                self.ingest(ordinal: ordinal, state: state)
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
        if let lastOrdinal, ordinal < lastOrdinal {
            return
        }
        lastOrdinal = ordinal
        if store.ingest(artwork: state.artwork) {
            onTextureChange?()
        }
    }
}
#endif
