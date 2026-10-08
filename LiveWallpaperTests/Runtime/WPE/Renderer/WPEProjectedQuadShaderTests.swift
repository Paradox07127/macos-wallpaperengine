#if !LITE_BUILD
import CoreGraphics
import Foundation
@testable import LiveWallpaper
import Metal
import simd
import Testing

@Suite("Projected composelayer quad shaders", .serialized)
struct WPEProjectedQuadShaderTests {
    private static let width = 64, height = 36
    /// Blue channel marks unwritten pixels: the uv-encoded source never writes blue.
    private static let clearBytes: [UInt8] = [0, 0, 255, 255]
    private static let tolerance = 2

    private static func quad() throws -> WPEProjectedComposeQuad {
        let scene = CGSize(width: width, height: height)
        return try #require(WPEProjectedComposeQuad(
            origin: SIMD3(32, 18, 0), scale: SIMD3(0.4, 0.4, 1.5), angles: SIMD3(20, -20, 0) * .pi / 180,
            size: scene, sceneSize: scene, fovDegrees: 90
        ))
    }

    /// 256² texels whose R = column and G = row, so a linear sample at uv reads `uv·256 − ½` exactly.
    private static func uvTexture(device: MTLDevice) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 256, height: 256, mipmapped: false)
        descriptor.usage = [.shaderRead]
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        var bytes = [UInt8](repeating: 0, count: 256 * 256 * 4)
        for row in 0 ..< 256 {
            for column in 0 ..< 256 {
                let index = (row * 256 + column) * 4
                bytes[index] = UInt8(column)
                bytes[index + 1] = UInt8(row)
                bytes[index + 3] = 255
            }
        }
        texture.replace(region: MTLRegionMake2D(0, 0, 256, 256), mipmapLevel: 0, withBytes: bytes, bytesPerRow: 256 * 4)
        return texture
    }

    private static func expectedRG(uv: SIMD2<Double>) -> SIMD2<Double> {
        simd_clamp(uv * 256 - 0.5, SIMD2(repeating: 0), SIMD2(repeating: 255))
    }

    private static func draw(
        vertexName: String, fragmentName: String, uniforms: WPEProjectedQuadUniforms, vertexUniforms: Bool
    ) throws -> [UInt8] {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let library = try #require(device.makeDefaultLibrary())
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = try #require(library.makeFunction(name: vertexName))
        descriptor.fragmentFunction = try #require(try WPEMetalColorOutput.fragment(library: library, name: fragmentName, format: .rgba8Unorm))
        descriptor.colorAttachments[0].pixelFormat = .rgba8Unorm
        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)

        let targetDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false
        )
        targetDescriptor.usage = [.renderTarget, .shaderRead]
        let target = try #require(device.makeTexture(descriptor: targetDescriptor))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 1, alpha: 1)
        pass.colorAttachments[0].storeAction = .store

        let buffer = try #require(queue.makeCommandBuffer())
        let encoder = try #require(buffer.makeRenderCommandEncoder(descriptor: pass))
        encoder.setRenderPipelineState(pipeline)
        var bound = uniforms
        if vertexUniforms {
            encoder.setVertexBytes(&bound, length: MemoryLayout<WPEProjectedQuadUniforms>.stride, index: 1)
        } else {
            encoder.setFragmentBytes(&bound, length: MemoryLayout<WPEProjectedQuadUniforms>.stride, index: 0)
        }
        let source = try uvTexture(device: device)
        encoder.setFragmentTexture(source, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
        #expect(buffer.error == nil)

        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        target.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        return bytes
    }

    private static func pixel(_ bytes: [UInt8], _ column: Int, _ row: Int) -> [UInt8] {
        let index = (row * width + column) * 4
        return Array(bytes[index ..< index + 4])
    }

    /// Returns the larger channel error so the suite can report the worst case.
    @discardableResult
    private static func expectPixel(_ actual: [UInt8], matches rg: SIMD2<Double>, at label: String) -> Double {
        let error = max(abs(Double(actual[0]) - rg.x), abs(Double(actual[1]) - rg.y))
        #expect(error <= Double(tolerance) && actual[2] == 0 && actual[3] == 255, "\(label): \(actual) vs \(rg)")
        return error
    }

    @Test("Swift uniforms match the Metal layout and normalise the homography")
    func uniformLayout() throws {
        #expect(MemoryLayout<WPEProjectedQuadUniforms>.stride == 128)
        #expect(MemoryLayout<WPEProjectedQuadUniforms>.offset(of: \.captureRow0) == 64)
        #expect(MemoryLayout<WPEProjectedQuadUniforms>.offset(of: \.captureRow1) == 80)
        #expect(MemoryLayout<WPEProjectedQuadUniforms>.offset(of: \.captureRow2) == 96)
        #expect(MemoryLayout<WPEProjectedQuadUniforms>.offset(of: \.flags) == 112)
        let quad = try Self.quad()
        let uniforms = WPEProjectedQuadUniforms(quad: quad, clearAlpha: true)
        let tl = quad.clipCorners[2]
        #expect(uniforms.clipCorners.2 == SIMD4(Float(tl.x), Float(tl.y), 0, Float(tl.z)))
        #expect(uniforms.captureRow2.z == 1 && uniforms.captureRow2.w == 0)
        #expect(uniforms.flags.x == 1)
        #expect(WPEProjectedQuadUniforms(quad: quad, clearAlpha: false).flags.x == 0)
    }

    @Test("Draw-back keeps clip w so each pixel samples the inverse-homography layer uv")
    func drawBackIsPerspectiveCorrect() throws {
        let quad = try Self.quad()
        let bytes = try Self.draw(
            vertexName: "wpe_projected_quad_vertex", fragmentName: "wpe_util_copy_fragment",
            uniforms: WPEProjectedQuadUniforms(quad: quad, clearAlpha: false), vertexUniforms: true
        )
        let size = SIMD2(Double(Self.width), Double(Self.height))
        var worst = 0.0
        // Near-TL probe pins orientation: layer uv (0,0) must land where clipCorners[2] projects.
        for layerUV in [SIMD2(0.5, 0.5), SIMD2(0.2, 0.25), SIMD2(0.8, 0.2), SIMD2(0.25, 0.8), SIMD2(0.75, 0.75), SIMD2(0.06, 0.06)] {
            let mapped = quad.captureHomography * SIMD3(layerUV.x, layerUV.y, 1)
            let screenPixel = SIMD2(mapped.x, mapped.y) / mapped.z * size
            let column = Int(screenPixel.x.rounded(.down)), row = Int(screenPixel.y.rounded(.down))
            let center = (SIMD2(Double(column), Double(row)) + 0.5) / size
            let reference = try #require(quad.layerUV(screenUV: center))
            worst = max(worst, Self.expectPixel(Self.pixel(bytes, column, row), matches: Self.expectedRG(uv: reference),
                                                at: "layer uv \(layerUV) at pixel (\(column), \(row))"))
        }
        let tl = quad.clipCorners[2]
        let tlPixel = SIMD2((tl.x / tl.z + 1) / 2, (1 - tl.y / tl.z) / 2) * size
        #expect(tlPixel.x < size.x / 2 && tlPixel.y < size.y / 2, "TL corner projects to \(tlPixel)")
        let outside = SIMD2(0.5, 0.5) / size
        let outsideUV = try #require(quad.layerUV(screenUV: outside))
        #expect(outsideUV.x < 0 || outsideUV.y < 0)
        #expect(Self.pixel(bytes, 0, 0) == Self.clearBytes)
        print("WPEProjectedQuadShaderTests draw-back worst error \(worst)")
    }

    @Test("Capture samples the scene where the homography maps each layer uv")
    func captureFollowsHomography() throws {
        let quad = try Self.quad()
        let bytes = try Self.draw(
            vertexName: "wpe_fullscreen_vertex", fragmentName: "wpe_projected_scene_capture_fragment",
            uniforms: WPEProjectedQuadUniforms(quad: quad, clearAlpha: false), vertexUniforms: false
        )
        var worst = 0.0
        for (column, row) in [(32, 18), (10, 8), (50, 9), (12, 28), (52, 30), (0, 0), (63, 35)] {
            let layerUV = SIMD2(Double(column) + 0.5, Double(row) + 0.5) / SIMD2(Double(Self.width), Double(Self.height))
            let mapped = quad.captureHomography * SIMD3(layerUV.x, layerUV.y, 1)
            let sceneUV = simd_clamp(SIMD2(mapped.x, mapped.y) / mapped.z, SIMD2(repeating: 0), SIMD2(repeating: 1))
            worst = max(worst, Self.expectPixel(Self.pixel(bytes, column, row), matches: Self.expectedRG(uv: sceneUV),
                                                at: "layer pixel (\(column), \(row))"))
        }
        print("WPEProjectedQuadShaderTests capture worst error \(worst)")
    }

    @Test("CLEARALPHA capture writes transparent black everywhere")
    func clearAlphaCaptureIsTransparent() throws {
        let quad = try Self.quad()
        let bytes = try Self.draw(
            vertexName: "wpe_fullscreen_vertex", fragmentName: "wpe_projected_scene_capture_fragment",
            uniforms: WPEProjectedQuadUniforms(quad: quad, clearAlpha: true), vertexUniforms: false
        )
        #expect(bytes.allSatisfy { $0 == 0 })
    }
}
#endif
