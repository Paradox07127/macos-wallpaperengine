#if !LITE_BUILD
import Foundation
import Metal

/// Single estimator for GPU texture footprints, shared by the texture-cache LRU
/// (`WPEMetalSceneRenderer.textureResidentBytes`) and the memory-audit census
/// (`WPEMetalTextureMetadataRegistry`). The two previously used different math
/// — the census billed BC-compressed textures at uncompressed rates (4-6x
/// over), so its numbers could not explain what the LRU was budgeting.
enum WPEMetalTextureByteEstimator {
    static func estimatedBytes(of texture: MTLTexture) -> Int {
        estimatedBytes(
            pixelFormat: texture.pixelFormat,
            width: texture.width,
            height: texture.height,
            mipmapLevelCount: texture.mipmapLevelCount,
            arrayLength: texture.arrayLength,
            isCube: texture.textureType == .typeCube || texture.textureType == .typeCubeArray
        )
    }

    /// Descriptor-shaped overload so estimates (and tests) need no MTLDevice.
    /// For cube arrays `arrayLength` counts cubes, so the x6 face factor stacks.
    static func estimatedBytes(
        pixelFormat: MTLPixelFormat,
        width: Int,
        height: Int,
        mipmapLevelCount: Int = 1,
        arrayLength: Int = 1,
        isCube: Bool = false
    ) -> Int {
        var sliceBytes = 0
        for level in 0..<max(mipmapLevelCount, 1) {
            sliceBytes += levelBytes(
                pixelFormat: pixelFormat,
                width: max(width >> level, 1),
                height: max(height >> level, 1)
            )
        }
        return sliceBytes * max(arrayLength, 1) * (isCube ? 6 : 1)
    }

    private static func levelBytes(pixelFormat: MTLPixelFormat, width: Int, height: Int) -> Int {
        switch pixelFormat {
        // BC stays compressed in VRAM; per-pixel math would 4-6x over-count.
        case .bc1_rgba, .bc1_rgba_srgb:
            return blockCount(width) * blockCount(height) * 8
        case .bc2_rgba, .bc2_rgba_srgb, .bc3_rgba, .bc3_rgba_srgb,
             .bc7_rgbaUnorm, .bc7_rgbaUnorm_srgb:
            return blockCount(width) * blockCount(height) * 16
        default:
            return width * height * bytesPerPixel(for: pixelFormat)
        }
    }

    /// Mip levels below 4px still occupy one full 4x4 block per axis.
    private static func blockCount(_ dimension: Int) -> Int {
        max((dimension + 3) / 4, 1)
    }

    private static func bytesPerPixel(for pixelFormat: MTLPixelFormat) -> Int {
        switch pixelFormat {
        case .rgba32Float: return 16
        case .rgba16Float, .rg32Float: return 8
        case .rgba8Unorm, .rgba8Unorm_srgb, .bgra8Unorm, .bgra8Unorm_srgb, .r32Float, .rg16Float:
            return 4
        case .rg8Unorm, .r16Float, .r16Unorm: return 2
        case .r8Unorm: return 1
        // Unknown formats fall back to 4 B/px: over-estimates most remaining
        // formats, so the LRU errs toward evicting rather than over-retaining.
        default: return 4
        }
    }
}
#endif
