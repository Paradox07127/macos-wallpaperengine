import CoreGraphics
@testable import LiveWallpaper
import Metal
import Testing

@Suite("Wallpaper canvas region", .serialized)
@MainActor
struct WallpaperCanvasRegionTests {
    // MARK: - Layout and values

    @Test("The canvas fields follow the 24-byte prefix the shaders already read")
    func uniformLayout() {
        #expect(MemoryLayout<WallpaperTransitionUniforms>.offset(of: \.regionOrigin) == 24)
        #expect(MemoryLayout<WallpaperTransitionUniforms>.offset(of: \.regionSize) == 32)
        #expect(MemoryLayout<WallpaperTransitionUniforms>.offset(of: \.canvasAspect) == 40)
        #expect(MemoryLayout<WallpaperTransitionUniforms>.stride == 48)
    }

    @Test("A display that is the whole canvas gets exactly the identity region")
    func singleDisplayIsIdentity() {
        let frame = CGRect(x: 1440, y: -200, width: 1512, height: 982)
        let region = WallpaperCanvasRegion(frame: frame, canvas: frame)
        let identity = WallpaperCanvasRegion.identity(aspect: Float(frame.width / frame.height))
        #expect(bits(region) == bits(identity))
    }

    @Test("Side-by-side displays start where the left one ends, in canvas heights")
    func sideBySide() {
        let left = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let right = CGRect(x: 1920, y: 0, width: 2560, height: 1440)
        let canvas = left.union(right)
        let leftRegion = WallpaperCanvasRegion(frame: left, canvas: canvas)
        let rightRegion = WallpaperCanvasRegion(frame: right, canvas: canvas)
        #expect(leftRegion.origin == SIMD2(0, 0))
        #expect(rightRegion.origin == SIMD2(Float(1920.0 / 1440.0), 0))
        #expect(rightRegion.size == SIMD2(Float(2560.0 / 1440.0), 1))
        #expect(leftRegion.canvasAspect == Float(4480.0 / 1440.0))
        #expect(rightRegion.canvasAspect == leftRegion.canvasAspect)
    }

    @Test("A display stacked above another keeps a positive y origin, so y is not flipped")
    func stacked() {
        let bottom = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let top = CGRect(x: 0, y: 1080, width: 1920, height: 1080)
        let canvas = bottom.union(top)
        #expect(WallpaperCanvasRegion(frame: bottom, canvas: canvas).origin == SIMD2(0, 0))
        #expect(WallpaperCanvasRegion(frame: top, canvas: canvas).origin == SIMD2(0, 0.5))
        #expect(WallpaperCanvasRegion(frame: top, canvas: canvas).size == SIMD2(Float(1920.0 / 2160.0), 0.5))
    }

    @Test("Staggered displays with negative global coordinates measure from the canvas corner")
    func staggered() {
        let main = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let external = CGRect(x: -1920, y: -200, width: 1920, height: 1080)
        let canvas = main.union(external)
        let mainRegion = WallpaperCanvasRegion(frame: main, canvas: canvas)
        let externalRegion = WallpaperCanvasRegion(frame: external, canvas: canvas)
        #expect(externalRegion.origin == SIMD2(0, 0))
        #expect(externalRegion.size == SIMD2(Float(1920.0 / 1182.0), Float(1080.0 / 1182.0)))
        #expect(mainRegion.origin == SIMD2(Float(1920.0 / 1182.0), Float(200.0 / 1182.0)))
        #expect(mainRegion.size == SIMD2(Float(1512.0 / 1182.0), Float(982.0 / 1182.0)))
        #expect(mainRegion.canvasAspect == Float(3432.0 / 1182.0))
    }

    private func bits(_ region: WallpaperCanvasRegion) -> [UInt32] {
        [region.origin.x, region.origin.y, region.size.x, region.size.y, region.canvasAspect].map(\.bitPattern)
    }

    // MARK: - Seam continuity

    enum Seam: String, CaseIterable, Sendable {
        case meteorMask = "wallpaperTransitionMeteorMask"
        case meteorLight = "wallpaperTransitionMeteorLight"
        case loomMask = "wallpaperOpeningLoomMask"
        case loomLight = "wallpaperOpeningLoomLight"

        var progresses: [Float] {
            switch self {
            case .meteorMask: [0.35, 0.6]
            case .meteorLight: [0.12, 0.2, 0.35]
            case .loomMask: [0.5, 0.7]
            case .loomLight: [0.14, 0.18, 0.25]
            }
        }

        /// Masks are drawn at half the display's resolution, so they are checked at both sizes.
        var sizes: [(width: Int, height: Int)] {
            switch self {
            case .meteorMask, .loomMask: [(512, 144), (256, 72)]
            case .meteorLight, .loomLight: [(512, 144)]
            }
        }
    }

