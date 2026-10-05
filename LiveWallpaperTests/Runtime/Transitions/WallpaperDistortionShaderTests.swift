@testable import LiveWallpaper
import Metal
import Testing

@Suite("Wallpaper distortion shaders", .serialized)
@MainActor
struct WallpaperDistortionShaderTests {
    private static let width = 256
    private static let height = 144
    private static let tolerance: Float = 1.0 / 255.0 + 1e-4

    private static let variants: [(seed: Float, origin: SIMD2<Float>)] = [
        (0.37, SIMD2(0.4, 0.6)),
        (0.81, SIMD2(1.0, 0.0)),
    ]

    private static let pixelFormats: [MTLPixelFormat] = [.bgra8Unorm, .rgba8Unorm_srgb, .rgba16Float]

    /// Red-green gradient with a 16 px checkerboard.
    private static let fromPixels: [SIMD4<Float>] = pixels { x, y in
        let checker: Float = ((x / 16 + y / 16) % 2 == 0) ? 0.25 : 0
        let u = Float(x) / Float(width - 1)
        let v = Float(y) / Float(height - 1)
        return SIMD4(0.2 + 0.55 * u + checker, 0.75 - 0.55 * v + checker, 0.1, 1)
    }

    /// Blue-yellow gradient with 6 px horizontal stripes.
    private static let toPixels: [SIMD4<Float>] = pixels { x, y in
        let stripe: Float = (y / 6) % 2 == 0 ? 0.2 : 0
        let t = Float(x + y) / Float(width + height - 2)
        return SIMD4(0.1 + 0.7 * t, 0.1 + 0.6 * t + stripe, 0.85 - 0.75 * t, 1)
    }

    private static func pixels(_ color: (Int, Int) -> SIMD4<Float>) -> [SIMD4<Float>] {
        (0 ..< height).flatMap { y in (0 ..< width).map { x in color(x, y) } }
    }

    private struct Inputs {
        let from: MTLTexture
        let to: MTLTexture
        let queue: MTLCommandQueue
    }

    private func makeInputs(_ renderer: WallpaperDistortionRenderer, format: MTLPixelFormat) throws -> Inputs {
        let from = try makeTexture(renderer.device, format: format, usage: .shaderRead)
        let to = try makeTexture(renderer.device, format: format, usage: .shaderRead)
        upload(Self.fromPixels, to: from)
        upload(Self.toPixels, to: to)
        let queue = try #require(renderer.device.makeCommandQueue())
        return Inputs(from: from, to: to, queue: queue)
    }

