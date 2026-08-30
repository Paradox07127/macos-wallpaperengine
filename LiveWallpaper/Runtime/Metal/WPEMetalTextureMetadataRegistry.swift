#if !LITE_BUILD
import Foundation
import LiveWallpaperProWPE
import Metal

struct WPEMetalTextureResolution: Equatable, Sendable {
    let textureWidth: Int
    let textureHeight: Int
    let imageWidth: Int
    let imageHeight: Int
    /// TEXI ClampUVs flag → sample with clamp-to-edge. Defaults to `true` (clamp)
    /// for unregistered textures (render targets / framebuffers) and raster images,
    /// which must not wrap. Only real `.tex` content with the bit UNSET tiles (repeat).
    let clampUVs: Bool
    /// TEXI NoInterpolation flag → sample with nearest filtering. Default `false` (linear).
    let noInterpolation: Bool
    /// The AUTHORED image size in world pixels — unlike `imageWidth`/`imageHeight`, which
    /// describe the uploaded level (shrinking with it under render scaling). World-layout
    /// consumers (the object-quad size fallback) must use this, never the texture's own dimensions; shader UV math keeps using `imageWidth`/`textureWidth`, whose ratio stays level-consistent.
    let worldWidth: Int
    let worldHeight: Int

    init(
        texture: MTLTexture,
        imageWidth: Int? = nil,
        imageHeight: Int? = nil,
        clampUVs: Bool = true,
        noInterpolation: Bool = false,
        worldWidth: Int? = nil,
        worldHeight: Int? = nil
    ) {
        textureWidth = max(texture.width, 1)
        textureHeight = max(texture.height, 1)
        let imageWidth = max(Self.validLogicalSize(imageWidth) ?? texture.width, 1)
        let imageHeight = max(Self.validLogicalSize(imageHeight) ?? texture.height, 1)
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.clampUVs = clampUVs
        self.noInterpolation = noInterpolation
        self.worldWidth = max(Self.validLogicalSize(worldWidth) ?? imageWidth, 1)
        self.worldHeight = max(Self.validLogicalSize(worldHeight) ?? imageHeight, 1)
    }

    var shaderValue: WPESceneShaderConstantValue {
        .vector([
            Double(textureWidth),
            Double(textureHeight),
            Double(imageWidth),
            Double(imageHeight)
        ])
    }

    private static func validLogicalSize(_ value: Int?) -> Int? {
        guard let value, value > 0 else {
            return nil
        }
        return value
    }
}

final class WPEMetalTextureMetadataRegistry: @unchecked Sendable {
    static let shared = WPEMetalTextureMetadataRegistry()

    private final class Entry {
        weak var texture: MTLTexture?
        let resolution: WPEMetalTextureResolution

        init(texture: MTLTexture, resolution: WPEMetalTextureResolution) {
            self.texture = texture
            self.resolution = resolution
        }
    }

    private let lock = NSLock()
    private var resolutions: [ObjectIdentifier: Entry] = [:]
    /// Dead entries (weak texture released) are otherwise only purged when
    /// `resolution(for:)` happens to be queried with the recycled pointer, so
    /// long sessions accumulate them. Sweep every N registers instead.
    private var registersSinceSweep = 0
    private static let sweepInterval = 256

    private init() {}

    func register(
        texture: MTLTexture,
        imageWidth: Int? = nil,
        imageHeight: Int? = nil,
        clampUVs: Bool = true,
        noInterpolation: Bool = false,
        worldWidth: Int? = nil,
        worldHeight: Int? = nil
    ) {
        let key = ObjectIdentifier(texture as AnyObject)
        let resolution = WPEMetalTextureResolution(
            texture: texture,
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            clampUVs: clampUVs,
            noInterpolation: noInterpolation,
            worldWidth: worldWidth,
            worldHeight: worldHeight
        )
        lock.lock()
        resolutions[key] = Entry(texture: texture, resolution: resolution)
        registersSinceSweep += 1
        if registersSinceSweep >= Self.sweepInterval {
            registersSinceSweep = 0
            resolutions = resolutions.filter { $0.value.texture != nil }
        }
        lock.unlock()
    }

    func resolution(for texture: MTLTexture) -> WPEMetalTextureResolution {
        let key = ObjectIdentifier(texture as AnyObject)
        lock.lock()
        if let entry = resolutions[key],
           let registeredTexture = entry.texture,
           ObjectIdentifier(registeredTexture as AnyObject) == key {
            let resolution = entry.resolution
            lock.unlock()
            return resolution
        }
        if resolutions[key] != nil {
            resolutions.removeValue(forKey: key)
        }
        lock.unlock()
        return WPEMetalTextureResolution(texture: texture)
    }

