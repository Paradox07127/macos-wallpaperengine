#if !LITE_BUILD
import Foundation
import Metal
import Testing
@testable import LiveWallpaper

@Suite("WPE Metal texture byte estimator")
struct WPEMetalTextureByteEstimatorTests {
    @Test("BC3 counts compressed blocks, not pixels")
    func bc3BlockMath() {
        // 4096x4096 bc3 = 1024x1024 blocks x 16 bytes = 16 MiB.
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

    /// The static-layer cache must NOT use this estimator: it reserves from a
    /// descriptor and then rejects any snapshot over that reservation, so both
    /// sides have to be Metal's own number.
    @Test("Static-layer cache bills through Metal's own allocation size, not the estimator")
    func staticLayerCacheBillsRealAllocationSize() throws {
        let targets = try RepositoryRoot.source(
            "LiveWallpaper/Runtime/Metal/WPEMetalRenderExecutor+Targets.swift"
        )
        #expect(targets.contains("device.heapTextureSizeAndAlign(descriptor: descriptor).size"))
        #expect(targets.contains("bytes += cached.allocatedSize"))
        #expect(!targets.contains("staticLayerCacheBytesPerPixel"))
        #expect(!targets.contains("WPEMetalTextureByteEstimator"))
    }

    @Test("Estimator still owns the LRU, census and animated-texture totals")
    func estimatorRetainsItsCallers() throws {
        for path in [
            "LiveWallpaper/Runtime/Metal/WPEMetalSceneRenderer+Textures.swift",
            "LiveWallpaper/Runtime/Metal/WPEMetalTextureMetadataRegistry.swift",
            "LiveWallpaper/Runtime/Assets/WPETexAnimatedTextureSource.swift",
        ] {
            #expect(
                try RepositoryRoot.source(path).contains("WPEMetalTextureByteEstimator.estimatedBytes(of:"),
                Comment(rawValue: path)
            )
        }
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
