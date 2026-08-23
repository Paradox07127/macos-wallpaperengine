#if !LITE_BUILD
import CoreGraphics
import Foundation
import LiveWallpaperProWPE
import Metal
import MetalKit

// `@unchecked Sendable` so the parallel texture-resolve lane in
// `WPEMetalSceneRenderer.loadTextures` can capture the loader: all stored
// properties are thread-safe and nothing is mutated after init.
struct WPEMetalTextureLoader: @unchecked Sendable {
    private let device: MTLDevice
    private let capabilities: WPEMetalTextureCapabilities
    private let uploadQueue: WPEMetalTextureUploadQueue

    /// Corpus profile: ~47% of `.tex` assets ship a pre-baked mip chain, while
    /// the upload path historically wrote level 0 only (the decoder now inflates
    /// only what this decision selects). Builtin shaders' samplers are
    /// `constexpr` and cannot be flag-gated, so enabling the chain only benefits
    /// transpiled/custom-shader sampling. Read fresh rather than cached: uploads
    /// happen once per texture at scene load, never per frame, so this takes
    /// effect without restarting.
    static let mipChainDefaultsKey = "WPEMetalMipChainEnabled"

    /// Explicit `WPEMetalMipChainEnabled`, or nil when the user never set it.
    static var mipChainOverride: Bool? {
        UserDefaults.standard.object(forKey: mipChainDefaultsKey) != nil
            ? UserDefaults.standard.bool(forKey: mipChainDefaultsKey)
            : nil
    }

    /// Upload side. Unset defaults ON only while THIS scene actually renders
    /// scaled: scaled targets sample sources at stronger minification, and
    /// level-0-only sampling of a mip-shipping texture aliases. A scene whose
    /// plan declined gains nothing from the extra levels, so it keeps its
    /// historical level-0 upload.
    static func uploadsMipChain(scalingActive: Bool) -> Bool {
        mipChainOverride ?? scalingActive
    }

    /// Sampler side, deliberately more permissive than the upload side: a
    /// texture with a single level samples level 0 whatever the mip filter says,
    /// so allowing trilinear costs nothing on a scene that uploaded no chain.
    /// It must NOT depend on the per-scene plan — `customSamplerStateCache`
    /// survives reloads, so a plan-dependent descriptor would leak one scene's
    /// filtering into the next.
    static var allowsMipFiltering: Bool {
        mipChainOverride ?? WPEMetalFXSpatialUpscaler.isExperimentEnabled
    }

    /// First mip level worth uploading under a render-scale cap: the SMALLEST
    /// decoded level that still covers `maxEdge` on its longest side (levels are
    /// ordered largest-first). Never scales UP — if even level 0 is below the
    /// cap, level 0 stays. nil/degenerate caps keep level 0 (bit-identical path).
    static func uploadMipStartIndex(mipmaps: [WPETexTextureMipmap], maxEdge: Int?) -> Int {
        WPETexMipInflateScope.startLevel(
            levelSizes: mipmaps.map { (width: $0.width, height: $0.height) },
            maxEdge: maxEdge
        )
    }

    /// Decode-side twin of the upload decision below: hand this to the decoder
    /// so it only inflates the levels this upload will read.
    static func mipInflateScope(maxSourceEdge: Int?) -> WPETexMipInflateScope {
        WPETexMipInflateScope(
            maxSourceEdge: maxSourceEdge,
            uploadsChain: uploadsMipChain(scalingActive: maxSourceEdge != nil)
        )
    }

    init(
        device: MTLDevice,
        capabilities: WPEMetalTextureCapabilities? = nil,
        uploadQueue: WPEMetalTextureUploadQueue = .shared
    ) {
        self.device = device
        self.capabilities = capabilities ?? WPEMetalTextureCapabilities(device: device)
        self.uploadQueue = uploadQueue
    }

