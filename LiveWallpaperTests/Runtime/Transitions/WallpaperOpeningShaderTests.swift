import Metal
import Testing

@Suite("Wallpaper opening shaders", .serialized)
@MainActor
struct WallpaperOpeningShaderTests {
    enum Opening: String, CaseIterable, Sendable {
        case loom = "Loom"
        case frame = "Frame"
        case dawn = "Dawn"

        /// A progress inside the darkening phase, before any wallpaper is revealed.
        var darkeningProgress: Float {
            self == .dawn ? 0.2 : 0.1
        }
    }

    /// Mirrors `WallpaperTransitionUniforms` in the Metal sources (24 bytes).
    private struct Uniforms {
        var progress: Float
        var time: Float
        var aspect: Float
        var seed: Float
        var origin: SIMD2<Float>
    }

    private nonisolated static let width = 256
    private nonisolated static let height = 144

    private struct AlphaStats: CustomStringConvertible {
        let alphas: [Float]
        var min: Float {
            alphas.min() ?? .nan
        }

        var max: Float {
            alphas.max() ?? .nan
        }

        var shown: Int {
            alphas.count { $0 >= 0.9 }
        }

        var hidden: Int {
            alphas.count { $0 <= 0.1 }
        }

        /// The top-right 16x16 block, far from every opening's light.
        var corner: AlphaStats {
            let rows = 0 ..< 16
            let columns = (WallpaperOpeningShaderTests.width - 16) ..< WallpaperOpeningShaderTests.width
            return AlphaStats(alphas: rows.flatMap { row in
                columns.map { alphas[row * WallpaperOpeningShaderTests.width + $0] }
            })
        }

        var description: String {
            String(format: "min %.3f max %.3f, >=0.9: %d, <=0.1: %d of %d", min, max, shown, hidden, alphas.count)
        }
    }

    private func render(_ function: String, progress: Float) throws -> AlphaStats {
        #expect(MemoryLayout<Uniforms>.stride == 24)
        let device = try #require(MTLCreateSystemDefaultDevice())
        let library = try #require(device.makeDefaultLibrary(), "the app bundle has no default Metal library")
        let vertex = try #require(library.makeFunction(name: "wallpaperTransitionVertex"))
        let fragment = try #require(library.makeFunction(name: function), "\(function) is missing from the app's library")
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertex
        pipelineDescriptor.fragmentFunction = fragment
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        let pipeline = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)

        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: Self.width,
            height: Self.height,
            mipmapped: false
        )
        textureDescriptor.usage = [.renderTarget]
        textureDescriptor.storageMode = .shared
        let texture = try #require(device.makeTexture(descriptor: textureDescriptor))

        let passDescriptor = MTLRenderPassDescriptor()
        passDescriptor.colorAttachments[0].texture = texture
        passDescriptor.colorAttachments[0].loadAction = .clear
        passDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        passDescriptor.colorAttachments[0].storeAction = .store
        let queue = try #require(device.makeCommandQueue())
        let commandBuffer = try #require(queue.makeCommandBuffer())
        let encoder = try #require(commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor))
        var uniforms = Uniforms(
            progress: progress,
            time: 0,
            aspect: Float(Self.width) / Float(Self.height),
            seed: 0.5,
            origin: SIMD2(0.5, 0.5)
        )
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        #expect(commandBuffer.status == .completed)

        var bytes = [UInt8](repeating: 0, count: Self.width * Self.height * 4)
        texture.getBytes(&bytes, bytesPerRow: Self.width * 4, from: MTLRegionMake2D(0, 0, Self.width, Self.height), mipmapLevel: 0)
        return AlphaStats(alphas: stride(from: 3, to: bytes.count, by: 4).map { Float(bytes[$0]) / 255 })
    }

    @Test("Every opening mask hides the wallpaper at 0, is mid-reveal at 0.5 and shows all of it at 1",
          arguments: Opening.allCases)
    func maskSpansTheWholeReveal(opening: Opening) throws {
        let function = "wallpaperOpening\(opening.rawValue)Mask"
        let start = try render(function, progress: 0)
        let middle = try render(function, progress: 0.5)
        let end = try render(function, progress: 1)
        print("[opening-mask] \(opening.rawValue): p0 {\(start)} p0.5 {\(middle)} p1 {\(end)}")
        #expect(start.max <= 0.01, "\(opening.rawValue) p=0 already shows the wallpaper: \(start)")
        #expect(end.min >= 0.99, "\(opening.rawValue) p=1 still hides part of the wallpaper: \(end)")
        #expect(middle.shown > 0 && middle.hidden > 0, "\(opening.rawValue) p=0.5 is not mid-reveal: \(middle)")
    }

    @Test("Every opening light is clear at the ends and darkens the desktop before the reveal",
          arguments: Opening.allCases)
    func lightDarkensThenClears(opening: Opening) throws {
        let function = "wallpaperOpening\(opening.rawValue)Light"
        let start = try render(function, progress: 0)
        let darkening = try render(function, progress: opening.darkeningProgress)
        let end = try render(function, progress: 1)
        print("[opening-light] \(opening.rawValue): p0 {\(start)} p\(opening.darkeningProgress) corner {\(darkening.corner)} p1 {\(end)}")
        #expect(start.max == 0, "\(opening.rawValue) light shows at p=0: \(start)")
        #expect(end.max == 0, "\(opening.rawValue) light shows at p=1: \(end)")
        #expect(darkening.corner.min >= 0.1, "\(opening.rawValue) does not darken the desktop corner: \(darkening.corner)")
    }
}