    /// A half sees its canvas point rounded differently from the whole canvas: one 8-bit step absorbs that,
    /// and a point landing exactly on a hash-cell boundary may flip a few pixels further.
    private static let channelTolerance = 1
    private static let outlierPixelLimit = 4
    /// Rendering each half as its own canvas restarts every effect at the seam; this floor proves the check sees it.
    private static let controlMinimumDifference = 64

    private static let variants: [(seed: Float, origin: SIMD2<Float>)] = [
        (0.37, SIMD2(0.4, 0.6)),
        (0.81, SIMD2(0.7, 0.25)),
    ]

    private struct Comparison: CustomStringConvertible {
        var maxDifference = 0
        var outliers = 0
        var description: String {
            "max channel difference \(maxDifference), pixels over tolerance \(outliers)"
        }
    }

    @Test("Two halves rendered with their canvas regions match the whole canvas pixel for pixel",
          arguments: Seam.allCases)
    func halvesMatchTheWholeCanvas(seam: Seam) throws {
        for size in seam.sizes {
            let half = size.width / 2
            let canvas = CGRect(x: 0, y: 0, width: size.width, height: size.height)
            let leftFrame = CGRect(x: 0, y: 0, width: half, height: size.height)
            let rightFrame = CGRect(x: half, y: 0, width: half, height: size.height)
            for variant in Self.variants {
                for progress in seam.progresses {
                    let whole = try render(seam.rawValue, width: size.width, height: size.height,
                                           progress: progress, variant: variant, region: nil)
                    let left = try render(seam.rawValue, width: half, height: size.height, progress: progress, variant: variant,
                                          region: WallpaperCanvasRegion(frame: leftFrame, canvas: canvas))
                    let right = try render(seam.rawValue, width: half, height: size.height, progress: progress, variant: variant,
                                           region: WallpaperCanvasRegion(frame: rightFrame, canvas: canvas))
                    let leftResult = compare(left, whole, width: size.width, height: size.height, columnOffset: 0)
                    let rightResult = compare(right, whole, width: size.width, height: size.height, columnOffset: half)
                    let label = "\(seam.rawValue) \(size.width)x\(size.height) seed \(variant.seed) p=\(progress)"
                    #expect(rightResult.outliers <= Self.outlierPixelLimit, "\(label) right half drifts from the canvas: \(rightResult)")
                    #expect(leftResult.outliers <= Self.outlierPixelLimit, "\(label) left half drifts from the canvas: \(leftResult)")

                    let controlRight = try render(seam.rawValue, width: half, height: size.height, progress: progress,
                                                  variant: variant, region: nil)
                    let control = compare(controlRight, whole, width: size.width, height: size.height, columnOffset: half)
                    #expect(control.maxDifference >= Self.controlMinimumDifference,
                            "\(label) a half drawn as its own canvas still matches, so the seam check has no teeth: \(control)")
                }
            }
        }
    }

    private func compare(_ half: [UInt8], _ whole: [UInt8], width: Int, height: Int, columnOffset: Int) -> Comparison {
        let halfWidth = width / 2
        var result = Comparison()
        for row in 0 ..< height {
            for column in 0 ..< halfWidth {
                var pixelDifference = 0
                for channel in 0 ..< 4 {
                    let a = Int(half[(row * halfWidth + column) * 4 + channel])
                    let b = Int(whole[(row * width + column + columnOffset) * 4 + channel])
                    pixelDifference = max(pixelDifference, abs(a - b))
                }
                result.maxDifference = max(result.maxDifference, pixelDifference)
                if pixelDifference > Self.channelTolerance {
                    result.outliers += 1
                }
            }
        }
        return result
    }

    private func render(
        _ function: String,
        width: Int,
        height: Int,
        progress: Float,
        variant: (seed: Float, origin: SIMD2<Float>),
        region: WallpaperCanvasRegion?
    ) throws -> [UInt8] {
        let renderer = try #require(WallpaperTransitionRenderer.shared, "no Metal device or transition shaders in the app's library")
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: WallpaperTransitionRenderer.pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = .shared
        let texture = try #require(renderer.device.makeTexture(descriptor: descriptor))
        let uniforms = WallpaperTransitionUniforms(
            progress: progress,
            time: 0.7,
            aspect: Float(width) / Float(height),
            seed: variant.seed,
            origin: variant.origin,
            region: region
        )
        let shaders = WallpaperMaskShaders(mask: function, light: nil)
        let commandBuffer = try #require(renderer.render(.mask, shaders: shaders, uniforms: uniforms, to: texture))
        commandBuffer.waitUntilCompleted()
        #expect(commandBuffer.status == .completed)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        return bytes
    }
}
