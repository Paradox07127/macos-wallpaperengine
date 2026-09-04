#if !LITE_BUILD
import CoreText
import Foundation
import ImageIO
import LiveWallpaperProWPE
import Metal
import Testing
@testable import LiveWallpaper

/// End-to-end mesh + atlas checks with real ink: every glyph quad must map to
/// a non-empty atlas cell. (Regression: the atlas once rasterized with the
/// PLACED rect's origin as the pen offset, so every glyph after the first
/// landed outside its cell — text rendered as a bare first letter.)
struct WPETextMeshRendererTests {

    private func makeRenderer() throws -> WPETextMeshRenderer {
        let device = try #require(MTLCreateSystemDefaultDevice())
        return WPETextMeshRenderer(
            device: device,
            resolver: WPEMultiRootResourceResolver(
                primaryRootURL: FileManager.default.temporaryDirectory,
                dependencyMounts: []
            )
        )
    }

    private func textObject(_ text: String) -> WPESceneTextObject {
        WPESceneTextObject(
            id: "t1", name: "t1", text: text,
            fontRelativePath: nil, pointSize: 24,
            color: SIMD3<Double>(1, 1, 1), alpha: 1,
            origin: SIMD3<Double>(960, 540, 0), scale: SIMD3<Double>(1, 1, 1),
            visible: true,
            horizontalAlignment: "center", verticalAlignment: "center",
            maxWidth: nil,
            parallaxDepth: SIMD2<Double>(0, 0)
        )
    }

    private struct Quad {
        let xs: ClosedRange<Float>
        let uvXs: ClosedRange<Float>
        let uvYs: ClosedRange<Float>
    }

    private func quads(of page: WPETextMeshPageDraw) -> [Quad] {
        let count = page.vertexCount
        let vertices = page.vertexBuffer.contents()
            .bindMemory(to: WPETextMeshVertex.self, capacity: count)
        var out: [Quad] = []
        var index = 0
        while index + 6 <= count {
            let group = (index..<index + 6).map { vertices[$0] }
            out.append(Quad(
                xs: group.map(\.position.x).min()!...group.map(\.position.x).max()!,
                uvXs: group.map(\.uv.x).min()!...group.map(\.uv.x).max()!,
                uvYs: group.map(\.uv.y).min()!...group.map(\.uv.y).max()!
            ))
            index += 6
        }
        return out
    }

    /// Coverage sum of the atlas texels inside one quad's uv rect.
    private func ink(in quad: Quad, texture: MTLTexture) -> Int {
        let x0 = Int(quad.uvXs.lowerBound * Float(texture.width))
        let x1 = Int(quad.uvXs.upperBound * Float(texture.width))
        let y0 = Int(quad.uvYs.lowerBound * Float(texture.height))
        let y1 = Int(quad.uvYs.upperBound * Float(texture.height))
        let width = max(x1 - x0, 1)
        let height = max(y1 - y0, 1)
        var bytes = [UInt8](repeating: 0, count: width * height)
        texture.getBytes(
            &bytes,
            bytesPerRow: width,
            from: MTLRegionMake2D(x0, y0, width, height),
            mipmapLevel: 0
        )
        return bytes.reduce(0) { $0 + Int($1) }
    }

    @Test("Every glyph quad has ink in its atlas cell (not just the first)")
    func everyGlyphHasInk() throws {
        let renderer = try makeRenderer()
        let payload = try #require(renderer.payload(
            for: textObject("Hello World\n12:34:56"),
            placement: WPETextMeshPlacement(
                originTopLeft: SIMD2<Double>(960, 540),
                scale: SIMD2<Double>(1, 1),
                rotation: 0
            )
        ))
        var glyphCount = 0
        for page in payload.pages {
            for (index, quad) in quads(of: page).enumerated() {
                glyphCount += 1
                #expect(ink(in: quad, texture: page.texture) > 0,
                        "glyph quad #\(index) maps to an empty atlas cell")
            }
        }
        // "Hello World\n12:34:56" = 18 non-space glyphs.
        #expect(glyphCount == 18)
    }

    @Test("The mesh spans the whole block, not just the first glyph")
    func meshSpansBlock() throws {
        let renderer = try makeRenderer()
        let payload = try #require(renderer.payload(
            for: textObject("MMMMMMMMMM"),
            placement: WPETextMeshPlacement(
                originTopLeft: SIMD2<Double>(960, 540),
                scale: SIMD2<Double>(1, 1),
                rotation: 0
            )
        ))
        let allQuads = payload.pages.flatMap { quads(of: $0) }
        #expect(allQuads.count == 10)
        let minX = allQuads.map(\.xs.lowerBound).min() ?? 0
        let maxX = allQuads.map(\.xs.upperBound).max() ?? 0
        let firstWidth = (allQuads.first?.xs.upperBound ?? 0) - (allQuads.first?.xs.lowerBound ?? 0)
        #expect(maxX - minX > firstWidth * 8,
                "10 identical glyphs must span ~10 advances, not collapse onto the first")
        // Centered on origin.x = 960.
        #expect(abs((minX + maxX) / 2 - 960) < 3)
    }

    @Test("Suspension reclaim drops atlas pages and rebuilds current text")
    func releaseCachedResourcesRebuildsAtlas() throws {
        let renderer = try makeRenderer()
        let placement = WPETextMeshPlacement(
            originTopLeft: SIMD2<Double>(960, 540),
            scale: SIMD2<Double>(1, 1),
            rotation: 0
        )
        let first = try #require(renderer.payload(for: textObject("12:34"), placement: placement))
        #expect(!first.pages.isEmpty)
        #expect(renderer.releaseCachedResources() == 1)
        #expect(renderer.releaseCachedResources() == 0)

        let rebuilt = try #require(renderer.payload(for: textObject("Sunday"), placement: placement))
        #expect(!rebuilt.pages.isEmpty)
        #expect(rebuilt.pages[0].texture !== first.pages[0].texture)
    }
}
#endif

