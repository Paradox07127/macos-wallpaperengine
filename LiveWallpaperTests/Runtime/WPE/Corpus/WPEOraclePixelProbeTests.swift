#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import Metal
import Testing

@Suite("Oracle raw GPU pixel evidence")
struct WPEOraclePixelProbeTests {
    @Test("Terminal probes reuse the present shader without changing scene storage")
    func terminalStage() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let source = try makeTexture(device: device, format: .rgba16Float)
        let values: [Float16] = [4, 1, 0.5, 0.25]
        values.withUnsafeBytes {
            source.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 8)
        }
        let executor = try WPEMetalRenderExecutor(device: device)
        let terminal = try WPEOraclePixelProbe.terminalLinearTexture(source: source, executor: executor)
        let evidence = try WPEOraclePixelProbe.stageEvidence(
            stage: "terminal-linear", texture: terminal, coordinates: [[0, 0]],
            commandQueue: executor.commandQueue, frameOrdinal: 3, time: 6.05
        )
        let samples = try #require(evidence["samples"] as? [[String: Any]])
        let rgba = try #require(samples[0]["storageRGBA"] as? [Double])
        #expect(rgba[0] == 3 && rgba[1] == 3 && rgba[3] == 1)
        #expect(abs(rgba[2] - 0.21404114 * 3) < 0.002)
        #expect(evidence["stage"] as? String == "terminal-linear")
        #expect(evidence["transfer"] as? String == "linear")
        #expect(evidence["frameOrdinal"] as? Int == 3)
        let original = try WPEOraclePixelProbe.sample(texture: source, coordinates: [[0, 0]], commandQueue: executor.commandQueue)
        let originalSamples = try #require(original["samples"] as? [[String: Any]])
        #expect(originalSamples[0]["storageRGBA"] as? [Double] == [4, 1, 0.5, 0.25])
    }

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
        descriptor.usage = [.shaderRead, .renderTarget]
        return try #require(device.makeTexture(descriptor: descriptor))
    }
}
#endif
