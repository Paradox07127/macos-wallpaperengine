#if !LITE_BUILD && DEBUG
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import XCTest

/// Draws WPE's stock sprite particle program (VS + GS + PS) from a point list through MSC geometry emulation.
final class WPEParityGeometryEmulationTests: XCTestCase {
    private static let side = 256
    /// Model-space centre and opaque colour per particle; the MVP halves x and y.
    private static let particles: [(position: SIMD2<Float>, color: SIMD4<Float>)] = [
        (SIMD2(-1.2, 0.8), SIMD4(1, 0, 0, 1)), (SIMD2(0, 0), SIMD4(0, 1, 0, 1)), (SIMD2(1.2, -0.8), SIMD4(0, 0, 1, 1)),
    ]
    /// Model-space quad edge; 0.4 × 0.5 (MVP) × 128 px per clip unit = 25.6 px.
    private static let size: Float = 0.4

    private var scratch: URL!

    override func setUp() {
        super.setUp()
        scratch = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
        super.tearDown()
    }

    func testSpriteParticlesExpandIntoQuadsAtTheirCentres() async throws {
        let renderer = try await makeRenderer()
        let pixels = try renderer.render(vertexCount: Self.particles.count)

        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "wpe-parity-gs-sprites.png")
        try writePNG(pixels, to: url)
        print("geometry emulation: wrote \(url.path)")

