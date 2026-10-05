#if !LITE_BUILD
import CoreGraphics
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import simd
import Testing

@Suite("Captured WPE HDR bloom contract", .serialized)
struct WPEBloomContractTests {
    @Test("Constant HDR field preserves measured pyramid gain and scene alpha", arguments: [4, 8])
    func pyramidGain(iterations: Int) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        for scatter in [1.0, 2.0] {
            let strength = scatter == 1 ? 0.5 : 0.3
            let output = try texture(device, width: 256, height: 256, pixel: SIMD4(4, 4, 4, 1))
            let bloom = WPESceneBloomSettings(strength: strength, threshold: 1, feather: 1,
                                              scatter: scatter, iterations: iterations, tint: SIMD3(repeating: 1))
            let camera = WPEMetalCameraUniforms(
                orthogonalProjection: .init(width: 256, height: 256, auto: true),
                sceneCamera: .defaultCamera, sceneHDR: true, bloom: bloom
            )
            let command = try #require(executor.commandQueue.makeCommandBuffer())
            try executor.encodeSceneBloomIfNeeded(cameraUniforms: camera, output: output, commandBuffer: command)
            command.commit()
            command.waitUntilCompleted()
            #expect(command.status == .completed, "\(String(describing: command.error))")
            #expect(executor.bloomLevelTextures.count == iterations)
            let normalization = 1 + pow(scatter, Double(iterations - 2))
            let gain = (0 ..< iterations).reduce(0.0) { $0 + pow(scatter, Double($1)) }
            // For brightness 4 and threshold 1 the hard-knee contribution is 3.
            let expected = 4 + 3 * strength / normalization * gain
            let actual = pixel(output, x: 128, y: 128)
            #expect(abs(Double(actual.x) - expected) < 0.05)
            #expect(actual.w == 1, "bloom must preserve coverage instead of adding alpha")
        }
    }

    @Test("Cubic upsample agrees with independent sixteen-tap B-spline convolution")
    func cubicUpsampleKernel() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let source = try texture(device, width: 8, height: 5, pixel: SIMD4(0, 0, 0, 0.1))
        let destination = try texture(device, width: 16, height: 10, pixel: .zero)
        let impulse: [UInt16] = [Float16(4).bitPattern, Float16(2).bitPattern, Float16(1).bitPattern, Float16(0.1).bitPattern]
        impulse.withUnsafeBytes {
            source.replace(region: MTLRegionMake2D(3, 2, 1, 1), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 8)
        }
        let command = try #require(executor.commandQueue.makeCommandBuffer())
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = destination
        descriptor.colorAttachments[0].loadAction = .dontCare
        descriptor.colorAttachments[0].storeAction = .store
        let encoder = try #require(command.makeRenderCommandEncoder(descriptor: descriptor))
        try encoder.setRenderPipelineState(executor.renderPipeline(fragmentName: "wpe_bloom_upsample_fragment", colorPixelFormat: .rgba16Float))
        encoder.setFragmentTexture(source, index: 0)
        var uniforms = WPEBloomUniforms(texelAndWeight: SIMD4(1.0 / 16, 1.0 / 10, 2, 0), blendParams: .zero, tint: .zero)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WPEBloomUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        #expect(command.status == .completed, "\(String(describing: command.error))")
        for y in 0 ..< 10 {
            for x in 0 ..< 16 {
                let uv = SIMD2((Double(x) + 0.5) / 16, (Double(y) + 0.5) / 10)
                let offsets: [SIMD2<Double>] = [SIMD2(1.0 / 16, 1.0 / 10), SIMD2(-1.0 / 16, 1.0 / 10),
                               SIMD2(1.0 / 16, -1.0 / 10), SIMD2(-1.0 / 16, -1.0 / 10)]
                let expected = offsets.reduce(0.0) { $0 + splineImpulse(uv + $1) } * 0.25 * 2
                let actual = pixel(destination, x: x, y: y)
                #expect(abs(Double(actual.x) - expected * 4) < 0.01)
                #expect(abs(Double(actual.y) - expected * 2) < 0.01)
                #expect(abs(Double(actual.z) - expected) < 0.01)
                #expect(actual.w == 1)
            }
        }
    }

    /// Direct convolution; deliberately does not use paired bilinear fetches.
    private func splineImpulse(_ uv: SIMD2<Double>) -> Double {
        let position = uv * SIMD2(8, 5) - SIMD2(repeating: 0.5)
        let base = SIMD2(floor(position.x), floor(position.y))
        let f = position - base
        func weights(_ t: Double) -> [Double] {
            [pow(1 - t, 3) / 6, (3 * pow(t, 3) - 6 * t * t + 4) / 6,
             (-3 * pow(t, 3) + 3 * t * t + 3 * t + 1) / 6, pow(t, 3) / 6]
        }
        let wx = weights(f.x), wy = weights(f.y)
        var result = 0.0
        for y in 0 ..< 4 {
            for x in 0 ..< 4 {
                let sx = min(max(Int(base.x) + x - 1, 0), 7)
                let sy = min(max(Int(base.y) + y - 1, 0), 4)
                if sx == 3, sy == 2 {
                    result += wx[x] * wy[y]
                }
            }
        }
        return result
    }

    private func texture(_ device: MTLDevice, width: Int, height: Int, pixel: SIMD4<Float>) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.renderTarget, .shaderRead]
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        let rgba = (0 ..< 4).map { Float16(pixel[$0]).bitPattern }
        var pixels = [UInt16]()
        for _ in 0 ..< (width * height) {
            pixels.append(contentsOf: rgba)
        }
        pixels.withUnsafeBytes {
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width * 8)
        }
        return texture
    }

    private func pixel(_ texture: MTLTexture, x: Int, y: Int) -> SIMD4<Float> {
        var rgba = [UInt16](repeating: 0, count: 4)
        rgba.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: 8, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
        }
        return SIMD4(Float(Float16(bitPattern: rgba[0])), Float(Float16(bitPattern: rgba[1])),
                     Float(Float16(bitPattern: rgba[2])), Float(Float16(bitPattern: rgba[3])))
    }
}
#endif
