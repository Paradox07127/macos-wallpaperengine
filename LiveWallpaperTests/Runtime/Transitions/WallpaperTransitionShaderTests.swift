@testable import LiveWallpaper
import Metal
import Testing

@Suite("Wallpaper transition shaders", .serialized)
@MainActor
struct WallpaperTransitionShaderTests {
    private static let width = 256
    private static let height = 144

    private static let variants: [(seed: Float, origin: SIMD2<Float>)] = [
        (0.37, SIMD2(0.4, 0.6)),
        (0.81, SIMD2(0.7, 0.25)),
    ]

    private struct AlphaStats: CustomStringConvertible {
        let alphas: [Float]
        var min: Float {
            alphas.min() ?? .nan
        }

        var max: Float {
            alphas.max() ?? .nan
        }

        var mean: Float {
            alphas.reduce(0, +) / Float(alphas.count)
        }

        var kept: Int {
            alphas.count { $0 >= 0.9 }
        }

        var cut: Int {
            alphas.count { $0 <= 0.1 }
        }

        var description: String {
            String(format: "min %.3f max %.3f mean %.3f, >=0.9: %d, <=0.1: %d of %d", min, max, mean, kept, cut, alphas.count)
        }
    }

    private func render(
        _ pass: WallpaperTransitionRenderer.Pass,
        _ effect: WallpaperRevealEffect,
        progress: Float,
        variant: (seed: Float, origin: SIMD2<Float>)
    ) throws -> AlphaStats {
        let renderer = try #require(WallpaperTransitionRenderer.shared, "no Metal device or transition shaders in the app's library")
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: WallpaperTransitionRenderer.pixelFormat,
            width: Self.width,
            height: Self.height,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = .shared
        let texture = try #require(renderer.device.makeTexture(descriptor: descriptor))
        let uniforms = WallpaperTransitionUniforms(
            progress: progress,
            time: 0,
            aspect: Float(Self.width) / Float(Self.height),
            seed: variant.seed,
            origin: variant.origin
        )
        let commandBuffer = try #require(renderer.render(pass, effect: effect, uniforms: uniforms, to: texture))
        commandBuffer.waitUntilCompleted()
        #expect(commandBuffer.status == .completed)
        var bytes = [UInt8](repeating: 0, count: Self.width * Self.height * 4)
        texture.getBytes(&bytes, bytesPerRow: Self.width * 4, from: MTLRegionMake2D(0, 0, Self.width, Self.height), mipmapLevel: 0)
        let alphas = stride(from: 3, to: bytes.count, by: 4).map { Float(bytes[$0]) / 255 }
        return AlphaStats(alphas: alphas)
    }

    @Test("Every mask keeps the old wallpaper at 0, is mid-reveal at 0.5 and cuts it all away at 1",
          arguments: WallpaperRevealEffect.allCases)
    func maskSpansTheWholeReveal(effect: WallpaperRevealEffect) throws {
        for variant in Self.variants {
            let start = try render(.mask, effect, progress: 0, variant: variant)
            let middle = try render(.mask, effect, progress: 0.5, variant: variant)
            let end = try render(.mask, effect, progress: 1, variant: variant)
            print("[transition-mask] \(effect.rawValue) seed \(variant.seed): p0 {\(start)} p0.5 {\(middle)} p1 {\(end)}")
            #expect(start.min >= 0.99, "\(effect.rawValue) p=0 already cuts into the old wallpaper: \(start)")
            #expect(end.max <= 0.01, "\(effect.rawValue) p=1 leaves part of the old wallpaper: \(end)")
            #expect(middle.kept > 0 && middle.cut > 0, "\(effect.rawValue) p=0.5 is not mid-reveal: \(middle)")
        }
    }

    @Test("Every light overlay is fully transparent at the start and the end",
          arguments: WallpaperRevealEffect.allCases.filter { $0.lightFunctionName != nil })
    func lightIsClearAtTheEnds(effect: WallpaperRevealEffect) throws {
        for variant in Self.variants {
            let start = try render(.light, effect, progress: 0, variant: variant)
            let end = try render(.light, effect, progress: 1, variant: variant)
            let middle = try render(.light, effect, progress: 0.3, variant: variant)
            print("[transition-light] \(effect.rawValue) seed \(variant.seed): p0 {\(start)} p0.3 {\(middle)} p1 {\(end)}")
            #expect(start.max == 0, "\(effect.rawValue) light shows at p=0: \(start)")
            #expect(end.max == 0, "\(effect.rawValue) light shows at p=1: \(end)")
            #expect(middle.max > 0.1, "\(effect.rawValue) light never draws: \(middle)")
        }
    }
}