        var counted = 0
        for particle in Self.particles {
            let clip = particle.position * 0.5
            let centre = SIMD2(Int((clip.x + 1) / 2 * Float(Self.side)), Int((1 - clip.y) / 2 * Float(Self.side)))
            let expected = (0 ..< 4).map { UInt8(particle.color[$0] * 255) }
            XCTAssertEqual(pixel(pixels, centre.x, centre.y), expected, "centre \(centre)")
            // 25.6 px quads: 25 or 26 covered rows and columns inside a 40 px box.
            let box = (centre.x - 20 ..< centre.x + 20, centre.y - 20 ..< centre.y + 20)
            let covered = coveredCount(pixels, in: box)
            XCTAssertTrue((25 * 25 ... 26 * 26).contains(covered), "\(covered) pixels around \(centre)")
            counted += covered
        }
        XCTAssertEqual(coveredCount(pixels, in: (0 ..< Self.side, 0 ..< Self.side)), counted,
                       "pixels drawn outside the three quads")
    }

    func testZeroVerticesDrawNothing() async throws {
        let renderer = try await makeRenderer()
        let pixels = try renderer.render(vertexCount: 0)
        XCTAssertEqual(coveredCount(pixels, in: (0 ..< Self.side, 0 ..< Self.side)), 0)
    }

    // MARK: Rendering

    private struct Renderer {
        let device: MTLDevice
        let queue: MTLCommandQueue
        let encoder: WPEParityDrawEncoder
        let arena: WPEParityFrameArena
        let draw: WPEParityDraw

        func render(vertexCount: Int) throws -> [UInt8] {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm, width: WPEParityGeometryEmulationTests.side,
                height: WPEParityGeometryEmulationTests.side, mipmapped: false
            )
            descriptor.usage = .renderTarget
            descriptor.storageMode = .private
            let target = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
            let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
            let frame = try XCTUnwrap(arena.beginFrame(for: commandBuffer))
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
            pass.colorAttachments[0].storeAction = .store
            let renderEncoder = try XCTUnwrap(commandBuffer.makeRenderCommandEncoder(descriptor: pass))
            var draw = draw
            draw.vertexCount = vertexCount
            try encoder.encode(draw, frame: frame, hasDepthAttachment: false, on: renderEncoder)
            renderEncoder.endEncoding()

            let side = WPEParityGeometryEmulationTests.side
            let length = side * side * 4
            let readback = try XCTUnwrap(device.makeBuffer(length: length, options: .storageModeShared))
            let blit = try XCTUnwrap(commandBuffer.makeBlitCommandEncoder())
            blit.copy(from: target, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: side, height: side, depth: 1), to: readback,
                      destinationOffset: 0, destinationBytesPerRow: side * 4, destinationBytesPerImage: length)
            blit.endEncoding()
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            XCTAssertNil(commandBuffer.error)
            return Array(UnsafeRawBufferPointer(start: readback.contents(), count: length))
        }
    }

    private func makeRenderer() async throws -> Renderer {
        let artifact = try await compileSpriteProgram()
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let factory = WPEParityPipelineFactory(device: device)
        let pipeline = try factory.makePipeline(artifact: artifact, blend: .wpe(.normal, modifiers: .writeAlpha),
                                                colorPixelFormat: .rgba8Unorm)

        // GS-path sprite vertex, 44 bytes: POSITION f3 | TEXCOORD0 f4 (rotation.xyz, size) | COLOR f4.
        let vertices = Self.particles.flatMap { particle -> [Float] in
            [particle.position.x, particle.position.y, 0, 0, 0, 0, Self.size]
                + (0 ..< 4).map { particle.color[$0] }
        }
        XCTAssertEqual(vertices.count * 4, Self.particles.count * 44)
        let vertexBuffer = try XCTUnwrap(device.makeBuffer(bytes: vertices, length: vertices.count * 4,
                                                           options: .storageModeShared))
        let white = try makeWhiteTexture(device)

        let mvp = WPEFloatMatrix(columns: [[0.5, 0, 0, 0], [0, 0.5, 0, 0], [0, 0, 1, 0], [0, 0, 0, 1]])
        let geometry: [String: WPECBufferValue] = [
            "g_ModelViewProjectionMatrix": .matrix(mvp),
            "g_OrientationRight": .vector([1, 0, 0]), "g_OrientationUp": .vector([0, 1, 0]),
            "g_OrientationForward": .vector([0, 0, 1]), "g_Texture0Resolution": .vector([1, 1, 1, 1]),
        ]
        var draw = WPEParityDraw(
            pipeline: pipeline,
            depthStencil: .wpe(depthTest: false, depthWrite: false),
            rasterizer: .wpe(flipFrontFace: false, cullingDisabled: true, slopeDepthBias: false, multisample: false),
            vertexBuffer: vertexBuffer,
            primitiveType: .point,
            vertexCount: Self.particles.count
        )
        draw.constants = [.vertex: geometry, .geometry: geometry, .fragment: ["g_Overbright": .float(1)]]
        draw.textures = ["g_Texture0": white]
        draw.samplers = ["g_Texture0SamplerState": .wpe(filter: .point, address: .clamp)]
        return try Renderer(device: device, queue: XCTUnwrap(device.makeCommandQueue()),
                            encoder: WPEParityDrawEncoder(factory: factory),
                            arena: XCTUnwrap(WPEParityFrameArena(device: device, capacity: 64 * 1024)), draw: draw)
    }

    // MARK: Program

    private struct ManifestEntry: Decodable {
        let n: Int
        let name: String
        let target: String
        let hlsl: String
    }

    /// genericparticle as WPE captured it with GS_ENABLED: the gs_5_0 capture src_0x1e between its VS and PS.
    private func compileSpriteProgram() async throws -> WPEParityShaderArtifact {
        guard let root = TestScratch.externalFixtureURL(pathKey: "WPE_HLSL_CAPTURE_DIR") else {
            throw XCTSkip("Set LIVEWALLPAPER_EXTERNAL_FIXTURES=1 and WPE_HLSL_CAPTURE_DIR=<hlsl-capture directory>")
        }
        let manifest = try JSONDecoder().decode([ManifestEntry].self,
                                                from: Data(contentsOf: root.appending(path: "manifest.json")))
        let geometry = try XCTUnwrap(manifest.first { $0.hlsl == "hlsl/src_0x1e.hlsl" })
        let vertex = try XCTUnwrap(manifest.first { $0.n == geometry.n - 1 })
        let fragment = try XCTUnwrap(manifest.first { $0.n == geometry.n + 1 })
        XCTAssertEqual([vertex.name, geometry.name, fragment.name],
                       ["shaders/genericparticle.vert", "shaders/genericparticle.geom", "shaders/genericparticle.frag"])
        XCTAssertEqual([vertex.target, geometry.target, fragment.target], ["vs_5_0", "gs_5_0", "ps_5_0"])
        func source(_ entry: ManifestEntry) throws -> [UInt8] {
            try Array(Data(contentsOf: root.appending(path: entry.hlsl)))
        }
        let program = try WPEHLSLProgram(vertex: source(vertex), geometry: source(geometry), fragment: source(fragment))

        let compiler = try makeCompiler()
        let request = WPEParityShaderCompileRequest(program: program, compilerIdentity: compiler.compilerIdentity,
                                                    bindingABIVersion: 1)
        let cache = scratch.appending(path: "cache")
        let store = WPEParityShaderStore(compiler: compiler, diskCache: WPEParityShaderDiskCache(cachesURL: cache))
        let artifact = try await store.artifact(for: request)
        // A second store must rebuild the artifact, stage-in included, from the disk cache alone.
        let cached = try await WPEParityShaderStore(compiler: NoCompiler(),
                                                    diskCache: WPEParityShaderDiskCache(cachesURL: cache))
            .artifact(for: request)
        XCTAssertNotNil(artifact.vertex.stageIn)
        XCTAssertEqual(cached.vertex.stageIn, artifact.vertex.stageIn)
        return artifact
    }

    private struct NoCompiler: WPEParityShaderCompiling {
        func compile(_: WPEParityShaderCompileRequest) async throws -> WPEParityCompiledStages {
            throw CocoaError(.featureUnsupported)
        }
    }

    private func makeCompiler() throws -> WPEParityHelperShaderCompiler {
        try WPEParityHelperShaderCompiler.local(workDirectory: scratch.appending(path: "shaderc"))
    }

    // MARK: Pixels

    private func makeWhiteTexture(_ device: MTLDevice) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1,
                                                                  mipmapped: false)
        descriptor.usage = .shaderRead
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: [UInt8](repeating: 255, count: 4),
                        bytesPerRow: 4)
        return texture
    }

    private func pixel(_ pixels: [UInt8], _ x: Int, _ y: Int) -> [UInt8] {
        let offset = (y * Self.side + x) * 4
        return Array(pixels[offset ..< offset + 4])
    }

    private func coveredCount(_ pixels: [UInt8], in box: (Range<Int>, Range<Int>)) -> Int {
        box.1.reduce(0) { count, y in
            count + box.0.count { x in pixel(pixels, x, y)[3] != 0 }
        }
    }

    private func writePNG(_ pixels: [UInt8], to url: URL) throws {
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let image = try XCTUnwrap(CGImage(
            width: Self.side, height: Self.side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: Self.side * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
#endif
