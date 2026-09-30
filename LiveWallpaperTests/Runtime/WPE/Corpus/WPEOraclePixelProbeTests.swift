#if !LITE_BUILD
import Foundation
import Metal
import Testing

@Suite("Oracle raw GPU pixel evidence")
struct WPEOraclePixelProbeTests {
    @Test("sRGB storage keeps encoded channels and coverage; no alpha division")
    func encodedStorage() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let texture = try makeTexture(device: device, format: .rgba8Unorm_srgb)
        let bytes: [UInt8] = [64, 32, 16, 128]
        bytes.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 4) }
        let queue = try #require(device.makeCommandQueue())
        let probe = try WPEOraclePixelProbe.sample(texture: texture, coordinates: [[0, 0]], commandQueue: queue)
        let samples = try #require(probe["samples"] as? [[String: Any]])
        #expect(samples[0]["storageRGBA"] as? [Double] == bytes.map { Double($0) / 255 })
    }

    @Test("HDR storage retains overbright and zero-coverage additive values")
    func floatingStorage() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let texture = try makeTexture(device: device, format: .rgba16Float)
        let values: [Float16] = [4, 1, 0.5, 0]
        values.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 8) }
        let queue = try #require(device.makeCommandQueue())
        let probe = try WPEOraclePixelProbe.sample(texture: texture, coordinates: [[0, 0]], commandQueue: queue)
        let samples = try #require(probe["samples"] as? [[String: Any]])
        #expect(samples[0]["storageRGBA"] as? [Double] == [4, 1, 0.5, 0])
    }

    @Test("Invalid coordinates fail rather than sampling a different pixel")
    func invalidCoordinates() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let texture = try makeTexture(device: device, format: .rgba8Unorm)
        let queue = try #require(device.makeCommandQueue())
        for coordinates in [[[1, 0]], [[-1, 0]], [[0]], [[0, 0, 0]]] {
            #expect(throws: (any Error).self) {
                try WPEOraclePixelProbe.sample(texture: texture, coordinates: coordinates, commandQueue: queue)
            }
        }
    }

    private func makeTexture(device: MTLDevice, format: MTLPixelFormat) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: 1, height: 1, mipmapped: false)
        descriptor.storageMode = .shared
        return try #require(device.makeTexture(descriptor: descriptor))
    }
}
#endif
