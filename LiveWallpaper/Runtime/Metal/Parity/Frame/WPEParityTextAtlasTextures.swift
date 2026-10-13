#if !LITE_BUILD
import LiveWallpaperProWPE
import Metal

/// The text layers' glyph atlases and one unmipped texture per atlas key and list: R8Unorm for grey glyphs,
/// RGBA8Unorm for colour glyphs (R23 Q4).
struct WPEParityTextAtlasTextures {
    struct Key: Hashable {
        let atlasKey: String
        let atlas: WPEParityGlyphAtlasInstance.Atlas
    }

    /// The CPU atlases; an atlas is clean once its pixels are in its texture.
    private(set) var atlases: [String: WPEParityGlyphAtlasInstance]
    private(set) var textures: [Key: MTLTexture] = [:]

    init(atlases: [String: WPEParityGlyphAtlasInstance]) {
        self.atlases = atlases
    }

    /// Takes `atlases` as a re-layout left them and uploads the ones that are new, resized or dirty.
    mutating func replace(_ atlases: [String: WPEParityGlyphAtlasInstance], device: MTLDevice) {
        self.atlases = atlases
        upload(device: device)
    }

    /// Makes the textures that are missing or no longer match their atlas size and uploads each new texture's or
    /// dirty atlas's pixels whole, as WPE does before a draw (1401b3430.c:133-144, :187-202).
    mutating func upload(device: MTLDevice) {
        for (atlasKey, instance) in atlases {
            let lists: [(WPEParityGlyphAtlasInstance.Atlas, WPEParityGlyphAtlas?)] = [
                (.mono, instance.mono), (.color, instance.color),
            ]
            for case let (list, atlas?) in lists {
                let key = Key(atlasKey: atlasKey, atlas: list)
                var texture = textures[key]
                let stale = texture.map { $0.width != atlas.width || $0.height != atlas.height } ?? true
                if stale {
                    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                        pixelFormat: atlas.format == .r8 ? .r8Unorm : .rgba8Unorm, width: atlas.width,
                        height: atlas.height, mipmapped: false
                    )
                    descriptor.usage = .shaderRead
                    texture = device.makeTexture(descriptor: descriptor)
                    texture?.label = "\(atlasKey) \(list)"
                    textures[key] = texture
                }
                guard let texture, stale || atlas.isDirty else { continue }
                texture.replace(region: MTLRegionMake2D(0, 0, atlas.width, atlas.height), mipmapLevel: 0,
                                withBytes: atlas.pixels, bytesPerRow: atlas.width * atlas.format.bytesPerPixel)
                if list == .mono {
                    _ = atlases[atlasKey]?.mono.takeDirty()
                } else {
                    _ = atlases[atlasKey]?.color?.takeDirty()
                }
            }
        }
    }
}
#endif