    /// `maxSourceEdge`: when set (static scene-layer textures under MetalFX
    /// render scaling), the upload starts at the smallest decoded mip level that
    /// still covers it, instead of always paying level-0 VRAM. Callers whose
    /// consumers do math on PHYSICAL texture dimensions (particle sprite grids,
    /// animation atlases) must leave it nil.
    func makeTexture(
        from payload: WPETexTexturePayload,
        label: String,
        colorSpace: WPEMetalColorSpace = .sRGB,
        maxSourceEdge: Int? = nil
    ) async throws -> MTLTexture {
        try Task.checkCancellation()
        if payload.videoPayload != nil {
            throw WPEMetalTextureLoaderError.malformedPayload(
                "video payload must be routed through WPEVideoTextureSource"
            )
        }
        if payload.animationTrack != nil {
            throw WPEMetalTextureLoaderError.malformedPayload(
                "animated payload must be routed through WPETexAnimatedTextureSource"
            )
        }
        let device = self.device
        let capabilities = self.capabilities
        return try await uploadQueue.perform {
            try Self.makeTextureSynchronously(
                from: payload,
                label: label,
                device: device,
                capabilities: capabilities,
                colorSpace: colorSpace,
                maxSourceEdge: maxSourceEdge
            )
        }
    }

    /// Lazy LZ4 streaming source for multi-frame `.tex` animations that
    /// would otherwise saturate VRAM if every frame were pre-uploaded.
    /// See `WPETexLazyAnimatedTextureSource` for the on-demand decode +
    /// sub-rect crop + rotating-texture rationale.
    // Not `@MainActor`: called on the renderer's actor.
    func makeLazyAnimatedTextureSource(
        from payload: WPETexStreamingPayload,
        label: String
    ) throws -> WPETexLazyAnimatedTextureSource {
        try WPETexLazyAnimatedTextureSource(payload: payload, device: device, label: label)
    }

    /// **Invariant**: one MTLTexture per unique `imageID` (the whole atlas),
    /// not per-frame sub-rect. The particle renderer's sprite-grid math
    /// (`parseParticleSpriteSheet`) divides atlas pixel dims by `.tex-json`
    /// sprite frame dims to recover `cols/rows` — so frames must reference
    /// the full atlas. Sub-rect metadata is retained on
    /// `WPETexAnimatedFrame.sourceSubRect` for shader-aware consumers
    /// (sprite-sheet background passes).
    // Not `@MainActor`: called on the renderer's actor.
    func makeAnimatedTextureSource(
        from payload: WPETexTexturePayload,
        label: String
    ) async throws -> WPETexAnimatedTextureSource {
        guard let animation = payload.animationTrack else {
            throw WPEMetalTextureLoaderError.malformedPayload("missing animation track")
        }

        // Dedup atlas uploads by imageID — mirrors makeAnimationTrack's
        // mipmapsByImageID cache. Frames sharing a source image reuse
        // the same MTLTexture instead of paying for redundant uploads.
        var atlasTextures: [Int: MTLTexture] = [:]
        var frames: [WPETexAnimatedFrame] = []
        frames.reserveCapacity(animation.frames.count)
        for (frameIndex, frame) in animation.frames.enumerated() {
            try Task.checkCancellation()
            guard let atlasMip = frame.mipmaps.first else {
                throw WPEMetalTextureLoaderError.malformedPayload(
                    "animation frame \(frameIndex) is missing its source atlas mipmap"
                )
            }
            let texture: MTLTexture
            if let cached = atlasTextures[frame.imageID] {
                texture = cached
            } else {
                let framePayload = WPETexTexturePayload(
                    info: payload.info,
                    mipmaps: [atlasMip],
                    hasAnimationFrames: false
                )
                texture = try await makeTexture(
                    from: framePayload,
                    label: "\(label) image \(frame.imageID)"
                )
                atlasTextures[frame.imageID] = texture
            }
            frames.append(WPETexAnimatedFrame(
                texture: texture,
                sourceSubRect: frame.subRect,
                duration: frame.duration
            ))
        }

        return WPETexAnimatedTextureSource(
            frames: frames,
            frameRate: animation.frameRate,
            loop: animation.loop
        )
    }

