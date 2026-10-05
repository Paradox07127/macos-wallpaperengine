#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import simd
import Testing

/// Glyph coverage composites the same authored colour numbers as image layers.
@Suite("WPE text colour space")
struct WPETextDirectBlendDiagnosticTests {
    @Test("an authored text colour blends in the same number domain as a layer tint")
    func directGlyphOverBackground() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        // What the renderer emits: the authored triple, without an implicit transfer.
        let authoredSRGB = SIMD3<Float>(0.52941, 0.46275, 0.83137)
        let clock = SIMD4<Float>(
            authoredSRGB.x,
            authoredSRGB.y,
            authoredSRGB.z,
            1
        )
        // The wallpaper behind the clock, converted from the screenshot's sRGB (182,167,230).
        let background = SIMD4<Float>(0.4668, 0.3866, 0.7921, 1)

        for coverageByte in [UInt8(64), UInt8(128), UInt8(192), UInt8(255)] {
            let atlasDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .r8Unorm, width: 2, height: 2, mipmapped: false
            )
            let atlas = try #require(device.makeTexture(descriptor: atlasDescriptor))
            var texels = [UInt8](repeating: coverageByte, count: 4)
            atlas.replace(region: MTLRegionMake2D(0, 0, 2, 2), mipmapLevel: 0, withBytes: &texels, bytesPerRow: 2)

            let corners: [SIMD2<Float>] = [
                .init(0, 0), .init(4, 0), .init(0, 4),
                .init(4, 0), .init(4, 4), .init(0, 4),
            ]
            var vertices = corners.map { WPETextMeshVertex(position: $0, uv: SIMD2<Float>(0.5, 0.5)) }
            let buffer = try #require(device.makeBuffer(
                bytes: &vertices,
                length: MemoryLayout<WPETextMeshVertex>.stride * vertices.count
            ))
            let payload = WPETextMeshPayload(
                pages: [WPETextMeshPageDraw(vertexBuffer: buffer, vertexCount: vertices.count, texture: atlas)],
                color: clock
            )
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float, width: 4, height: 4, mipmapped: false
            )
            descriptor.usage = [.renderTarget, .shaderRead]
            let output = try #require(device.makeTexture(descriptor: descriptor))
            let queue = try #require(device.makeCommandQueue())

            // Prime the target with the wallpaper colour, the way direct mode finds it.
            let prime = try #require(queue.makeCommandBuffer())
            let primePass = MTLRenderPassDescriptor()
            primePass.colorAttachments[0].texture = output
            primePass.colorAttachments[0].loadAction = .clear
            primePass.colorAttachments[0].storeAction = .store
            primePass.colorAttachments[0].clearColor = MTLClearColor(
                red: Double(background.x), green: Double(background.y),
                blue: Double(background.z), alpha: 1
            )
            try #require(prime.makeRenderCommandEncoder(descriptor: primePass)).endEncoding()
            prime.commit()
            prime.waitUntilCompleted()

            let commandBuffer = try #require(queue.makeCommandBuffer())
            try executor.encodeTextMesh(
                payload: WPETextRenderPayload(
                    mode: .direct, mesh: payload, backgroundColor: nil, copiesSceneBackground: false
                ),
                sceneSize: CGSize(width: 4, height: 4),
                output: output,
                clearsOutput: false,
                commandBuffer: commandBuffer
            )
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()

            var halves = [UInt16](repeating: 0, count: 4 * 4 * 4)
            output.getBytes(&halves, bytesPerRow: 32, from: MTLRegionMake2D(0, 0, 4, 4), mipmapLevel: 0)
            let base = (4 + 1) * 4
            let r = Float(Float16(bitPattern: halves[base]))
            let g = Float(Float16(bitPattern: halves[base + 1]))
            let b = Float(Float16(bitPattern: halves[base + 2]))
            let coverage = Float(coverageByte) / 255
            let ideal = SIMD3<Float>(
                clock.x * coverage + background.x * (1 - coverage),
                clock.y * coverage + background.y * (1 - coverage),
                clock.z * coverage + background.z * (1 - coverage)
            )
            #expect(abs(r - ideal.x) < 0.01, "direct blend is not a plain over")
            #expect(abs(g - ideal.y) < 0.01)
            #expect(abs(b - ideal.z) < 0.01)
        }
    }

    @Test("the renderer preserves authored colour numbers")
    func rendererConvertsAuthoredColour() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = WPETextMeshRenderer(
            device: device,
            resolver: WPEMultiRootResourceResolver(
                primaryRootURL: FileManager.default.temporaryDirectory,
                dependencyMounts: []
            )
        )
        let authored = SIMD3<Double>(0.52941, 0.46275, 0.83137)
        let object = WPESceneTextObject(
            id: "clock", name: "clock", text: "03:12",
            fontRelativePath: nil, pointSize: 24,
            color: authored, alpha: 1,
            origin: SIMD3<Double>(960, 540, 0), scale: SIMD3<Double>(1, 1, 1),
            visible: true,
            horizontalAlignment: "center", verticalAlignment: "center",
            maxWidth: nil,
            parallaxDepth: SIMD2<Double>(0, 0)
        )
        let payload = try #require(renderer.payload(
            for: object,
            placement: WPETextMeshPlacement(
                originTopLeft: SIMD2<Double>(960, 540),
                scale: SIMD2<Double>(1, 1),
                rotation: 0
            )
        ))
        for (index, authoredChannel) in [authored.x, authored.y, authored.z].enumerated() {
            let expected = Float(authoredChannel)
            #expect(abs(payload.color[index] - expected) < 0.001, "channel \(index) changed authored values")
        }
    }
}
#endif