    private func makeTexture(_ device: MTLDevice, format: MTLPixelFormat, usage: MTLTextureUsage) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format,
            width: Self.width,
            height: Self.height,
            mipmapped: false
        )
        descriptor.usage = usage
        descriptor.storageMode = .shared
        return try #require(device.makeTexture(descriptor: descriptor))
    }

    private func upload(_ pixels: [SIMD4<Float>], to texture: MTLTexture) {
        let region = MTLRegionMake2D(0, 0, Self.width, Self.height)
        if texture.pixelFormat == .rgba16Float {
            let halves = pixels.flatMap { [Float16($0.x), Float16($0.y), Float16($0.z), Float16($0.w)] }
            halves.withUnsafeBytes { texture.replace(region: region, mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: Self.width * 8) }
        } else {
            let bgra = texture.pixelFormat == .bgra8Unorm
            let bytes = pixels.flatMap { pixel in
                (bgra ? [pixel.z, pixel.y, pixel.x, pixel.w] : [pixel.x, pixel.y, pixel.z, pixel.w])
                    .map { UInt8((min(max($0, 0), 1) * 255).rounded()) }
            }
            bytes.withUnsafeBytes { texture.replace(region: region, mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: Self.width * 4) }
        }
    }

    private func readback(_ texture: MTLTexture) -> [SIMD4<Float>] {
        let region = MTLRegionMake2D(0, 0, Self.width, Self.height)
        if texture.pixelFormat == .rgba16Float {
            var halves = [Float16](repeating: 0, count: Self.width * Self.height * 4)
            texture.getBytes(&halves, bytesPerRow: Self.width * 8, from: region, mipmapLevel: 0)
            return stride(from: 0, to: halves.count, by: 4).map { (i: Int) -> SIMD4<Float> in
                SIMD4(Float(halves[i]), Float(halves[i + 1]), Float(halves[i + 2]), Float(halves[i + 3]))
            }
        }
        var bytes = [UInt8](repeating: 0, count: Self.width * Self.height * 4)
        texture.getBytes(&bytes, bytesPerRow: Self.width * 4, from: region, mipmapLevel: 0)
        // Compared as stored, so sRGB targets are checked in their encoded values.
        let (red, blue) = texture.pixelFormat == .bgra8Unorm ? (2, 0) : (0, 2)
        return stride(from: 0, to: bytes.count, by: 4).map {
            SIMD4(Float(bytes[$0 + red]), Float(bytes[$0 + 1]), Float(bytes[$0 + blue]), Float(bytes[$0 + 3])) / 255
        }
    }

    private func render(
        _ renderer: WallpaperDistortionRenderer,
        _ prepared: WallpaperDistortionRenderer.Prepared,
        progress: Float,
        queue: MTLCommandQueue
    ) throws -> [SIMD4<Float>] {
        let target = try makeTexture(renderer.device, format: prepared.pixelFormat, usage: .renderTarget)
        let commandBuffer = try #require(queue.makeCommandBuffer())
        #expect(renderer.encode(prepared, progress: progress, time: 0, into: commandBuffer, target: target))
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        #expect(commandBuffer.status == .completed)
        return readback(target)
    }

    /// Largest per-channel RGB difference, and the share of pixels differing by more than `tolerance`.
    private func compare(_ lhs: [SIMD4<Float>], _ rhs: [SIMD4<Float>]) -> (maxDiff: Float, differing: Double) {
        var maxDiff: Float = 0
        var differing = 0
        for (a, b) in zip(lhs, rhs) {
            let diff = a - b
            let channelMax = max(abs(diff.x), abs(diff.y), abs(diff.z))
            maxDiff = max(maxDiff, channelMax)
            if channelMax > Self.tolerance {
                differing += 1
            }
        }
        return (maxDiff, Double(differing) / Double(lhs.count))
    }

    @Test("Each distortion starts exactly on the old wallpaper, ends exactly on the new one and mixes them midway",
          arguments: WallpaperDistortionEffect.allCases)
    func spansFromOldToNew(effect: WallpaperDistortionEffect) throws {
        let renderer = try #require(WallpaperDistortionRenderer.shared, "no Metal device or distortion shaders in the app's library")
        for format in Self.pixelFormats {
            let inputs = try makeInputs(renderer, format: format)
            let from = readback(inputs.from)
            let to = readback(inputs.to)
            for variant in Self.variants {
                let prepared = try #require(renderer.prepare(
                    effect,
                    from: inputs.from,
                    to: inputs.to,
                    seed: variant.seed,
                    origin: variant.origin,
                    pixelFormat: format
                ))
                let label = "\(effect.rawValue) format \(format.rawValue) seed \(variant.seed)"
                let start = try compare(render(renderer, prepared, progress: 0, queue: inputs.queue), from)
                let end = try compare(render(renderer, prepared, progress: 1, queue: inputs.queue), to)
                let middle = try render(renderer, prepared, progress: 0.5, queue: inputs.queue)
                let middleVsFrom = compare(middle, from)
                let middleVsTo = compare(middle, to)
                print("[distortion] \(label): p0 max \(start.maxDiff) p1 max \(end.maxDiff) p0.5 differs from \(middleVsFrom.differing) to \(middleVsTo.differing)")
                #expect(start.maxDiff <= Self.tolerance, "\(label) p=0 departs from the old wallpaper by \(start.maxDiff)")
                #expect(end.maxDiff <= Self.tolerance, "\(label) p=1 departs from the new wallpaper by \(end.maxDiff)")
                #expect(middleVsFrom.differing > 0.05, "\(label) p=0.5 still looks like the old wallpaper")
                #expect(middleVsTo.differing > 0.05, "\(label) p=0.5 already looks like the new wallpaper")
            }
        }
    }

    @Test("Effects with per-transition resources reuse one prepare for every frame of a transition",
          arguments: [WallpaperDistortionEffect.crystal, .bokeh, .dust])
    func preparesOnce(effect: WallpaperDistortionEffect) throws {
        let renderer = try #require(WallpaperDistortionRenderer.shared, "no Metal device or distortion shaders in the app's library")
        let variant = Self.variants[1]
        for format in Self.pixelFormats {
            let inputs = try makeInputs(renderer, format: format)
            let prepare = {
                renderer.prepare(effect, from: inputs.from, to: inputs.to, seed: variant.seed, origin: variant.origin, pixelFormat: format)
            }
            let shared = try #require(prepare(), "\(effect.rawValue) format \(format.rawValue) failed to prepare")
            for progress: Float in [0.2, 0.35, 0.5, 0.65, 0.8] {
                let reused = try render(renderer, shared, progress: progress, queue: inputs.queue)
                let fresh = try render(renderer, #require(prepare()), progress: progress, queue: inputs.queue)
                #expect(reused == fresh, "\(effect.rawValue) format \(format.rawValue) p=\(progress) differs after re-preparing")
            }
        }
    }
}