    /// Same `maxSourceEdge` contract as the payload overload. Raster decode
    /// already thumbnails to the cap when the resolver is given one; this
    /// downsample is the fallback if that path still handed us a larger image.
    /// A failed resample (exotic color space) keeps the original — never fatal.
    ///
    /// `sourcePixelSize` is the asset's FULL-resolution size, which the caller
    /// must supply whenever `cgImage` may already be a capped decode: world
    /// layout reads it back from the registry, so recording the reduced size
    /// there lays the layer out at a fraction of its authored footprint.
    func makeTexture(
        from cgImage: CGImage,
        label: String,
        colorSpace: WPEMetalColorSpace = .sRGB,
        maxSourceEdge: Int? = nil,
        sourcePixelSize: (width: Int, height: Int)? = nil
    ) async throws -> MTLTexture {
        try Task.checkCancellation()
        let device = self.device
        return try await uploadQueue.perform {
            let upload = maxSourceEdge.flatMap { Self.downsampledImage(cgImage, maxEdge: $0) } ?? cgImage
            let loader = MTKTextureLoader(device: device)
            do {
                let texture = try loader.newTexture(
                    cgImage: upload,
                    options: [
                        MTKTextureLoader.Option.SRGB: colorSpace == .sRGB,
                        MTKTextureLoader.Option.textureUsage: MTLTextureUsage.shaderRead.rawValue
                    ]
                )
                texture.label = label
                WPEMetalTextureMetadataRegistry.shared.register(
                    texture: texture,
                    imageWidth: upload.width,
                    imageHeight: upload.height,
                    worldWidth: sourcePixelSize?.width ?? cgImage.width,
                    worldHeight: sourcePixelSize?.height ?? cgImage.height
                )
                return texture
            } catch {
                throw WPEMetalTextureLoaderError.malformedPayload(error.localizedDescription)
            }
        }
    }

    static func downsampledImage(_ image: CGImage, maxEdge: Int) -> CGImage? {
        let longest = max(image.width, image.height)
        // Strip-shaped images (LUTs/gradients) index by texel — never resample.
        guard maxEdge > 0, longest > maxEdge, min(image.width, image.height) > 64 else { return nil }
        let ratio = Double(maxEdge) / Double(longest)
        let width = max(Int((Double(image.width) * ratio).rounded()), 1)
        let height = max(Int((Double(image.height) * ratio).rounded()), 1)
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)
        guard let space,
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// RG88 is sampled as LUMINANCE_ALPHA (R,R,R,G) for particle glow sprites — but the
    /// shake effect stores its flow masks as RG88 too, with R = x-displacement and G =
    /// y-displacement. Swizzling those collapses `.g` onto `.r`, destroying the y-flow so
    /// the whole composited frame is displaced (full-screen tearing / criss-cross lines,
    /// not the masked-region motion). Flow/data masks live under `masks/` (`shake_mask_*`);
    /// glow sprites never do, so the path name is the reliable discriminator.
    static func rg88NeedsLuminanceAlphaSwizzle(isLuminanceAlpha: Bool, label: String) -> Bool {
        guard isLuminanceAlpha else { return false }
        return !label.lowercased().contains("mask")
    }

