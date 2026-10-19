#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import Testing

@Suite("WPE data texture colour space")
struct WPEDataTextureColorSpaceTests {
    @Test("Parity colour and mask uploads sample their encoded channels without alpha conversion", arguments: [UInt8(0), UInt8(128)])
    func authoredColourMaskAndCoverageRemainIndependent(alpha: UInt8) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let color = try WPEParityTextureLoader.load(span: .init(data: Self.tex(format: 0, bytes: [192, 128, 64, alpha])), device: device)
        let mask = try WPEParityTextureLoader.load(span: .init(data: Self.tex(format: 9, bytes: [128])), device: device)
        #expect(color.texture.pixelFormat == .rgba8Unorm)
        #expect(mask.texture.pixelFormat == .r8Unorm)
        let library = try device.makeLibrary(source: """
        #include <metal_stdlib>
        using namespace metal;
        kernel void sample_data(texture2d<float> color [[texture(0)]], texture2d<float> mask [[texture(1)]],
                                device float4 *values [[buffer(0)]]) {
            constexpr sampler point(filter::nearest, address::clamp_to_edge);
            values[0] = color.sample(point, float2(0.5));
            values[1] = mask.sample(point, float2(0.5));
        }
        """, options: nil)
        let pipeline = try device.makeComputePipelineState(function: #require(library.makeFunction(name: "sample_data")))
        let output = try #require(device.makeBuffer(length: 2 * MemoryLayout<SIMD4<Float>>.stride, options: .storageModeShared))
        let command = try #require(device.makeCommandQueue()?.makeCommandBuffer())
        let encoder = try #require(command.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(color.texture, index: 0)
        encoder.setTexture(mask.texture, index: 1)
        encoder.setBuffer(output, offset: 0, index: 0)
        encoder.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        try #require(command.status == .completed && command.error == nil)
        let actual = output.contents().bindMemory(to: SIMD4<Float>.self, capacity: 2)
        let expected = [SIMD4<Float>(192, 128, 64, Float(alpha)) / 255, SIMD4<Float>(128.0 / 255, 0, 0, 1)]
        for pixel in 0 ..< 2 {
            for channel in 0 ..< 4 {
                #expect(abs(actual[pixel][channel] - expected[pixel][channel]) < 0.0001)
            }
        }
    }

    private static func tex(format: UInt32, bytes: [UInt8]) -> Data {
        var data = Data("TEXV0004\0".utf8)
        for value: UInt32 in [format, 0, 1, 1, 1, 1, 1, 1, 1, UInt32(bytes.count)] {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: bytes)
        return data
    }
}
#endif