    /// Removes metadata at an explicit owner-driven reclamation boundary so a
    /// following census cannot report an atlas page that has just been purged.
    func unregister(texture: MTLTexture) {
        let key = ObjectIdentifier(texture as AnyObject)
        lock.lock()
        if let registered = resolutions[key]?.texture,
           ObjectIdentifier(registered as AnyObject) == key {
            resolutions.removeValue(forKey: key)
        }
        lock.unlock()
    }

    /// Live GPU-texture census grouped by the `label` prefix each allocation site sets,
    /// answering "where did the gigabytes go" with measured bytes instead of estimates.
    ///
    /// NOT a complete inventory — only what calls `register` (scene textures, render-target
    /// pool). Absent: video `CVMetalTexture`s, the bloom chain (its own shared heap), the
    /// refraction background, the executor's output pool, `.previous` snapshots, depth
    /// textures, hidden-text placeholders. Always read `device.currentAllocatedSize`
    /// alongside it — this explains composition, not the total.
    /// Enable with `defaults write com.loomscreen.pro WPEMemoryAuditLog -bool YES`.
    struct Census {
        /// Bytes each texture owns outright. EXCLUDES heap-aliased render
        /// targets: those all sit in one shared placement heap, so summing
        /// their logical sizes counts the same memory many times over (a
        /// measured 1221.3 MiB against 459.4 MiB of `currentAllocatedSize`).
        var totalBytes = 0
        var count = 0
        /// Logical size of the heap-aliased render targets, reported separately
        /// because it is an upper bound on one shared allocation, not an addend.
        var aliasBytes = 0
        var aliasCount = 0
        /// label prefix → (bytes, count), biggest first when rendered.
        var byCategory: [String: (bytes: Int, count: Int)] = [:]
        var largest: [(label: String, bytes: Int, width: Int, height: Int, format: String)] = []
    }

    func census() -> Census {
        lock.lock()
        let live = resolutions.values.compactMap(\.texture)
        lock.unlock()

        var result = Census()
        var items: [(String, Int, Int, Int, String)] = []
        for texture in live {
            let bytes = Self.approximateBytes(of: texture)
            let label = texture.label ?? "(unlabelled)"
            let category = Self.category(for: label)
            if label.hasSuffix(Self.aliasLabelSuffix) {
                result.aliasBytes += bytes
                result.aliasCount += 1
            } else {
                result.totalBytes += bytes
                result.count += 1
            }
            var bucket = result.byCategory[category] ?? (0, 0)
            bucket.bytes += bytes
            bucket.count += 1
            result.byCategory[category] = bucket
            items.append((label, bytes, texture.width, texture.height, "\(texture.pixelFormat)"))
        }
        result.largest = items.sorted { $0.1 > $1.1 }.prefix(12)
            .map { (label: $0.0, bytes: $0.1, width: $0.2, height: $0.3, format: $0.4) }
        return result
    }

    /// Suffix `WPEMetalRenderTargetPool.aliasTexture` puts on every render target
    /// it places in the ONE shared alias heap. `primary heap texture` gets its
    /// own single-texture heap, so only this suffix means "shares memory".
    private static let aliasLabelSuffix = " alias texture"

    /// Bucket the aliases land in. Kept separate from the plain render-target
    /// bucket so the per-category figures still sum to `totalBytes`; folding
    /// them together made the log's header and its category list disagree by
    /// exactly `aliasBytes`.
    private static let aliasCategory = "WPE render target (alias, shared heap)"

    /// Allocation-site buckets, longest prefix first. Render targets are named
    /// per layer (`WPE _rt_imageLayerComposite_272_a alias texture`), so anything
    /// keying off the label's own words puts every one of them in its own
    /// bucket — 400+ lines that push the totals and `largest` out of the log.
    /// (No `WPE text placeholder` bucket: those 1x1 stand-ins never register.)
    private static let categoryPrefixes: [(prefix: String, name: String)] = [
        ("WPE text glyph", "WPE text glyph"),
        ("WPE _rt_", "WPE render target"),
        ("WPE texture", "WPE texture"),
        ("particle texture", "particle texture"),
    ]

    private static func category(for label: String) -> String {
        if label.hasSuffix(aliasLabelSuffix) { return aliasCategory }
        for entry in categoryPrefixes where label.hasPrefix(entry.prefix) {
            return entry.name
        }
        return label.split(separator: " ").prefix(2).joined(separator: " ")
    }

    /// Shares `WPEMetalTextureByteEstimator` with the texture-cache LRU so the
    /// census reports the same bytes the eviction budget counts (BC block math
    /// included — the old per-pixel path billed BC textures 4-6x over).
    private static func approximateBytes(of texture: MTLTexture) -> Int {
        WPEMetalTextureByteEstimator.estimatedBytes(of: texture)
    }
}
#endif
