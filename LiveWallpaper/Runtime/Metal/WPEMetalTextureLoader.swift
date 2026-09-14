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

    static let mipChainDefaultsKey = "WPEMetalMipChainEnabled"

    static var mipChainOverride: Bool? {
        UserDefaults.standard.object(forKey: mipChainDefaultsKey) != nil
            ? UserDefaults.standard.bool(forKey: mipChainDefaultsKey)
            : nil
    }

    /// Unset defaults ON only while this scene renders scaled: level-0-only sampling of a mip-shipping texture aliases under minification.
    static func uploadsMipChain(scalingActive: Bool) -> Bool {
        mipChainOverride ?? scalingActive
    }

    /// Must not depend on the per-scene plan: `customSamplerStateCache` survives reloads, so a plan-dependent descriptor would leak one scene's filtering into the next.
    static var allowsMipFiltering: Bool {
        mipChainOverride ?? WPEMetalFXSpatialUpscaler.isExperimentEnabled
    }

    /// Smallest decoded level that still covers `maxEdge` on its longest side (levels are largest-first). Never scales up; nil/degenerate caps keep level 0.
    static func uploadMipStartIndex(mipmaps: [WPETexTextureMipmap], maxEdge: Int?) -> Int {
        WPETexMipInflateScope.startLevel(
            levelSizes: mipmaps.map { (width: $0.width, height: $0.height) },
            maxEdge: maxEdge
        )
    }

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

    /// `maxSourceEdge`: when set, upload starts at the smallest decoded mip that still covers it. Callers that do math on physical texture dimensions (particle sprite grids, animation atlases) must leave it nil.
    func makeTexture(
        from payload: WPETexTexturePayload,
        label: String,
        colorSpace: WPEMetalColorSpace = .sRGB,
        maxSourceEdge: Int? = nil,
        preserveMipmaps: Bool = false
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
                maxSourceEdge: maxSourceEdge,
                preserveMipmaps: preserveMipmaps
            )
        }
    }

    func makeLazyAnimatedTextureSource(
        from payload: WPETexStreamingPayload,
        label: String,
        colorSpace: WPEMetalColorSpace = .sRGB
    ) throws -> WPETexLazyAnimatedTextureSource {
        try WPETexLazyAnimatedTextureSource(payload: payload, device: device, label: label, colorSpace: colorSpace)
    }

    /// One MTLTexture per unique `imageID` (the whole atlas), not per-frame sub-rect: sprite-grid math divides atlas pixel dims by `.tex-json` frame dims to recover cols/rows.
    func makeAnimatedTextureSource(
        from payload: WPETexTexturePayload,
        label: String,
        colorSpace: WPEMetalColorSpace = .sRGB
    ) async throws -> WPETexAnimatedTextureSource {
        guard let animation = payload.animationTrack else {
            throw WPEMetalTextureLoaderError.malformedPayload("missing animation track")
        }

        var atlasTextures: [Int: MTLTexture] = [:]
        var frames: [WPETexAnimatedFrame] = []
        frames.reserveCapacity(animation.frames.count)
        for (frameIndex, frame) in animation.frames.enumerated() {
            try Task.checkCancellation()
            guard !frame.mipmaps.isEmpty else {
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
                    mipmaps: frame.mipmaps,
                    hasAnimationFrames: false
                )
                texture = try await makeTexture(
                    from: framePayload,
                    label: "\(label) image \(frame.imageID)",
                    colorSpace: colorSpace,
                    preserveMipmaps: true
                )
                atlasTextures[frame.imageID] = texture
            }
            frames.append(WPETexAnimatedFrame(
                texture: texture,
                sourceSubRect: frame.subRect,
                duration: frame.duration,
                samplingDescriptor: frame.samplingDescriptor
            ))
        }

        return WPETexAnimatedTextureSource(
            frames: frames,
            frameRate: animation.frameRate,
            loop: animation.loop
        )
    }

    /// `sourcePixelSize` is the asset's full-resolution size; supply it whenever `cgImage` may already be a capped decode (world layout reads it from the registry).
    /// Failed resample (exotic color space) keeps the original — never fatal.
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

    /// RG88 luminance-alpha swizzle is for particle glow (R,R,R,G). Shake flow masks are also RG88 (R=x, G=y) — swizzling would collapse y-flow. Discriminator: `masks/` in the path.
    static func rg88NeedsLuminanceAlphaSwizzle(isLuminanceAlpha: Bool, label: String) -> Bool {
        guard isLuminanceAlpha else { return false }
        return !label.lowercased().contains("mask")
    }

    static func makeTextureSynchronously(
        from payload: WPETexTexturePayload,
        label: String,
        device: MTLDevice,
        capabilities: WPEMetalTextureCapabilities,
        colorSpace: WPEMetalColorSpace = .sRGB,
        maxSourceEdge: Int? = nil,
        preserveMipmaps: Bool = false
    ) throws -> MTLTexture {
        guard let format = payload.info.format else {
            throw WPEMetalTextureLoaderError.malformedPayload("unknown texture format \(payload.info.textureFormatCode)")
        }
        guard let level0 = payload.largestMipmap else {
            throw WPEMetalTextureLoaderError.malformedPayload("missing mipmap")
        }
        // Data textures (noInterpolation / strip-shaped, min edge ≤64) are exempt: they index by texel, and minifying collapses distinct entries.
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
        // `allSatisfy` covers decoder/upload disagreeing: `mipChainOverride` is read fresh on both sides, so a mid-load flip can leave levels without bytes — upload the one level we have rather than failing.
        let mipChainEligible = (preserveMipmaps || Self.uploadsMipChain(scalingActive: maxSourceEdge != nil))
            && selectedMipmaps.count > 1
            && selectedMipmaps.allSatisfy { !$0.bytes.isEmpty }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: mapping.pixelFormat,
            width: mip.width,
            height: mip.height,
            mipmapped: mipChainEligible
        )
        if mipChainEligible {
            // The container's chain may be shorter than the full log2 chain `mipmapped: true` would imply — bound `mipmapLevelCount` to the levels we have decoded bytes for.
            descriptor.mipmapLevelCount = selectedMipmaps.count
        }
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        // RG88 glow sprites: luminance-alpha swizzle (R,R,R,G). Raw `.rg8Unorm` samples (R,G,0,1) and renders opaque.
        if Self.rg88NeedsLuminanceAlphaSwizzle(isLuminanceAlpha: payload.info.isRG88LuminanceAlpha, label: label) {
            descriptor.swizzle = MTLTextureSwizzleChannels(red: .red, green: .red, blue: .red, alpha: .green)
        }

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw WPEMetalTextureLoaderError.textureAllocationFailed
        }
        texture.label = label
        // Logical (image) dims describe the uploaded level so the shader UV crop ratio image/texture stays level-consistent; authored size goes to worldWidth/Height.
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
            // worldWidth/Height are level-0 physical dims (not authored image dims): the quad path's world fallback historically saw the padded physical size; that exact value keeps scale=1 bit-identical.
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
