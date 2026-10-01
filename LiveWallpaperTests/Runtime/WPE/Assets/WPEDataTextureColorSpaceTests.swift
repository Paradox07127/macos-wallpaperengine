import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import Testing

@Suite("WPE data texture colour space")
struct WPEDataTextureColorSpaceTests {
    @Test("Pulse Add evaluates authored encoded colours while preserving masks and alpha")
    func pulseEncodedColourAmplitude() throws {
        let low = try pulsePixel(time: -.pi / 2)
        let middle = try pulsePixel(time: 0)
        let high = try pulsePixel(time: .pi / 2)
        #expect(abs(Int(low[0]) - 128) <= 2)
        #expect(abs(Int(middle[0]) - 192) <= 2)
        #expect(abs(Int(high[0]) - 255) <= 2)
        #expect(high[3] == 255)
        let masked = try pulsePixel(time: .pi / 2, mask: 128)
        #expect(abs(Int(masked[0]) - 192) <= 2)
        let transparent = try pulsePixel(time: .pi / 2, alpha: 0)
        #expect(transparent == [0, 0, 0, 0])
        let translucent = try pulsePixel(time: .pi / 2, alpha: 128)
        #expect(abs(Int(translucent[0]) - 128) <= 2)
        #expect(translucent[3] == 128)
    }

    @Test("Other effects use the same number arithmetic")
    func otherEffectArithmeticStaysLinear() throws {
        let high = try pulsePixel(time: .pi / 2, shaderName: "effects/other")
        #expect(abs(Int(high[0]) - 255) <= 2)
    }

    /// mask 的原始值不能过颜色传输函数,所以它与 source 纹理格式刻意不同。
    private func pulsePixel(
        time: Float, mask: UInt8 = 255, alpha: UInt8 = 255,
        shaderName: String = "effects/pulse"
    ) throws -> [UInt8] {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let translation = try WPEShaderTranspiler.translateFragment(
            shaderName: shaderName,
            preprocessedSource: """
            uniform sampler2D g_Texture0;
            uniform sampler2D g_Texture1;
            uniform float g_Time;
            varying vec2 v_TexCoord;
            void main() {
                vec4 sampleColor = texSample2D(g_Texture0, v_TexCoord);
                float mask = texSample2D(g_Texture1, v_TexCoord).r;
                float pulse = smoothstep(0.0, 1.0, sin(g_Time) * 0.5 + 0.5);
                vec3 added = min(sampleColor.rgb + sampleColor.rgb, vec3(1.0));
                vec3 animated = mix(sampleColor.rgb, added, pulse);
                gl_FragColor = vec4(mix(sampleColor.rgb, animated, mask), sampleColor.a);
            }
            """,
            premultipliedInputSlots: [0], premultipliedOutput: true
        )
        let vertex = """
        vertex WPEStageIn pulse_probe_vertex(uint id [[vertex_id]]) {
            float2 positions[3] = {float2(-1, -1), float2(3, -1), float2(-1, 3)};
            WPEStageIn out;
            out.position = float4(positions[id], 0, 1);
            out.uv = float2(0.5);
            return out;
        }
        """
        let library = try device.makeLibrary(source: translation.mslSource + "\n" + vertex, options: nil)
        let pipeline = MTLRenderPipelineDescriptor()
        pipeline.vertexFunction = library.makeFunction(name: "pulse_probe_vertex")
        pipeline.fragmentFunction = try WPEMetalColorOutput.fragment(library: library, name: "wpe_translated_fragment", format: .rgba8Unorm)
        pipeline.colorAttachments[0].pixelFormat = .rgba8Unorm
        let state = try device.makeRenderPipelineState(descriptor: pipeline)
        func texture(_ format: MTLPixelFormat, _ bytes: [UInt8]) throws -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format, width: 1, height: 1, mipmapped: false
            )
            descriptor.storageMode = .shared
            descriptor.usage = [.shaderRead, .renderTarget]
            let result = try #require(device.makeTexture(descriptor: descriptor))
            bytes.withUnsafeBytes {
                result.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
                               withBytes: $0.baseAddress!, bytesPerRow: 4)
            }
            return result
        }
        let grey = UInt8((128.0 * Double(alpha) / 255).rounded())
        let source = try texture(.rgba8Unorm, [grey, grey, grey, alpha])
        let maskTexture = try texture(.rgba8Unorm, [mask, mask, mask, 255])
        let output = try texture(.rgba8Unorm, [0, 0, 0, 0])
        let queue = try #require(device.makeCommandQueue())
        let command = try #require(queue.makeCommandBuffer())
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = output
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        let encoder = try #require(command.makeRenderCommandEncoder(descriptor: descriptor))
        encoder.setRenderPipelineState(state)
        encoder.setFragmentTexture(source, index: 0)
        encoder.setFragmentTexture(maskTexture, index: 1)
        let sampler = try #require(device.makeSamplerState(descriptor: MTLSamplerDescriptor()))
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 1)
        var uniform = SIMD4<Float>(time, 0, 0, 0)
        encoder.setFragmentBytes(&uniform, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        #expect(command.status == .completed)
        var bytes = [UInt8](repeating: 0, count: 4)
        output.getBytes(&bytes, bytesPerRow: 4, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
        return bytes
    }
}
