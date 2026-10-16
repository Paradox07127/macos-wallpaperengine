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
        let depth: Int
        let bytes: Data
        let compressionFlags: UInt32
        let decompressedByteCount: UInt32?

        init(width: Int, height: Int, depth: Int = 1, bytes: Data,
             compressionFlags: UInt32 = 0, decompressedByteCount: UInt32? = nil) {
            self.width = width
            self.height = height
            self.depth = depth
            self.bytes = bytes
            self.compressionFlags = compressionFlags
            self.decompressedByteCount = decompressedByteCount
        }
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

    func testRawFloatAndNormalizedSixteenBitFormatsPreserveBitsAndMipsThroughGPU() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        func halfBytes(_ words: [UInt16]) -> Data {
            Data(words.flatMap { [UInt8(truncatingIfNeeded: $0), UInt8($0 >> 8)] })
        }
        func floatBytes(_ words: [UInt32]) -> Data {
            Data(words.flatMap { word in (0 ..< 4).map { UInt8(truncatingIfNeeded: word >> ($0 * 8)) } })
        }
        var cases: [(UInt32, MTLPixelFormat, [Mip], [SIMD4<Float>])] = [
            (10, .rg16Float, [
                Mip(width: 2, height: 1, bytes: halfBytes([0xC000, 0x4300, 0x7E35, 0x8000])),
                Mip(width: 1, height: 1, bytes: halfBytes([0x3800, 0xC400])),
            ], [SIMD4(-2, 3.5, 0, 1), SIMD4(0.5, -4, 0, 1)]),
            (11, .r16Float, [
                Mip(width: 2, height: 1, bytes: halfBytes([0xC000, 0x7E35])),
                Mip(width: 1, height: 1, bytes: halfBytes([0x4300])),
            ], [SIMD4(-2, 0, 0, 1), SIMD4(3.5, 0, 0, 1)]),
            (16, .r32Float, [
                Mip(width: 4, height: 1, bytes: floatBytes([0xC050_0000, 0x422A_0000, 0x7FC0_1234, 0x8000_0000])),
                Mip(width: 2, height: 1, bytes: floatBytes([0x40F8_0000, 0xC100_0000])),
                Mip(width: 1, height: 1, bytes: floatBytes([0x4480_0000])),
            ], [SIMD4(-3.25, 0, 0, 1), SIMD4(7.75, 0, 0, 1), SIMD4(1024, 0, 0, 1)]),
        ]
        for code: UInt32 in [14, 15] {
            cases.append((code, .rgba16Float, [
                Mip(width: 2, height: 1, bytes: halfBytes([0xC000, 0x4300, 0x3800, 0xB400, 0x8000, 0x7E35, 0x7C00, 0xFC00])),
                Mip(width: 1, height: 1, bytes: halfBytes([0x4400, 0xC400, 0x3C00, 0])),
            ], [SIMD4<Float>(-2, 3.5, 0.5, -0.25), SIMD4<Float>(4, -4, 1, 0)]))
        }
        for code: UInt32 in [17, 18] {
            cases.append((code, .rgba16Unorm, [
                Mip(width: 2, height: 1, bytes: halfBytes([0, 32768, 65535, 16384, 1, 3, 5, 7])),
                Mip(width: 1, height: 1, bytes: halfBytes([65535, 0, 32768, 65535])),
            ], [SIMD4<Float>(0, 32768.0 / 65535, 1, 16384.0 / 65535), SIMD4<Float>(1, 0, 32768.0 / 65535, 1)]))
        }
        for code: UInt32 in [19, 20] {
            cases.append((code, .rgba16Snorm, [
                Mip(width: 2, height: 1, bytes: halfBytes([0x8000, 0x7FFF, 0, 0xC000, 1, 3, 5, 7])),
                Mip(width: 1, height: 1, bytes: halfBytes([0x8001, 0x2000, 0xE000, 0])),
            ], [SIMD4<Float>(-1, 1, 0, -16384.0 / 32767), SIMD4<Float>(-1, 8192.0 / 32767, -8192.0 / 32767, 0)]))
        }
        for (code, pixelFormat, mipmaps, expected) in cases {
            let loaded = try load(tex(format: code, images: [mipmaps]), device)
            XCTAssertEqual(loaded.info.textureFormatCode, Int(code))
            XCTAssertEqual(loaded.texture.pixelFormat, pixelFormat)
            XCTAssertEqual(loaded.texture.mipmapLevelCount, mipmaps.count)
            let values = try read(loaded.texture, levels: mipmaps.indices.map(UInt32.init), device: device)
            for index in values.indices {
                assertPixel(values[index], expected[index])
                // Sampling can canonicalize NaNs. Raw texture readback independently proves every payload bit,
                // including NaN payloads, negative zero, signed normalized minimum and all authored mips.
                let mip = mipmaps[index]
                var copied = Data(count: mip.bytes.count)
                copied.withUnsafeMutableBytes {
                    loaded.texture.getBytes($0.baseAddress!, bytesPerRow: mip.bytes.count / mip.height,
                                            from: MTLRegionMake2D(0, 0, mip.width, mip.height), mipmapLevel: index)
                }
                XCTAssertEqual(copied, mip.bytes)
            }
            // No evidence supports these extended formats through the encoded-image bridge.
            let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYPj/HwADAgH/5ncLrgAAAABJRU5ErkJggg=="))
            XCTAssertThrowsError(try load(tex(format: code, images: [[Mip(width: 1, height: 1, bytes: png)]], encoded: true), device)) {
                XCTAssertEqual($0 as? WPETexDecodeError, .unsupportedFormat(code: Int(code)))
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

    func testRawVolumesSampleEveryXYZAndMipAndPreservePayloadBits() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        // Native 1400ec220 supplies a dense row pitch and a width*height slice pitch. Non-cubic geometry,
        // different z planes and every authored mip make a 2D slice-zero upload observably wrong.
        let formats: [(UInt32, MTLPixelFormat)] = [
            (0, .rgba8Unorm), (8, .rg8Unorm), (9, .r8Unorm), (10, .rg16Float), (11, .r16Float),
            (13, .rgb10a2Unorm), (14, .rgba16Float), (15, .rgba16Float), (16, .r32Float),
            (17, .rgba16Unorm), (18, .rgba16Unorm), (19, .rgba16Snorm), (20, .rgba16Snorm),
        ]
        for (code, pixelFormat) in formats {
            var coordinates: [SIMD4<UInt32>] = []
            var expected: [SIMD4<Float>] = []
            let mipmaps = [(4, 2, 2), (2, 1, 1), (1, 1, 1)].enumerated().map { level, size -> Mip in
                let (width, height, depth) = size
                var bytes = Data()
                for z in 0 ..< depth {
                    for y in 0 ..< height {
                        for x in 0 ..< width {
                            let index = (z * height + y) * width + x
                            var value = SIMD4<Float>(0, 0, 0, 1)
                            coordinates.append(SIMD4(UInt32(x), UInt32(y), UInt32(z), UInt32(level)))
                            switch code {
                            case 0, 8, 9:
                                let channels = code == 0 ? 4 : code == 8 ? 2 : 1
                                let pixel = [19 + index * 11, 51 + z * 60 + level * 10, 83 + y * 40, 107 + x * 23]
                                for lane in 0 ..< channels {
                                    bytes.append(UInt8(pixel[lane]))
                                    value[lane] = Float(pixel[lane]) / 255
                                }
                            case 13:
                                let pixel = [(index * 53 + 1) % 1024, (z * 347 + level * 113 + 2) % 1024,
                                             (y * 401 + x * 11 + 3) % 1024, (x + level) % 4]
                                append(UInt32(pixel[0] | pixel[1] << 10 | pixel[2] << 20 | pixel[3] << 30), to: &bytes)
                                value = SIMD4(Float(pixel[0]) / 1023, Float(pixel[1]) / 1023,
                                              Float(pixel[2]) / 1023, Float(pixel[3]) / 3)
                            case 10, 11, 14, 15, 16:
                                let channels = code == 10 ? 2 : code == 11 || code == 16 ? 1 : 4
                                let pixel = [Float(index) - 3.5, Float(z + level) + 2.25, -Float(y + 1), Float(x) - 0.5]
                                for lane in 0 ..< channels {
                                    let negativeZero = level == 0 && index == 14 && lane == 0
                                    value[lane] = negativeZero ? -0.0 : pixel[lane]
                                    if code == 16 {
                                        append(negativeZero ? 0x8000_0000 : pixel[lane].bitPattern, to: &bytes)
                                    } else {
                                        let word: UInt16 = negativeZero ? 0x8000 : Float16(pixel[lane]).bitPattern
                                        bytes.append(contentsOf: [UInt8(truncatingIfNeeded: word), UInt8(word >> 8)])
                                    }
                                }
                            default:
                                for lane in 0 ..< 4 {
                                    let word: UInt16
                                    if code == 17 || code == 18 {
                                        word = UInt16((index * 1000 + lane * 7000 + level * 113) % 65536)
                                        value[lane] = Float(word) / 65535
                                    } else {
                                        let signed: Int16 = index == 0 && lane == 0 ? .min : Int16(-24000 + index * 1024 + lane * 4096)
                                        word = UInt16(bitPattern: signed)
                                        value[lane] = max(-1, Float(signed) / 32767)
                                    }
                                    bytes.append(contentsOf: [UInt8(truncatingIfNeeded: word), UInt8(word >> 8)])
                                }
                            }
                            expected.append(value)
                        }
                    }
                }
                return Mip(width: width, height: height, depth: depth, bytes: bytes)
            }
            let loaded = try load(tex(format: code, images: [mipmaps], flags: 0x40, depth: 2), device)
            XCTAssertEqual(loaded.texture.textureType, .type3D)
            XCTAssertEqual(loaded.texture.pixelFormat, pixelFormat)
            XCTAssertEqual(loaded.texture.width, 4)
            XCTAssertEqual(loaded.texture.height, 2)
            XCTAssertEqual(loaded.texture.depth, 2)
            XCTAssertEqual(loaded.texture.mipmapLevelCount, 3)
            XCTAssertTrue(loaded.sprites.isEmpty)
            let sampled = try sampleVolume(loaded.texture, coordinates: coordinates, device: device)
            XCTAssertEqual(sampled.count, expected.count)
            for index in sampled.indices {
                for lane in 0 ..< 4 {
                    XCTAssertEqual(sampled[index][lane], expected[index][lane], accuracy: 0.00001)
                }
            }
            // Independently verify all z planes and every mip, including negative zero and normalized
            // minimum values, which sampled float values cannot prove bit-for-bit.
            for (level, mip) in mipmaps.enumerated() {
                var copied = Data(count: mip.bytes.count)
                copied.withUnsafeMutableBytes {
                    loaded.texture.getBytes($0.baseAddress!, bytesPerRow: mip.bytes.count / mip.height / mip.depth,
                                            bytesPerImage: mip.depth > 1 ? mip.bytes.count / mip.depth : 0,
                                            from: MTLRegionMake3D(0, 0, 0, mip.width, mip.height, mip.depth),
                                            mipmapLevel: level, slice: 0)
                }
                XCTAssertEqual(copied, mip.bytes)
            }
        }
        // The authored flag defines dimensionality even when the actual depth is one.
        let unit = try load(tex(format: 0, images: [[solid(1, 1, [7, 11, 13, 17])]], flags: 0x40, depth: 1), device)
        XCTAssertEqual(unit.texture.textureType, .type3D)
        try assertPixel(sampleVolume(unit.texture, coordinates: [.zero], device: device)[0], SIMD4(7, 11, 13, 17) / 255)
    }

    func testSpriteImageIDsShareUploadsAndKeepMipChainsAndAffineFrames() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let atlas = Mip(width: 4, height: 2, bytes: Data([
            0, 0, 255, 255, 0, 0, 255, 255, 0, 0, 255, 255, 0, 0, 255, 255,
            0, 255, 0, 255, 0, 255, 0, 255, 255, 0, 0, 255, 0, 255, 0, 255,
        ]))
        let images = [
            [solid(4, 2, [255, 0, 0, 255]), solid(2, 1, [0, 255, 0, 255]), solid(1, 1, [255, 255, 255, 255])],
            [atlas, solid(2, 1, [0, 255, 255, 255]), solid(1, 1, [255, 255, 255, 255])],
        ]
        var data = tex(format: 0, images: images, flags: 4)
        magic("TEXS0002", to: &data)
        append(3, to: &data)
        for id: UInt32 in [1, 0, 1] {
            append(id, to: &data)
            for value: Float in [0.125, 1, 0, 2, 1, -1, 1] {
                append(value.bitPattern, to: &data)
            }
        }
        let loaded = try load(data, device)
        XCTAssertEqual(loaded.sprites.count, 3)
        XCTAssertTrue(loaded.sprites[0].texture === loaded.sprites[2].texture)
        XCTAssertTrue(loaded.texture === loaded.sprites[1].texture)
        XCTAssertFalse(loaded.sprites[0].texture === loaded.texture)
        for sprite in loaded.sprites {
            XCTAssertEqual(sprite.texture.mipmapLevelCount, 3)
            XCTAssertEqual(sprite.duration, 0.125)
            XCTAssertEqual(sprite.frame.rotation, SIMD4(0.5, 0.5, -0.25, 0.5))
            XCTAssertEqual(sprite.frame.translation, SIMD2(0.25, 0))
        }
        let values = try read(loaded.sprites[0].texture, levels: [0, 1, 2], device: device)
        assertPixel(values[0], SIMD4(0, 0, 1, 1))
        assertPixel(values[1], SIMD4(0, 1, 1, 1))
        assertPixel(values[2], .one)
        // At uv=(0.6,0.5), native rotation selects the green second row. The old swapped denominators
        // select blue in row zero, so this observes the affine error through actual GPU sampling.
        try assertPixel(sample(loaded.sprites[0], uv: SIMD2(0.6, 0.5), device: device), SIMD4(0, 1, 0, 1))
        // At uv=(0.3,0.5), correct reconstruction selects blue row zero. Multiplying normalized widthY
        // by width instead of height makes the GPU select green row one.
        try assertPixel(sample(loaded.sprites[0], uv: SIMD2(0.3, 0.5), device: device), SIMD4(0, 0, 1, 1))
        // Independently catch heightX multiplied by height: x moves from column one to the red column two.
        try assertPixel(sample(loaded.sprites[0], uv: SIMD2(0.65, 0.4), device: device), SIMD4(0, 1, 0, 1))
    }

    func testUnsupportedAndMalformedResourcesDoNotBecomeSuccessful2DImages() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let volume = tex(format: 0, images: [[solid(1, 1, [1, 2, 3, 4])]], flags: 0x40, depth: 32, encoded: true)
        XCTAssertThrowsError(try load(volume, device)) {
            XCTAssertEqual($0 as? WPETexDecodeError, .unsupportedTextureDimension(depth: 32))
        }
        for code: UInt32 in [4, 6, 7, 12, 22, 23, 24] {
            let unsupported = tex(format: code, images: [[solid(1, 1, [0, 0, 0, 0, 0, 0, 0, 0])]], flags: 0x40, depth: 1)
            XCTAssertThrowsError(try load(unsupported, device)) {
                XCTAssertEqual($0 as? WPETexDecodeError, .unsupportedFormat(code: Int(code)))
            }
        }
        for flags: UInt32 in [0x44, 0x60] { // Authored sprite/video volume combinations remain unsupported.
            XCTAssertThrowsError(try load(tex(format: 0, images: [[solid(1, 1, [1, 2, 3, 4])]], flags: flags, depth: 1), device)) {
                XCTAssertEqual($0 as? WPETexDecodeError, .unsupportedTextureDimension(depth: 1))
            }
        }
        let animatedVolume = tex(format: 0, images: [[solid(1, 1, [1, 2, 3, 4])], [solid(1, 1, [5, 6, 7, 8])]],
                                 flags: 0x40, depth: 1)
        XCTAssertThrowsError(try load(animatedVolume, device)) {
            XCTAssertEqual($0 as? WPETexDecodeError, .unsupportedTextureDimension(depth: 1))
        }
        var conditionalVolume = tex(format: 0, images: [[solid(1, 1, [1, 2, 3, 4])]], flags: 0x40, depth: 1)
        let bitmap = try XCTUnwrap(conditionalVolume.range(of: Data("TEXB0003".utf8)))
        conditionalVolume.replaceSubrange(bitmap, with: Data("TEXB0004".utf8))
        var count = Data()
        append(1, to: &count)
        conditionalVolume.insert(contentsOf: count, at: bitmap.lowerBound + 9 + 8)
        XCTAssertThrowsError(try load(conditionalVolume, device)) {
            XCTAssertEqual($0 as? WPETexDecodeError, .unsupportedTextureDimension(depth: 1))
        }
        let oversized = tex(format: 0, images: [[solid(2049, 1, [1, 2, 3, 4])]], flags: 0x40, depth: 1)
        XCTAssertThrowsError(try load(oversized, device)) // Must fail before Metal's 3D descriptor validation.
        let typeless = tex(format: 23, images: [[solid(1, 1, [0, 0, 0, 0])]])
        XCTAssertThrowsError(try load(typeless, device)) {
            XCTAssertEqual($0 as? WPETexDecodeError, .unsupportedFormat(code: 23))
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

    func testConditionalGroupsSelectRawPatchesAcrossMipsAndReachGPU() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let table: [(UInt32, UInt32, UInt32, String)] = [
            (7, 9000, 0, #"{"condition":"enabled"}"#),
            (7, 5, 0, #"{"condition":"enabled"}"#),
            (9, 60000, 0, #"{"condition":{"name":"mode","condition":"ON"}}"#),
        ]
        let data = conditionalTex(format: 0, images: [[solid(4, 2, [10, 20, 30, 40]),
                                                       solid(2, 1, [50, 60, 70, 80]), solid(1, 1, [90, 100, 110, 120])]],
                                  table: table, records: [0: [
                                      [ConditionalRecord(id: 5, x: 0, y: 0, width: 1, height: 1, bytes: Data([255, 0, 0, 255])),
                                       ConditionalRecord(id: 9000, x: 1, y: 1, width: 2, height: 1, bytes: Data([100, 110, 120, 130, 140, 150, 160, 170]))],
                                      [ConditionalRecord(id: 9000, x: 0, y: 0, width: 1, height: 1, bytes: Data([200, 210, 220, 230]), word: 37)],
                                  ], 1: [[ConditionalRecord(id: 9000, x: 0, y: 0, width: 1, height: 1, bytes: Data([15, 25, 35, 45]))]]])
        let metadata = try WPETexDecoder().extractRawMetadata(data: data).get()
        XCTAssertEqual(metadata.bitmap.conditionalVariants.map(\.groupKey), [7, 7, 9])
        XCTAssertEqual(metadata.bitmap.conditionalVariants.map(\.variantID), [9000, 5, 60000])
        XCTAssertEqual(metadata.bitmap.conditionalRecords.map(\.mipIndex), [0, 0, 0, 1])
        XCTAssertThrowsError(try load(data, device)) {
            guard let failure = $0 as? WPEParityTextureLoader.Failure,
                  case .unsupportedConditionalVariants = failure else {
                return XCTFail("Unexpected no-context error: \($0)")
            }
        }
        let properties: WPESceneJSONValue = .object(["enabled": .object(["value": .bool(true)]),
                                                     "mode": .object(["value": .string("OFF")])])
        let loaded = try WPEParityTextureLoader.load(span: WPEMappedByteSpan(data: data), device: device, userProperties: properties)
        let values = try read(loaded.texture, levels: [0, 1, 2], device: device)
        assertPixel(values[0], SIMD4(200, 210, 220, 230) / 255)
        assertPixel(values[1], SIMD4(15, 25, 35, 45) / 255)
        assertPixel(values[2], SIMD4(90, 100, 110, 120) / 255)
        var copied = Data(count: 32)
        copied.withUnsafeMutableBytes {
            loaded.texture.getBytes($0.baseAddress!, bytesPerRow: 16, from: MTLRegionMake2D(0, 0, 4, 2), mipmapLevel: 0)
        }
        XCTAssertEqual(copied, Data([200, 210, 220, 230, 10, 20, 30, 40, 10, 20, 30, 40, 10, 20, 30, 40,
                                     10, 20, 30, 40, 100, 110, 120, 130, 140, 150, 160, 170, 10, 20, 30, 40]))
        XCTAssertEqual(loaded.conditionalSelection?.observations[Data("mode".utf8)], Data("$__default".utf8))
        let numeric: WPESceneJSONValue = .object(["enabled": .object(["value": .number(1)])])
        let base = try WPEParityTextureLoader.load(span: WPEMappedByteSpan(data: data), device: device, userProperties: numeric)
        try assertPixel(read(base.texture, levels: [0], device: device)[0], SIMD4(10, 20, 30, 40) / 255)
    }

    func testConditionalReplacementPrefixAndPackedBlendReachGPUWithoutAlphaConversion() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let table: [(UInt32, UInt32, UInt32, String)] = [(1, 1, 2, #"{"condition":"on"}"#), (2, 2, 2, #"{"condition":"on"}"#)]
        // Adjacent replacements: original trim keeps the predecessor and stops at it; ID 1 wins.
        // Its deliberately irrelevant rectangle ensures full-size geometry does not decide replacement.
        let packet = conditionalTex(format: 0, images: [[solid(1, 1, [10, 20, 30, 40])]], table: table,
                                    records: [0: [[ConditionalRecord(id: 1, x: 999, y: 999, width: 0, height: 0, bytes: Data([70, 80, 90, 100])),
                                                   ConditionalRecord(id: 2, x: 0, y: 0, width: 1, height: 1, bytes: Data([170, 180, 190, 200]))]]])
        let properties: WPESceneJSONValue = .object(["on": .object(["value": .bool(true)])])
        let replaced = try WPEParityTextureLoader.load(span: WPEMappedByteSpan(data: packet), device: device, userProperties: properties)
        try assertPixel(read(replaced.texture, levels: [0], device: device)[0], SIMD4(70, 80, 90, 100) / 255)
        let blended = conditionalTex(format: 0, images: [[Mip(width: 4, height: 1,
                                                              bytes: Data([200, 100, 50, 20, 200, 100, 50, 20, 200, 100, 50, 20, 200, 100, 50, 20]))]],
        table: [(1, 55, 1, #"{"condition":"on"}"#)],
        records: [0: [[ConditionalRecord(id: 55, x: 0, y: 0, width: 4, height: 1,
                                         bytes: Data([20, 180, 250, 0, 20, 180, 250, 1, 20, 180, 250, 128, 20, 180, 250, 255]))]]])
        let result = try WPEParityTextureLoader.load(span: WPEMappedByteSpan(data: blended), device: device, userProperties: properties)
        var bytes = Data(count: 16)
        bytes.withUnsafeMutableBytes {
            result.texture.getBytes($0.baseAddress!, bytesPerRow: 16, from: MTLRegionMake2D(0, 0, 4, 1), mipmapLevel: 0)
        }
        // Independent signed per-channel floor(src-dst)*a/256 plus max-alpha; no /255 or premultiplication.
        XCTAssertEqual(bytes, Data([200, 100, 50, 20, 199, 100, 50, 20, 110, 140, 150, 128, 20, 179, 249, 255]))
        try assertPixel(read(result.texture, levels: [0], device: device)[0], SIMD4(200, 100, 50, 20) / 255)
    }

    func testConditionalRAndRGPatchChannelsAndFailureBoundaries() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let properties: WPESceneJSONValue = .object(["on": .object(["value": .bool(true)])])
        for (code, base, patch, expected) in [
            (UInt32(9), [UInt8(10)], [UInt8(73)], SIMD4<Float>(73.0 / 255, 0, 0, 1)),
            (UInt32(8), [UInt8(10), 20], [UInt8(73), 149], SIMD4<Float>(73.0 / 255, 149.0 / 255, 0, 1)),
        ] {
            let packet = conditionalTex(format: code, images: [[solid(2, 1, base)]],
                                        table: [(1, 8, 0, #"{"condition":"on"}"#), (2, 9, 1, #"{"condition":"on"}"#)],
                                        records: [0: [[
                                            ConditionalRecord(id: 8, x: 0, y: 0, width: 1, height: 1, bytes: Data(patch)),
                                            // Non-RGBA flags1 and out-of-bounds patches are native no-ops, not decode errors.
                                            ConditionalRecord(id: 9, x: 0, y: 0, width: 1, height: 1, bytes: Data()),
                                            ConditionalRecord(id: 8, x: 2, y: 0, width: 1, height: 1, bytes: Data()),
                                        ]]])
            let loaded = try WPEParityTextureLoader.load(span: WPEMappedByteSpan(data: packet), device: device, userProperties: properties)
            XCTAssertEqual(loaded.texture.pixelFormat, code == 9 ? .r8Unorm : .rg8Unorm)
            try assertPixel(read(loaded.texture, levels: [0], device: device)[0], expected)
        }
        let truncated = conditionalTex(format: 0, images: [[solid(1, 1, [10, 20, 30, 40])]],
                                       table: [(1, 8, 0, #"{"condition":"on"}"#)],
                                       records: [0: [[ConditionalRecord(id: 8, x: 0, y: 0, width: 1, height: 1, bytes: Data([1, 2]))]]])
        XCTAssertThrowsError(try WPEParityTextureLoader.load(span: WPEMappedByteSpan(data: truncated), device: device, userProperties: properties))
    }

    func testConditionalRawPatchHighFlagsPreserveCopyBlendAndReplacementBytesOnGPU() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let properties: WPESceneJSONValue = .object(["on": .object(["value": .bool(true)])])
        for (flags, expected): (UInt32, [UInt8]) in [
            (0x8000_0000, [20, 180, 250, 128]),
            (0x8000_0001, [110, 140, 150, 128]),
            (0x8000_0002, [20, 180, 250, 128]),
            (0xFFFF_FFFF, [20, 180, 250, 128]),
        ] {
            let replacement = flags & 2 != 0
            let packet = conditionalTex(format: 0, images: [[solid(1, 1, [200, 100, 50, 20])]],
                                        table: [(1, 8, flags, #"{"condition":"on"}"#)],
                                        records: [0: [[ConditionalRecord(id: 8, x: replacement ? .max : 0, y: 0,
                                                                         width: replacement ? 0 : 1, height: 1,
                                                                         bytes: Data([20, 180, 250, 128]))]]])
            let loaded = try WPEParityTextureLoader.load(span: WPEMappedByteSpan(data: packet), device: device, userProperties: properties)
            XCTAssertEqual(loaded.conditionalSelection?.flagsByVariantID[8], flags)
            var bytes = Data(count: 4)
            bytes.withUnsafeMutableBytes {
                loaded.texture.getBytes($0.baseAddress!, bytesPerRow: 4, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
            }
            XCTAssertEqual(bytes, Data(expected), "Authored high flags \(flags) must not change the native low-bit operation")
        }
    }

    func testConditionalCompressedPatchFailureKeepsOtherPatchesAndRawChannelScratchBytesOnGPU() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let properties: WPESceneJSONValue = .object(["on": .object(["value": .bool(true)])])
        for (code, compressedBase, baseCount, patch, expected): (UInt32, [UInt8], UInt32, [UInt8], [UInt8]) in [
            (0, [0x80, 10, 20, 30, 40, 50, 60, 70, 80], 8, [0x40, 73, 149, 211, 255], [10, 20, 30, 40, 73, 149, 211, 255]),
            (9, [0x20, 10, 20], 2, [0x40, 73, 149, 211, 255], [10, 73]),
            (8, [0x40, 10, 20, 30, 40], 4, [0x40, 73, 149, 211, 255], [10, 20, 73, 149]),
            (9, [0x20, 10, 20], 2, [0x10, 73], [10, 73]),
            (8, [0x40, 10, 20, 30, 40], 4, [0x20, 73, 149], [10, 20, 73, 149]),
            (0, [0x80, 10, 20, 30, 40, 50, 60, 70, 80], 8, [0x20, 73, 149], [10, 20, 30, 40, 50, 60, 70, 80]),
        ] {
            // Independent LZ4 literal blocks. The bad offset-zero block fails; the later valid patch
            // produces four bytes, while R/RG copy only the channel prefix from the native 4B scratch.
            let base = Mip(width: 2, height: 1, bytes: Data(compressedBase), compressionFlags: 1, decompressedByteCount: baseCount)
            let packet = conditionalTex(format: code, images: [[base]], table: [(1, 8, 0, #"{"condition":"on"}"#)],
                                        records: [0: [[
                                            ConditionalRecord(id: 8, x: 0, y: 0, width: 1, height: 1, bytes: Data([0x00, 0x00, 0x00])),
                                            ConditionalRecord(id: 8, x: 1, y: 0, width: 1, height: 1, bytes: Data(patch)),
                                        ]]])
            let loaded = try WPEParityTextureLoader.load(span: WPEMappedByteSpan(data: packet), device: device, userProperties: properties)
            var bytes = Data(count: expected.count)
            bytes.withUnsafeMutableBytes {
                loaded.texture.getBytes($0.baseAddress!, bytesPerRow: expected.count,
                                        from: MTLRegionMake2D(0, 0, 2, 1), mipmapLevel: 0)
            }
            XCTAssertEqual(bytes, Data(expected), "A bad or insufficient compressed patch skips only that record for format \(code)")
        }
    }

    func testConditionalPatchOnShortCompressedBaseMipThrows() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let properties: WPESceneJSONValue = .object(["on": .object(["value": .bool(true)])])
        // The authored decompressed count (4) is smaller than the 4x4 RGBA layout (64); both payloads are LZ4 literals.
        let base = Mip(width: 4, height: 4, bytes: Data([0x40, 10, 20, 30, 40]), compressionFlags: 1, decompressedByteCount: 4)
        let packet = conditionalTex(format: 0, images: [[base]], table: [(1, 8, 0, #"{"condition":"on"}"#)],
                                    records: [0: [[ConditionalRecord(id: 8, x: 3, y: 3, width: 1, height: 1,
                                                                     bytes: Data([0x40, 1, 2, 3, 4]))]]])
        XCTAssertThrowsError(try WPEParityTextureLoader.load(span: WPEMappedByteSpan(data: packet), device: device,
                                                             userProperties: properties)) {
            // The materializer must reject the short base before a patch writes past it, not the later upload check.
            XCTAssertEqual($0 as? WPETexDecodeError, .decodeFailed(mipmap: 0, detail: "Truncated conditional base mip"))
        }
    }

    private struct ConditionalRecord {
        let id: UInt32
        let x: UInt32
        let y: UInt32
        let width: UInt32
        let height: UInt32
        let bytes: Data
        var word: UInt32 = 1
    }

    private func conditionalTex(format: UInt32, images: [[Mip]], table: [(UInt32, UInt32, UInt32, String)],
                                records: [Int: [[ConditionalRecord]]]) -> Data {
        let base = images[0][0]
        var data = Data()
        magic("TEXV0005", to: &data); magic("TEXI0001", to: &data)
        for word in [format, 0, UInt32(base.width), UInt32(base.height), UInt32(base.width), UInt32(base.height), 0] {
            append(word, to: &data)
        }
        magic("TEXB0004", to: &data)
        append(UInt32(images.count), to: &data); append(.max, to: &data); append(UInt32(table.count), to: &data)
        for (group, id, flags, condition) in table {
            for word in [group, id, flags] {
                append(word, to: &data)
            }
            data.append(contentsOf: condition.utf8); data.append(0)
        }
        for (imageIndex, levels) in images.enumerated() {
            append(UInt32(levels.count), to: &data)
            for (level, mip) in levels.enumerated() {
                for word in [UInt32(mip.width), UInt32(mip.height), mip.compressionFlags,
                             mip.decompressedByteCount ?? UInt32(mip.bytes.count), UInt32(mip.bytes.count)] {
                    append(word, to: &data)
                }
                data.append(mip.bytes)
                let groups = records[imageIndex * 32 + level] ?? []
                append(UInt32(groups.count), to: &data)
                for group in groups {
                    append(UInt32(group.count), to: &data)
                    for record in group {
                        for word in [record.word, record.id, record.x, record.y, record.width, record.height, UInt32.max, UInt32(record.bytes.count)] {
                            append(word, to: &data)
                        }
                        data.append(record.bytes)
                    }
                }
            }
        }
        return data
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
                if depth != nil {
                    append(UInt32(mip.depth), to: &data)
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

    private func sample(_ sprite: WPEParityTextureLoader.Sprite, uv: SIMD2<Float>,
                        device: MTLDevice) throws -> SIMD4<Float> {
        let library = try device.makeLibrary(source: """
        #include <metal_stdlib>
        using namespace metal;
        kernel void sample_sprite(texture2d<float> source [[texture(0)]],
            const device float4 *frame [[buffer(0)]], device float4 *value [[buffer(1)]]) {
            constexpr sampler point(coord::normalized, address::clamp_to_edge, filter::nearest);
            float2 uv = frame[1].xy + frame[1].z * frame[0].xy + frame[1].w * frame[0].zw;
            value[0] = source.sample(point, uv, level(0.0f));
        }
        """, options: nil)
        let function = try XCTUnwrap(library.makeFunction(name: "sample_sprite"))
        let pipeline = try device.makeComputePipelineState(function: function)
        let translation = sprite.frame.translation
        let frame = [sprite.frame.rotation, SIMD4(translation.x, translation.y, uv.x, uv.y)]
        let input = try XCTUnwrap(device.makeBuffer(bytes: frame, length: 32, options: .storageModeShared))
        let output = try XCTUnwrap(device.makeBuffer(length: 16, options: .storageModeShared))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(command.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(sprite.texture, index: 0)
        encoder.setBuffer(input, offset: 0, index: 0)
        encoder.setBuffer(output, offset: 0, index: 1)
        encoder.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed)
        if let error = command.error {
            throw error
        }
        return output.contents().load(as: SIMD4<Float>.self)
    }

    private func sampleVolume(_ texture: MTLTexture, coordinates: [SIMD4<UInt32>],
                              device: MTLDevice) throws -> [SIMD4<Float>] {
        let library = try device.makeLibrary(source: """
        #include <metal_stdlib>
        using namespace metal;
        kernel void sample_volume(texture3d<float> source [[texture(0)]],
            const device uint4 *coordinates [[buffer(0)]], device float4 *values [[buffer(1)]],
            uint index [[thread_position_in_grid]]) {
            constexpr sampler point(coord::normalized, address::clamp_to_edge, filter::nearest, mip_filter::nearest);
            uint4 at = coordinates[index];
            float3 extent(source.get_width(at.w), source.get_height(at.w), source.get_depth(at.w));
            values[index] = source.sample(point, (float3(at.xyz) + 0.5f) / extent, level(float(at.w)));
        }
        """, options: nil)
        let function = try XCTUnwrap(library.makeFunction(name: "sample_volume"))
        let pipeline = try device.makeComputePipelineState(function: function)
        let input = try XCTUnwrap(device.makeBuffer(bytes: coordinates, length: coordinates.count * 16, options: .storageModeShared))
        let output = try XCTUnwrap(device.makeBuffer(length: coordinates.count * 16, options: .storageModeShared))
        let command = try XCTUnwrap(device.makeCommandQueue()?.makeCommandBuffer())
        let encoder = try XCTUnwrap(command.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(texture, index: 0)
        encoder.setBuffer(input, offset: 0, index: 0)
        encoder.setBuffer(output, offset: 0, index: 1)
        encoder.dispatchThreads(MTLSize(width: coordinates.count, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed)
        if let error = command.error {
            throw error
        }
        return Array(UnsafeBufferPointer(start: output.contents().bindMemory(to: SIMD4<Float>.self,
                                                                             capacity: coordinates.count), count: coordinates.count))
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