    private static func makeTextureSynchronously(
        from payload: WPETexTexturePayload,
        label: String,
        device: MTLDevice,
        capabilities: WPEMetalTextureCapabilities,
        colorSpace: WPEMetalColorSpace = .sRGB,
        maxSourceEdge: Int? = nil
    ) throws -> MTLTexture {
        guard let format = payload.info.format else {
            throw WPEMetalTextureLoaderError.malformedPayload("unknown texture format \(payload.info.textureFormatCode)")
        }
        guard let level0 = payload.largestMipmap else {
            throw WPEMetalTextureLoaderError.malformedPayload("missing mipmap")
        }
        // Render-scale cap: start the upload at the smallest decoded level that
        // still covers the scaled scene output. Levels above it are simply not
        // uploaded — that skipped level 0 is ~75% of the chain's bytes.
        // Data textures are exempt: nearest-sampled (noInterpolation) content and
        // strip-shaped textures (a 4096×1 LUT) index by texel, and minifying them
        // collapses distinct entries.
        let isDataTexture = payload.info.noInterpolation
            || min(level0.width, level0.height) <= 64
        let startLevel = isDataTexture
            ? 0
            : uploadMipStartIndex(mipmaps: payload.mipmaps, maxEdge: maxSourceEdge)
        let selectedMipmaps = Array(payload.mipmaps.dropFirst(startLevel))
        guard let mip = selectedMipmaps.first else {
            throw WPEMetalTextureLoaderError.malformedPayload("missing mipmap")
        }

        let mapping = try WPEMetalTextureFormatMapper.mapping(
            for: format, capabilities: capabilities, colorSpace: colorSpace)
        // Only the level-0 payload is guaranteed present; a real chain needs
        // more than one decoded level before the flag has anything to do.
        // `allSatisfy` covers the one way the decoder's scope can disagree with
        // this decision: `mipChainOverride` is read fresh on both sides, so a
        // user flipping it mid-load leaves levels without bytes. Upload the one
        // level we do have instead of failing the texture.
        let mipChainEligible = Self.uploadsMipChain(scalingActive: maxSourceEdge != nil)
            && selectedMipmaps.count > 1
            && selectedMipmaps.allSatisfy { !$0.bytes.isEmpty }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: mapping.pixelFormat,
            width: mip.width,
            height: mip.height,
            mipmapped: mipChainEligible
        )
        if mipChainEligible {
            // The container's chain may be shorter than the full log2 chain
            // `mipmapped: true` would otherwise imply — bound it to exactly
            // the levels we have decoded bytes for.
            descriptor.mipmapLevelCount = selectedMipmaps.count
        }
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        // RG88 particle glow sprites sample as LUMINANCE_ALPHA → (R, R, R, G): R
        // luminance broadcast, G alpha falloff (raw `.rg8Unorm` samples (R, G, 0, 1),
        // rendering opaque — the "red square light" / red-line fog artifacts).
        if Self.rg88NeedsLuminanceAlphaSwizzle(isLuminanceAlpha: payload.info.isRG88LuminanceAlpha, label: label) {
            descriptor.swizzle = MTLTextureSwizzleChannels(red: .red, green: .red, blue: .red, alpha: .green)
        }

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw WPEMetalTextureLoaderError.textureAllocationFailed
        }
        texture.label = label
        // Logical (image) dims describe the UPLOADED level so the shader UV
        // crop ratio image/texture stays level-consistent; the authored size
        // goes into worldWidth/Height for world-layout consumers.
        let authoredImageWidth = payload.info.imageWidth > 0 ? payload.info.imageWidth : level0.width
        let authoredImageHeight = payload.info.imageHeight > 0 ? payload.info.imageHeight : level0.height
        let levelImageWidth = startLevel == 0
            ? authoredImageWidth
            : max(Int((Double(authoredImageWidth) * Double(mip.width) / Double(max(level0.width, 1))).rounded()), 1)
        let levelImageHeight = startLevel == 0
            ? authoredImageHeight
            : max(Int((Double(authoredImageHeight) * Double(mip.height) / Double(max(level0.height, 1))).rounded()), 1)
        WPEMetalTextureMetadataRegistry.shared.register(
            texture: texture,
            imageWidth: levelImageWidth,
            imageHeight: levelImageHeight,
            clampUVs: payload.info.clampUVs,
            noInterpolation: payload.info.noInterpolation,
            // Level-0 PHYSICAL dims, not the authored image dims: the world
            // fallback replaces a direct `texture.width` read in the quad path,
            // which historically saw the padded physical size — keeping that
            // exact value is what makes scale=1 bit-identical.
            worldWidth: level0.width,
            worldHeight: level0.height
        )

        for (uploadLevel, level) in selectedMipmaps.enumerated() {
            if uploadLevel > 0, !mipChainEligible { break }
            let levelExpected = format.expectedByteCount(width: level.width, height: level.height)
            guard level.bytes.count >= levelExpected else {
                throw WPEMetalTextureLoaderError.malformedPayload(
                    "mip bytes \(level.bytes.count) smaller than expected \(levelExpected) (level \(level.index))"
                )
            }
            let levelBytesPerRow = try Self.bytesPerRow(width: level.width, mapping: mapping)
            try level.bytes.withUnsafeBytes { raw in
                guard let baseAddress = raw.baseAddress else {
                    throw WPEMetalTextureLoaderError.malformedPayload(
                        "Empty mipmap bytes baseAddress (level \(level.index))"
                    )
                }
                texture.replace(
                    region: MTLRegionMake2D(0, 0, level.width, level.height),
                    mipmapLevel: uploadLevel,
                    withBytes: baseAddress,
                    bytesPerRow: levelBytesPerRow
                )
            }
        }
        return texture
    }

    private static func bytesPerRow(width: Int, mapping: WPEMetalTextureFormatMapping) throws -> Int {
        if let bytesPerPixel = mapping.bytesPerPixel {
            return width * bytesPerPixel
        }
        if let bytesPerBlock = mapping.bytesPerBlock {
            return max((width + 3) / 4, 1) * bytesPerBlock
        }
        throw WPEMetalTextureLoaderError.malformedPayload("missing row-stride information")
    }
}
#endif
