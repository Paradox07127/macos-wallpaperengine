#if !LITE_BUILD && DEBUG
@testable import LiveWallpaper
import Metal
import XCTest

final class WPEParityVideoStretchTests: XCTestCase {
    /// A decoded frame smaller than the fixed video texture covers all of it.
    func testStretchFillsTheWholeTarget() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let frame = try texture(size: 2, device: device)
        // BGRA: red, green / blue, white, all opaque.
        let texels: [UInt8] = [0, 0, 255, 255, 0, 255, 0, 255, 255, 0, 0, 255, 255, 255, 255, 255]
        frame.replace(region: MTLRegionMake2D(0, 0, 2, 2), mipmapLevel: 0, withBytes: texels, bytesPerRow: 8)
        let target = try texture(size: 4, device: device)
        target.replace(region: MTLRegionMake2D(0, 0, 4, 4), mipmapLevel: 0,
                       withBytes: [UInt8](repeating: 0, count: 64), bytesPerRow: 16)

        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        try WPEParityVideoTextures.stretch(frame, into: target, scaler: WPEParityVideoTextures.scaler(device: device),
                                           commandBuffer: commandBuffer)
        commandBuffer.commit()
        await commandBuffer.completed()
        XCTAssertNil(commandBuffer.error)

        var pixels = [UInt8](repeating: 0, count: 64)
        target.getBytes(&pixels, bytesPerRow: 16, from: MTLRegionMake2D(0, 0, 4, 4), mipmapLevel: 0)
        for texel in 0 ..< 16 {
            XCTAssertEqual(pixels[texel * 4 + 3], 255, "texel \(texel) alpha")
            XCTAssertNotEqual(Array(pixels[texel * 4 ..< texel * 4 + 3]), [0, 0, 0], "texel \(texel) colour")
        }
        XCTAssertEqual(Array(pixels[0 ..< 4]), Array(texels[0 ..< 4]), "top-left corner")
        XCTAssertEqual(Array(pixels[60 ..< 64]), Array(texels[12 ..< 16]), "bottom-right corner")
    }

    private func texture(size: Int, device: MTLDevice) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: size, height: size,
                                                                  mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .shaderWrite]
        return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    }
}
#endif
