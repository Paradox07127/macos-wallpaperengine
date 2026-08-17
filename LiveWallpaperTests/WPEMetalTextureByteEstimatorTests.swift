#if !LITE_BUILD
import Foundation
import Metal
import Testing
@testable import LiveWallpaper

@Suite("WPE Metal texture byte estimator")
struct WPEMetalTextureByteEstimatorTests {
    @Test("BC3 counts compressed blocks, not pixels")
    func bc3BlockMath() {
        // 4096x4096 bc3 = 1024x1024 blocks x 16 bytes = 16 MiB (not the 64 MiB
        // the old per-pixel census math reported).
        #expect(WPEMetalTextureByteEstimator.estimatedBytes(
            pixelFormat: .bc3_rgba,
            width: 4096,
            height: 4096
        ) == 16_777_216)
    }

    @Test("Full mip chain is the exact per-level sum with block rounding")
    func bc3FullMipChain() {
        // 4096 -> 1 is 13 levels; per-level block counts hand-derived from
        // max((dim + 3) / 4, 1). Sub-4px tails still occupy one block per axis.
        let blockCounts = [1024, 512, 256, 128, 64, 32, 16, 8, 4, 2, 1, 1, 1]
        let expected = blockCounts.map { $0 * $0 * 16 }.reduce(0, +)
        #expect(expected == 22_369_648)
        #expect(WPEMetalTextureByteEstimator.estimatedBytes(
            pixelFormat: .bc3_rgba,
            width: 4096,
            height: 4096,
            mipmapLevelCount: 13
        ) == expected)
    }

    @Test("Odd dimensions round up to whole blocks")
    func oddDimensionBlockRounding() {
        #expect(WPEMetalTextureByteEstimator.estimatedBytes(
            pixelFormat: .bc3_rgba,
            width: 5,
            height: 5
        ) == 2 * 2 * 16)
    }

    @Test("BC1 is half of BC3 at the same size")
    func bc1HalfOfBC3() {
        let bc1 = WPEMetalTextureByteEstimator.estimatedBytes(
            pixelFormat: .bc1_rgba,
            width: 4096,
            height: 4096
        )
        let bc3 = WPEMetalTextureByteEstimator.estimatedBytes(
            pixelFormat: .bc3_rgba,
            width: 4096,
            height: 4096
        )
        #expect(bc1 == 8_388_608)
        #expect(bc3 == bc1 * 2)
    }

    @Test("Uncompressed formats bill per pixel")
    func uncompressedPerPixel() {
        #expect(WPEMetalTextureByteEstimator.estimatedBytes(
            pixelFormat: .rgba8Unorm,
            width: 4096,
            height: 4096
        ) == 67_108_864)
        #expect(WPEMetalTextureByteEstimator.estimatedBytes(
            pixelFormat: .r8Unorm,
            width: 1024,
            height: 1024
        ) == 1_048_576)
    }

    @Test("Cube and array multiply the slice footprint")
    func cubeAndArraySlices() {
        #expect(WPEMetalTextureByteEstimator.estimatedBytes(
            pixelFormat: .rgba8Unorm,
            width: 512,
            height: 512,
            isCube: true
        ) == 512 * 512 * 4 * 6)
        #expect(WPEMetalTextureByteEstimator.estimatedBytes(
            pixelFormat: .bc3_rgba,
            width: 4096,
            height: 4096,
            arrayLength: 3
        ) == 16_777_216 * 3)
    }

    @Test("Every memory tier ships a bounded texture-cache budget")
    func everyTierIsBounded() {
        for tier in WPEMemoryTier.allCases {
            #expect(tier.defaultTextureCacheBudgetBytes != nil)
        }
        #expect(WPEMemoryTier.expansive.defaultTextureCacheBudgetBytes == 768 * 1_048_576)
    }
}
#endif
