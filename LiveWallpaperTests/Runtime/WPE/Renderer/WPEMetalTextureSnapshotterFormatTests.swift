#if !LITE_BUILD
import AppKit
@testable import LiveWallpaper
import Metal
import Testing

@Suite("WPEMetalTextureSnapshotter formats")
struct WPEMetalTextureSnapshotterFormatTests {
    private func makeTexture(format: MTLPixelFormat, width: Int, height: Int) throws -> MTLTexture {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        return try #require(device.makeTexture(descriptor: descriptor))
    }

    private func pixel(of image: NSImage, x: Int) throws -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let cg = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let data = try #require(cg.dataProvider?.data as Data?)
        let index = x * 4
        return (data[index], data[index + 1], data[index + 2], data[index + 3])
    }

    @Test("BGRA8 sources are swizzled to RGBA")
    func bgraSwizzle() throws {
        let texture = try makeTexture(format: .bgra8Unorm, width: 1, height: 1)
        var bytes: [UInt8] = [10, 20, 30, 255]
        texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &bytes, bytesPerRow: 4)
        let image = try #require(WPEMetalTextureSnapshotter.shared.snapshot(from: texture))
        let px = try pixel(of: image, x: 0)
        #expect(px.r == 30 && px.g == 20 && px.b == 10 && px.a == 255)
    }

    @Test("RGBA16Float authored HDR posters apply the measured terminal transfer")
    func rgba16FloatConverts() throws {
        let texture = try makeTexture(format: .rgba16Float, width: 2, height: 1)
        var halves: [UInt16] = [
            0x4000, 0x3C00, 0x0000, 0x3C00,
            0x3800, 0x3800, 0x3800, 0x3C00,
        ]
        texture.replace(region: MTLRegionMake2D(0, 0, 2, 1), mipmapLevel: 0, withBytes: &halves, bytesPerRow: 16)
        let image = try #require(WPEMetalTextureSnapshotter.shared.snapshot(from: texture))
        let hot = try pixel(of: image, x: 0)
        #expect(hot.r == 255 && hot.g == 255 && hot.b == 0 && hot.a == 255)
        let mid = try pixel(of: image, x: 1)
        #expect(abs(Int(mid.r) - 210) <= 2 && abs(Int(mid.g) - 210) <= 2 && abs(Int(mid.b) - 210) <= 2)
    }
}
#endif
