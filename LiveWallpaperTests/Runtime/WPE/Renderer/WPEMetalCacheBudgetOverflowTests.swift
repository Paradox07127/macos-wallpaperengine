import Foundation
@testable import LiveWallpaper
import Testing

/// Both MiB knobs multiply a user-supplied Int by 1,048,576; an unchecked product traps.
@MainActor
@Suite("WPE Metal cache budget MiB to bytes overflow")
struct WPEMetalCacheBudgetOverflowTests {
    private static let mib = 1_048_576
    private static let largestFittingMiB = Int.max / mib

    @Test("Texture cache budget: an overflowing MiB value is invalid, so nil")
    func textureCacheBudgetOverflowResolvesToNil() {
        for tier in [WPEMemoryTier.constrained, .standard, .expansive] {
            #expect(WPEMetalSceneRenderer.resolvedTextureCacheBudgetBytes(manualValue: Int.max, tier: tier) == nil)
            #expect(WPEMetalSceneRenderer.resolvedTextureCacheBudgetBytes(
                manualValue: Self.largestFittingMiB + 1, tier: tier
            ) == nil)
            #expect(WPEMetalSceneRenderer.resolvedTextureCacheBudgetBytes(
                manualValue: Self.largestFittingMiB, tier: tier
            ) == Self.largestFittingMiB * Self.mib)
            #expect(WPEMetalSceneRenderer.resolvedTextureCacheBudgetBytes(manualValue: 0, tier: tier) == nil)
            #expect(WPEMetalSceneRenderer.resolvedTextureCacheBudgetBytes(manualValue: -1, tier: tier) == nil)
            #expect(WPEMetalSceneRenderer.resolvedTextureCacheBudgetBytes(manualValue: Int.min, tier: tier) == nil)
            #expect(WPEMetalSceneRenderer.resolvedTextureCacheBudgetBytes(manualValue: 64, tier: tier)
                == 64 * Self.mib)
        }
    }

    @Test("Static layer cache budget: an overflowing MiB value falls back to the 256 MiB default")
    func staticLayerCacheBudgetOverflowFallsBackToDefault() {
        let fallback = 256 * Self.mib
        #expect(WPEMetalRenderExecutor.resolvedStaticLayerCacheBudgetBytes(mib: Int.max) == fallback)
        #expect(WPEMetalRenderExecutor.resolvedStaticLayerCacheBudgetBytes(mib: Self.largestFittingMiB + 1) == fallback)
        #expect(WPEMetalRenderExecutor.resolvedStaticLayerCacheBudgetBytes(mib: Self.largestFittingMiB)
            == Self.largestFittingMiB * Self.mib)
        #expect(WPEMetalRenderExecutor.resolvedStaticLayerCacheBudgetBytes(mib: 0) == 0)
        #expect(WPEMetalRenderExecutor.resolvedStaticLayerCacheBudgetBytes(mib: -1) == 0)
        #expect(WPEMetalRenderExecutor.resolvedStaticLayerCacheBudgetBytes(mib: Int.min) == 0)
        #expect(WPEMetalRenderExecutor.resolvedStaticLayerCacheBudgetBytes(mib: 256) == fallback)
        #expect(WPEMetalRenderExecutor.resolvedStaticLayerCacheBudgetBytes(mib: 64) == 64 * Self.mib)
    }
}