#if DEBUG
/// Draws a real multi-line text mesh through the executor and writes a PNG
/// artifact for visual inspection (scratch evidence, also asserts ink bbox).
struct WPETextMeshVisualDumpTests {
    @Test("GPU draw produces ink spanning the block")
    func gpuDrawInkBBox() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let renderer = WPETextMeshRenderer(
            device: device,
            resolver: WPEMultiRootResourceResolver(
                primaryRootURL: FileManager.default.temporaryDirectory,
                dependencyMounts: []
            )
        )
        let object = WPESceneTextObject(
            id: "v", name: "v", text: "Hello WPE 12:34\n第二行中文测试",
            fontRelativePath: nil, pointSize: 20,
            color: SIMD3<Double>(1, 1, 1), alpha: 1,
            origin: SIMD3<Double>(480, 270, 0), scale: SIMD3<Double>(1, 1, 1),
            visible: true,
            horizontalAlignment: "center", verticalAlignment: "center",
            maxWidth: nil,
            parallaxDepth: SIMD2<Double>(0, 0)
        )
        let payload = try #require(renderer.payload(
            for: object,
            placement: WPETextMeshPlacement(
                originTopLeft: SIMD2<Double>(480, 270), scale: SIMD2<Double>(1, 1), rotation: 0
            )
        ))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 960, height: 540, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let target = try #require(device.makeTexture(descriptor: descriptor))
        let queue = try #require(device.makeCommandQueue())
        let commandBuffer = try #require(queue.makeCommandBuffer())
        try executor.encodeTextMesh(
            payload: WPETextRenderPayload(
                mode: .direct,
                mesh: payload,
                backgroundColor: nil,
                copiesSceneBackground: false
            ),
            sceneSize: CGSize(width: 960, height: 540),
            output: target,
            clearsOutput: false,
            commandBuffer: commandBuffer
        )
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: 960 * 540 * 4)
        target.getBytes(&bytes, bytesPerRow: 960 * 4, from: MTLRegionMake2D(0, 0, 960, 540), mipmapLevel: 0)
        var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min, ink = 0
        for y in 0..<540 {
            for x in 0..<960 where bytes[(y * 960 + x) * 4 + 3] > 8 {
                ink += 1
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        #expect(ink > 500, "expected substantial ink, got \(ink)")
        #expect(maxX - minX > 200, "ink bbox width \(maxX - minX) — text collapsed?")
        #expect(maxY - minY > 60, "ink bbox height \(maxY - minY) — second line missing?")
        // PNG artifact for eyeballing: black ink on white.
        for i in stride(from: 0, to: bytes.count, by: 4) {
            let a = bytes[i + 3]
            bytes[i] = 255 - a; bytes[i + 1] = 255 - a; bytes[i + 2] = 255 - a; bytes[i + 3] = 255
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wpe-text-mesh-dump.png")
        if let space = CGColorSpace(name: CGColorSpace.sRGB),
           let ctx = CGContext(
               data: &bytes, width: 960, height: 540, bitsPerComponent: 8,
               bytesPerRow: 960 * 4, space: space,
               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
           ),
           let image = ctx.makeImage(),
           let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, image, nil)
            CGImageDestinationFinalize(dest)
            print("wpe-text-mesh-dump: \(url.path)")
        }
    }
}
#endif
