#if !LITE_BUILD
import LiveWallpaperProWPE
import Metal

/// Immutable text texture versions share their CPU atlas's entry/ref/generation owner. COLOR fields
/// publish primary and companion together; encoded command buffers retain both old versions through
/// Metal's retainedReferences ownership until completion.
struct WPEParityTextAtlasTextures {
    struct Key: Hashable {
        let atlasKey: String
        let atlas: WPEParityGlyphAtlasInstance.Atlas
        let colorScale: Int
        let plane: WPEParityGlyphAtlas.Plane

        init(atlasKey: String, atlas: WPEParityGlyphAtlasInstance.Atlas, colorScale: Int = 1,
             plane: WPEParityGlyphAtlas.Plane = .primary) {
            self.atlasKey = atlasKey
            self.atlas = atlas
            self.colorScale = colorScale
            self.plane = plane
        }
    }

    private(set) var atlases: [String: WPEParityGlyphAtlasInstance]
    private(set) var textures: [Key: MTLTexture] = [:]
    private(set) var contentGenerations: [Key: UInt64] = [:]

    init(atlases: [String: WPEParityGlyphAtlasInstance]) {
        self.atlases = atlases
    }

    /// Failed preparation keeps the previous CPU snapshot and the complete immutable texture pair.
    @discardableResult
    mutating func replace(_ atlases: [String: WPEParityGlyphAtlasInstance], device: MTLDevice,
                          makeTexture: ((Key, MTLTextureDescriptor) -> MTLTexture?)? = nil) -> Bool {
        var candidate = self
        candidate.atlases = atlases
        guard candidate.upload(device: device, makeTexture: makeTexture) else { return false }
        self = candidate
        return true
    }

    /// Prepare locally before publishing any changed group. Clean groups retain their existing textures.
    @discardableResult
    mutating func upload(device: MTLDevice,
                         makeTexture: ((Key, MTLTextureDescriptor) -> MTLTexture?)? = nil) -> Bool {
        var nextTextures = textures, nextGenerations = contentGenerations, nextAtlases = atlases
        var live: Set<Key> = []
        let maximumDimension = WPEMetalTextureLimits.maximum2DTextureDimension(for: device)
        for (atlasKey, instance) in atlases {
            let groups: [(WPEParityGlyphAtlasInstance.Atlas, Int, WPEParityGlyphAtlas)] =
                [(.mono, 1, instance.mono)] + instance.colorGroups.map { (.color, $0.key, $0.value) }
            for (list, scale, atlas) in groups {
                if list == .color {
                    guard atlas.format == .rgba8, scale == 1 || scale == 2 else { return false }
                    if instance.glyphMode == .distanceField {
                        guard atlas.companionScale == scale else { return false }
                    } else {
                        guard scale == 1, atlas.companionScale == nil else { return false }
                    }
                } else {
                    guard atlas.companionScale == nil else { return false }
                }
                var planes: [(WPEParityGlyphAtlas.Plane, Int, [UInt8])] = [(.primary, 1, atlas.pixels)]
                if let companionScale = atlas.companionScale {
                    guard list == .color, companionScale == scale, let pixels = atlas.companionPixels else { return false }
                    planes.append((.companion, companionScale, pixels))
                }
                let format: MTLPixelFormat = atlas.format == .r8 ? .r8Unorm : .rgba8Unorm
                var uploads: [(Key, Int, Int, Int, [UInt8])] = []
                for (plane, multiplier, pixels) in planes {
                    let (width, widthOverflow) = atlas.width.multipliedReportingOverflow(by: multiplier)
                    let (height, heightOverflow) = atlas.height.multipliedReportingOverflow(by: multiplier)
                    let (rowBytes, rowOverflow) = width.multipliedReportingOverflow(by: atlas.format.bytesPerPixel)
                    let (byteCount, byteOverflow) = rowBytes.multipliedReportingOverflow(by: height)
                    guard !widthOverflow, !heightOverflow, !rowOverflow, !byteOverflow,
                          width > 0, height > 0, width <= maximumDimension, height <= maximumDimension,
                          byteCount == pixels.count else { return false }
                    let key = Key(atlasKey: atlasKey, atlas: list, colorScale: scale, plane: plane)
                    live.insert(key)
                    uploads.append((key, width, height, rowBytes, pixels))
                }
                let stale = uploads.contains { key, width, height, _, _ in
                    guard let texture = textures[key] else { return true }
                    return texture.width != width || texture.height != height || texture.pixelFormat != format
                        || contentGenerations[key] != atlas.contentGeneration
                }
                guard stale || atlas.isDirty else { continue }
                for (key, width, height, rowBytes, pixels) in uploads {
                    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                        pixelFormat: format, width: width, height: height, mipmapped: false
                    )
                    descriptor.usage = .shaderRead
                    descriptor.storageMode = .shared
                    let prepared = if let makeTexture {
                        makeTexture(key, descriptor)
                    } else {
                        device.makeTexture(descriptor: descriptor)
                    }
                    guard let texture = prepared else { return false }
                    texture.label = "\(atlasKey) \(list) scale\(scale) \(key.plane) v\(atlas.contentGeneration)"
                    texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                                    withBytes: pixels, bytesPerRow: rowBytes)
                    nextTextures[key] = texture
                    nextGenerations[key] = atlas.contentGeneration
                }
                if list == .mono {
                    _ = nextAtlases[atlasKey]?.mono.takeDirty()
                } else {
                    _ = nextAtlases[atlasKey]?.colorGroups[scale]?.takeDirty()
                }
            }
        }
        atlases = nextAtlases
        textures = nextTextures.filter { live.contains($0.key) }
        contentGenerations = nextGenerations.filter { live.contains($0.key) }
        return true
    }
}
#endif
