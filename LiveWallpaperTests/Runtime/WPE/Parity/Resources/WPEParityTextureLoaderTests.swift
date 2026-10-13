#if !LITE_BUILD && DEBUG
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import XCTest

final class WPEParityTextureLoaderTests: XCTestCase {
    private struct Mip {
        let width: Int
        let height: Int
        let bytes: Data
    }

    /// These are native resource reads, so missing channels must come from Metal's R/RG format defaults.
    /// Expanding to luminance/alpha or passing through a premultiplied CGImage changes the independent values.
    func testRawChannelsAndEveryAuthoredMipReachGPU() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let rgba = try load(tex(format: 0, images: [[
            solid(4, 4, [192, 128, 64, 0]), solid(2, 2, [17, 33, 65, 128]), solid(1, 1, [1, 2, 3, 255]),
        ]]), device)
        XCTAssertEqual(rgba.texture.pixelFormat, .rgba8Unorm)
        XCTAssertEqual(rgba.texture.mipmapLevelCount, 3)
        let mipValues = try read(rgba.texture, levels: [0, 1, 2], device: device)
        assertPixel(mipValues[0], SIMD4(192, 128, 64, 0) / 255)
        assertPixel(mipValues[1], SIMD4(17, 33, 65, 128) / 255)
        assertPixel(mipValues[2], SIMD4(1, 2, 3, 255) / 255)

        let r = try load(tex(format: 9, images: [[solid(1, 1, [73])]]), device)
        XCTAssertEqual(r.texture.pixelFormat, .r8Unorm)
        try assertPixel(read(r.texture, levels: [0], device: device)[0], SIMD4(73.0 / 255, 0, 0, 1))
        let rg = try load(tex(format: 8, images: [[solid(1, 1, [73, 149])]]), device)
        XCTAssertEqual(rg.texture.pixelFormat, .rg8Unorm)
        try assertPixel(read(rg.texture, levels: [0], device: device)[0], SIMD4(73.0 / 255, 149.0 / 255, 0, 1))

