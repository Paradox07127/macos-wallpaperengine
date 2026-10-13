#if !LITE_BUILD
import LiveWallpaperProWPE
import Metal

/// The text layers' glyph atlases and one unmipped texture per atlas key and list: R8Unorm for grey glyphs,
/// RGBA8Unorm for colour glyphs (R23 Q4). Published textures are immutable: a new CPU pixel version gets a new
/// texture. Encoded command buffers retain their texture version until completion through Metal's default
/// retainedReferences ownership; removing an old version here cannot overwrite a GPU reader's pixels.
struct WPEParityTextAtlasTextures {
    struct Key: Hashable {
        let atlasKey: String
        let atlas: WPEParityGlyphAtlasInstance.Atlas
    }

    /// The CPU atlases; an atlas is clean once its pixels are in its texture.
    private(set) var atlases: [String: WPEParityGlyphAtlasInstance]
    private(set) var textures: [Key: MTLTexture] = [:]
    private(set) var contentGenerations: [Key: UInt64] = [:]

    init(atlases: [String: WPEParityGlyphAtlasInstance]) {
        self.atlases = atlases
    }

    /// Takes `atlases` as a re-layout left them and uploads the ones that are new, resized or dirty.
    @discardableResult
    mutating func replace(_ atlases: [String: WPEParityGlyphAtlasInstance], device: MTLDevice) -> Bool {
        self.atlases = atlases
        return upload(device: device)
    }

    /// Publishes missing, resized or changed atlases as new texture versions, uploading their pixels whole as
    /// WPE does before a draw (1401b3430.c:133-144, :187-202). A clean, unchanged atlas performs no allocation or
    /// upload. Returns false on allocation failure, keeping the CPU atlas dirty and withdrawing the stale GPU
    /// version from new draws; already encoded readers retain their old version until completion.
    @discardableResult
    mutating func upload(device: MTLDevice) -> Bool {
        var live: Set<Key> = []
        var succeeded = true
        for (atlasKey, instance) in atlases {
            let lists: [(WPEParityGlyphAtlasInstance.Atlas, WPEParityGlyphAtlas?)] = [
                (.mono, instance.mono), (.color, instance.color),
            ]
            for case let (list, atlas?) in lists {
                let key = Key(atlasKey: atlasKey, atlas: list)
                live.insert(key)
                let format: MTLPixelFormat = atlas.format == .r8 ? .r8Unorm : .rgba8Unorm
                let stale = textures[key].map {
                    $0.width != atlas.width || $0.height != atlas.height || $0.pixelFormat != format
                } ?? true
                guard stale || atlas.isDirty || contentGenerations[key] != atlas.contentGeneration else { continue }
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: format, width: atlas.width, height: atlas.height, mipmapped: false
                )
                descriptor.usage = .shaderRead
                descriptor.storageMode = .shared
                guard let texture = device.makeTexture(descriptor: descriptor) else {
                    textures[key] = nil
                    succeeded = false
                    continue
                }
                texture.label = "\(atlasKey) \(list) v\(atlas.contentGeneration)"
                texture.replace(region: MTLRegionMake2D(0, 0, atlas.width, atlas.height), mipmapLevel: 0,
                                withBytes: atlas.pixels, bytesPerRow: atlas.width * atlas.format.bytesPerPixel)
                textures[key] = texture
                contentGenerations[key] = atlas.contentGeneration
                if list == .mono {
                    _ = atlases[atlasKey]?.mono.takeDirty()
                } else {
                    _ = atlases[atlasKey]?.color?.takeDirty()
                }
            }
        }
        textures = textures.filter { live.contains($0.key) }
        contentGenerations = contentGenerations.filter { live.contains($0.key) }
        return succeeded
    }
}
#endif