        var word: UInt32 = (512 | (341 << 10) | (1023 << 20) | (2 << 30)).littleEndian
        let packed = withUnsafeBytes(of: &word) { Data($0) }
        let rgb10 = try load(tex(format: 13, images: [[Mip(width: 1, height: 1, bytes: packed)]]), device)
        XCTAssertEqual(rgb10.texture.pixelFormat, .rgb10a2Unorm)
        try assertPixel(read(rgb10.texture, levels: [0], device: device)[0], SIMD4(512.0 / 1023, 341.0 / 1023, 1, 2.0 / 3))
    }

    func testBCBlocksAndSmallMipTailsRemainCompressed() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        guard device.supportsBCTextureCompression else { throw XCTSkip("Metal device has no BC texture support") }
        let cases: [(Int, MTLPixelFormat)] = [(7, .bc1_rgba), (6, .bc2_rgba), (4, .bc3_rgba), (12, .bc7_rgbaUnorm)]
        let endpoints: [UInt16] = [0xF800, 0x07E0, 0x001F, 0xFFFF]
        let expected: [SIMD4<Float>] = [SIMD4(1, 0, 0, 1), SIMD4(0, 1, 0, 1), SIMD4(0, 0, 1, 1), .one]
        for (format, pixelFormat) in cases {
            var mipmaps: [Mip] = []
            for (index, size) in [8, 4, 2, 1].enumerated() {
                let colorBlock = [UInt8(truncatingIfNeeded: endpoints[index]), UInt8(endpoints[index] >> 8), 0, 0, 0, 0, 0, 0]
                let block: [UInt8] = switch format {
                case 7: colorBlock
                case 6: [UInt8](repeating: 255, count: 8) + colorBlock
                case 4: [255, 255, 0, 0, 0, 0, 0, 0] + colorBlock
                default:
                    // BC7 mode 6: all endpoints, p-bits and indices zero = transparent black.
                    [0x40] + [UInt8](repeating: 0, count: 15)
                }
                let count = max((size + 3) / 4, 1)
                mipmaps.append(Mip(width: size, height: size, bytes: Data((0 ..< count * count).flatMap { _ in block })))
            }
            let loaded = try load(tex(format: UInt32(format), images: [mipmaps]), device)
            XCTAssertEqual(loaded.texture.pixelFormat, pixelFormat)
            XCTAssertEqual(loaded.texture.mipmapLevelCount, 4)
            let values = try read(loaded.texture, levels: [0, 1, 2, 3], device: device)
            for index in values.indices {
                assertPixel(values[index], format == 12 ? .zero : expected[index])
            }
            // A format assertion alone could pass with zero/unuploaded blocks. Check the authored BC7 mode marker.
            if format == 12 {
                var bytes = [UInt8](repeating: 0, count: 16)
                bytes.withUnsafeMutableBytes {
                    loaded.texture.getBytes($0.baseAddress!, bytesPerRow: 16,
                                            from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 3)
                }
                XCTAssertEqual(bytes, [0x40] + [UInt8](repeating: 0, count: 15))
            }
        }
    }

    func testEncodedImagesPreserveTheirAuthoredMipChain() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        // Fixed RGBA PNG bitstreams, independently packed with PNG/zlib; each authored level has a different colour.
        let pngs = [
            "iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAYAAACp8Z5+AAAAEklEQVR4nGP4z8DwHxkzkC4AADxAH+HggXe0AAAAAElFTkSuQmCC",
            "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAADklEQVR4nGNg+A+FMAYAQ84H+fei4u8AAAAASUVORK5CYII=",
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYPj/HwADAgH/5ncLrgAAAABJRU5ErkJggg==",
        ]
        let mipmaps = try zip([4, 2, 1], pngs).map { size, png in
            try Mip(width: size, height: size, bytes: XCTUnwrap(Data(base64Encoded: png)))
        }
        let loaded = try load(tex(format: 0, images: [mipmaps], encoded: true), device)
        XCTAssertEqual(loaded.texture.pixelFormat, .rgba8Unorm)
        XCTAssertEqual(loaded.texture.mipmapLevelCount, 3)
        let values = try read(loaded.texture, levels: [0, 1, 2], device: device)
        assertPixel(values[0], SIMD4(1, 0, 0, 1))
        assertPixel(values[1], SIMD4(0, 1, 0, 1))
        assertPixel(values[2], SIMD4(0, 0, 1, 1))
    }

    func testSpriteImageIDsShareUploadsAndKeepMipChainsAndAffineFrames() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let images = [
            [solid(2, 2, [255, 0, 0, 255]), solid(1, 1, [0, 255, 0, 255])],
            [solid(2, 2, [0, 0, 255, 255]), solid(1, 1, [255, 255, 255, 255])],
        ]
        var data = tex(format: 0, images: images, flags: 4)
        magic("TEXS0002", to: &data)
        append(3, to: &data)
        for id: UInt32 in [1, 0, 1] {
            append(id, to: &data)
            for value: Float in [0.125, 1, 0, 1, 1, -1, 1] {
                append(value.bitPattern, to: &data)
            }
        }
        let loaded = try load(data, device)
        XCTAssertEqual(loaded.sprites.count, 3)
        XCTAssertTrue(loaded.sprites[0].texture === loaded.sprites[2].texture)
        XCTAssertTrue(loaded.texture === loaded.sprites[1].texture)
        XCTAssertFalse(loaded.sprites[0].texture === loaded.texture)
        for sprite in loaded.sprites {
            XCTAssertEqual(sprite.texture.mipmapLevelCount, 2)
            XCTAssertEqual(sprite.duration, 0.125)
            XCTAssertEqual(sprite.frame.rotation, SIMD4(0.5, 0.5, -0.5, 0.5))
            XCTAssertEqual(sprite.frame.translation, SIMD2(0.5, 0))
        }
        let values = try read(loaded.sprites[0].texture, levels: [0, 1], device: device)
        assertPixel(values[0], SIMD4(0, 0, 1, 1))
        assertPixel(values[1], .one)
    }

    func testUnsupportedAndMalformedResourcesDoNotBecomeSuccessful2DImages() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let volume = tex(format: 0, images: [[solid(1, 1, [1, 2, 3, 4])]], flags: 0x40, depth: 32)
        XCTAssertThrowsError(try load(volume, device)) {
            XCTAssertEqual($0 as? WPETexDecodeError, .unsupportedTextureDimension(depth: 32))
        }
        let float = tex(format: 14, images: [[solid(1, 1, [0, 0, 0, 0, 0, 0, 0, 0])]])
        XCTAssertThrowsError(try load(float, device)) {
            XCTAssertEqual($0 as? WPETexDecodeError, .unsupportedFormat(code: 14))
        }
        let truncated = tex(format: 0, images: [[solid(1, 1, [1, 2, 3])]])
        XCTAssertThrowsError(try load(truncated, device))
        // Native 14015c8d0 uses only bit0 for LZ4; other bits are preserved, not treated as compression.
        var rawFlags = tex(format: 0, images: [[solid(1, 1, [73, 149, 211, 255])]])
        rawFlags[75] = 2
        let metadata = try WPETexDecoder().extractRawMetadata(data: rawFlags).get()
        XCTAssertEqual(metadata.bitmap.largestMipmap?.compressionFlags, 2)
        XCTAssertEqual(metadata.bitmap.largestMipmap?.isCompressed, false)
        let raw = try load(rawFlags, device)
        try assertPixel(read(raw.texture, levels: [0], device: device)[0], SIMD4(73, 149, 211, 255) / 255)
        let discontinuous = tex(format: 0, images: [[solid(4, 4, [0, 0, 0, 0]), solid(1, 1, [0, 0, 0, 0])]])
        XCTAssertThrowsError(try load(discontinuous, device))
        let noSampling = tex(format: 0, images: [[solid(1, 1, [1, 2, 3, 4])], [solid(1, 1, [5, 6, 7, 8])]])
        XCTAssertThrowsError(try load(noSampling, device)) { error in
            guard case let WPEParityTextureLoader.Failure.unsupportedSpriteWithoutTEXS(imageID) = error else {
                return XCTFail("Expected a missing TEXS descriptor diagnostic: \(error)")
            }
            XCTAssertEqual(imageID, 0)
        }
    }

    func testVersionFourInlineRecordsUploadWithoutVersionFiveTagsOrTailWord() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        var data = Data()
        magic("TEXV0004", to: &data)
        for value: UInt32 in [0, 0, 1, 1, 1, 1, 1, 1, 1, 4] {
            append(value, to: &data)
        }
        data.append(contentsOf: [61, 127, 193, 255])
        let loaded = try load(data, device)
        XCTAssertEqual(loaded.info.containerVersion, 4)
        XCTAssertEqual(loaded.info.infoVersion, 0)
        XCTAssertEqual(loaded.info.unknownInt0, 0)
        try assertPixel(read(loaded.texture, levels: [0], device: device)[0], SIMD4(61, 127, 193, 255) / 255)
        data.replaceSubrange(0 ..< 8, with: Data("TEXV0006".utf8))
        XCTAssertThrowsError(try load(data, device)) {
            XCTAssertEqual($0 as? WPETexDecodeError, .unsupportedContainer(magic: "TEXV0006"))
        }
    }

    private func solid(_ width: Int, _ height: Int, _ pixel: [UInt8]) -> Mip {
        Mip(width: width, height: height, bytes: Data((0 ..< width * height).flatMap { _ in pixel }))
    }

    private func tex(format: UInt32, images: [[Mip]], flags: UInt32 = 0, depth: UInt32? = nil,
                     encoded: Bool = false) -> Data {
        let base = images[0][0]
        var data = Data()
        magic("TEXV0005", to: &data)
        magic("TEXI0001", to: &data)
        for value in [format, flags, UInt32(base.width), UInt32(base.height), UInt32(base.width), UInt32(base.height)] {
            append(value, to: &data)
        }
        if let depth {
            append(depth, to: &data)
        }
        append(0, to: &data)
        magic("TEXB0003", to: &data)
        append(UInt32(images.count), to: &data)
        append(encoded ? 0 : UInt32.max, to: &data)
        for image in images {
            append(UInt32(image.count), to: &data)
            for mip in image {
                append(UInt32(mip.width), to: &data)
                append(UInt32(mip.height), to: &data)
                if let depth {
                    append(depth, to: &data)
                }
                for value in [UInt32(0), UInt32(mip.bytes.count), UInt32(mip.bytes.count)] {
                    append(value, to: &data)
                }
                data.append(mip.bytes)
            }
        }
        return data
    }

    private func magic(_ value: String, to data: inout Data) {
        data.append(contentsOf: value.utf8); data.append(0)
    }

    private func append(_ value: UInt32, to data: inout Data) {
        var value = value.littleEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }

    private func load(_ data: Data, _ device: MTLDevice) throws -> WPEParityTextureLoader.Loaded {
        try WPEParityTextureLoader.load(span: WPEMappedByteSpan(data: data), device: device)
    }

    private func assertPixel(_ actual: SIMD4<Float>, _ expected: SIMD4<Float>,
                             file: StaticString = #filePath, line: UInt = #line) {
        for lane in 0 ..< 4 {
            XCTAssertEqual(actual[lane], expected[lane], accuracy: 0.00001, file: file, line: line)
        }
    }

    private func read(_ texture: MTLTexture, levels: [UInt32], device: MTLDevice) throws -> [SIMD4<Float>] {
        let library = try device.makeLibrary(source: """
        #include <metal_stdlib>
        using namespace metal;
        kernel void read_authored_mips(texture2d<float, access::read> source [[texture(0)]],
            const device uint *levels [[buffer(0)]], device float4 *values [[buffer(1)]],
            uint index [[thread_position_in_grid]]) { values[index] = source.read(uint2(0), levels[index]); }
        """, options: nil)
        let function = try XCTUnwrap(library.makeFunction(name: "read_authored_mips"))
        let pipeline = try device.makeComputePipelineState(function: function)
        let input = try XCTUnwrap(device.makeBuffer(bytes: levels, length: levels.count * 4, options: .storageModeShared))
        let output = try XCTUnwrap(device.makeBuffer(length: levels.count * 16, options: .storageModeShared))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(command.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(texture, index: 0)
        encoder.setBuffer(input, offset: 0, index: 0)
        encoder.setBuffer(output, offset: 0, index: 1)
        encoder.dispatchThreads(MTLSize(width: levels.count, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed)
        if let error = command.error {
            throw error
        }
        return Array(UnsafeBufferPointer(start: output.contents().bindMemory(to: SIMD4<Float>.self,
                                                                             capacity: levels.count), count: levels.count))
    }
}
#endif
