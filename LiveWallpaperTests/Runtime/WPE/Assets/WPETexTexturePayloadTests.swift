import Compression
import CoreGraphics
import Foundation
import ImageIO
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import Testing
import UniformTypeIdentifiers

@Suite("WPETexDecoder texture payload extraction")
struct WPETexTexturePayloadTests {

    @Test("Bridges TEXB-encoded PNG payload to RGBA8888 for Metal upload")
    func bridgesEncodedPNGPayloadToRGBA8888() throws {
        let png = try makeSolidColorPNG(width: 4, height: 4, red: 255, green: 0, blue: 0, alpha: 255)
        let tex = makeImage(
            width: 4,
            height: 4,
            formatCode: WPETexFormat.rgba8888.rawValue,
            payload: png,
            sourceImageFormatCode: 0
        )

        let extracted = try WPETexDecoder().extractTexturePayload(data: tex).get()

        #expect(extracted.info.format == .rgba8888)
        let mip = try #require(extracted.largestMipmap)
        #expect(mip.width == 4)
        #expect(mip.height == 4)
        #expect(mip.bytes.count == 4 * 4 * 4)
        let firstPixel = Array(mip.bytes.prefix(4))
        #expect(firstPixel[0] == 0xFF, "R channel should be 0xFF for the solid-red fixture")
        #expect(firstPixel[3] == 0xFF, "A channel should be 0xFF for the solid-red fixture")
    }

    @Test("Bridges semi-transparent TEXB-encoded PNG as straight alpha")
    func bridgesSemiTransparentEncodedPNGAsStraightAlpha() throws {
        let png = try makeSolidColorPNG(width: 4, height: 4, red: 255, green: 0, blue: 0, alpha: 128)
        let tex = makeImage(
            width: 4,
            height: 4,
            formatCode: WPETexFormat.rgba8888.rawValue,
            payload: png,
            sourceImageFormatCode: 0
        )

        let extracted = try WPETexDecoder().extractTexturePayload(data: tex).get()
        let mip = try #require(extracted.largestMipmap)
        let firstPixel = Array(mip.bytes.prefix(4))
        #expect(firstPixel[0] >= 0xFE, "R should round-trip near 0xFF (got \(firstPixel[0])); double-premultiply would emit ~0x80")
        #expect(firstPixel[3] == 0x80, "A should preserve 0x80 unchanged")
    }

    @Test("Embedded PNG preserves zero and low-alpha data channels")
    func embeddedPNGPreservesDataChannels() throws {
        let payload = try embeddedDataPayload()
        let mip = try #require(payload.largestMipmap)
        #expect(mip.bytes == embeddedDataBytes)
    }

    @Test("Embedded PNG data channels survive production Metal upload")
    func embeddedPNGDataChannelsSurviveMetalUpload() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let payload = try embeddedDataPayload()
        let texture = try WPEMetalTextureLoader.makeTextureSynchronously(
            from: payload, label: "normal", device: device,
            capabilities: WPEMetalTextureCapabilities(device: device), usage: .normal
        )
        #expect(texture.pixelFormat == .rgba8Unorm)
        let library = try device.makeLibrary(source: """
        #include <metal_stdlib>
        using namespace metal;
        kernel void b4_read(texture2d<float, access::read> input [[texture(0)]],
                            device float4 *output [[buffer(0)]], uint x [[thread_position_in_grid]]) {
            output[x] = input.read(uint2(x, 0));
        }
        """, options: nil)
        let function = try #require(library.makeFunction(name: "b4_read"))
        let pipeline = try device.makeComputePipelineState(function: function)
        let buffer = try #require(device.makeBuffer(length: 5 * MemoryLayout<SIMD4<Float>>.stride, options: .storageModeShared))
        let queue = try #require(device.makeCommandQueue())
        let command = try #require(queue.makeCommandBuffer())
        let encoder = try #require(command.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(texture, index: 0)
        encoder.setBuffer(buffer, offset: 0, index: 0)
        encoder.dispatchThreads(MTLSize(width: 5, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        try #require(command.status == .completed)
        let values = buffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: 5)
        let expected = Array(embeddedDataBytes)
        for x in 0 ..< 5 {
            for channel in 0 ..< 4 {
                #expect(abs(values[x][channel] - Float(expected[x * 4 + channel]) / 255) < 0.000001)
            }
        }
    }

    @Test("Straight RGBA extraction skips row padding and rejects conversion layouts")
    func straightRGBAExtractionLayoutBoundaries() throws {
        let pixels = Data([192, 128, 64, 0, 7, 7, 7, 7, 48, 32, 16, 1, 9, 9, 9, 9])
        let provider = try #require(CGDataProvider(data: pixels as CFData))
        let sRGB = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        func image(_ alpha: CGImageAlphaInfo, _ order: CGBitmapInfo, _ space: CGColorSpace) throws -> CGImage {
            try #require(CGImage(width: 1, height: 2, bitsPerComponent: 8, bitsPerPixel: 32,
                                 bytesPerRow: 8, space: space,
                                 bitmapInfo: CGBitmapInfo(rawValue: alpha.rawValue).union(order),
                                 provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        }
        let expected = Data([192, 128, 64, 0, 48, 32, 16, 1])
        #expect(try WPETexDecoder.straightRGBA8Bytes(from: image(.last, [], sRGB)) == expected)
        #expect(try WPETexDecoder.straightRGBA8Bytes(from: image(.last, .byteOrder32Big, sRGB)) == expected)
        #expect(try WPETexDecoder.straightRGBA8Bytes(from: image(.premultipliedLast, [], sRGB)) == nil)
        #expect(try WPETexDecoder.straightRGBA8Bytes(from: image(.first, .byteOrder32Little, sRGB)) == nil)
        let p3 = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        #expect(try WPETexDecoder.straightRGBA8Bytes(from: image(.last, [], p3)) == nil)
    }

    private var embeddedDataBytes: Data {
        Data([0, 1, 2, 8, 255].flatMap { [UInt8(192), 128, 64, UInt8($0)] })
    }

    private func embeddedDataPayload() throws -> WPETexTexturePayload {
        // Hand-encoded RGBA PNG avoids fixture authoring through a premultiplied CGContext.
        let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAUAAAABCAYAAAAW/mTzAAAAF0lEQVR4nGM40ODAAMSMQMwExBxA/B8AVlsIi0RWaPgAAAAASUVORK5CYII="))
        return try WPETexDecoder().extractTexturePayload(data: makeImage(
            width: 5, height: 1, formatCode: WPETexFormat.rgba8888.rawValue,
            payload: png, sourceImageFormatCode: 0
        )).get()
    }

    @Test("Rejects encoded PNG larger than the TEXI header before rasterizing")
    func rejectsEncodedPNGLargerThanTEXIHeader() throws {
        let png = try makeSolidColorPNG(width: 8, height: 8, red: 255, green: 0, blue: 0, alpha: 255)
        let tex = makeImage(
            width: 4,
            height: 4,
            formatCode: WPETexFormat.rgba8888.rawValue,
            payload: png,
            sourceImageFormatCode: 0
        )

        let extracted = WPETexDecoder().extractTexturePayload(data: tex)
        guard case let .failure(.invalidDimensions(width, height)) = extracted else {
            Issue.record("Expected invalidDimensions for 8x8 PNG in 4x4 TEXI, got \(extracted)")
            return
        }
        #expect(width == 8 && height == 8)

        let decoded = WPETexDecoder().decode(data: tex)
        guard case .failure(.invalidDimensions) = decoded else {
            Issue.record("Expected decode() to reject 8x8 PNG in 4x4 TEXI, got \(decoded)")
            return
        }
    }

    @Test("Rejects a small 20000x20000 PNG before allocating its RGBA buffer")
    func rejectsPNGWithHugeDeclaredDimensions() throws {
        let png = try blankOneBitPNG(width: 20000, height: 20000)
        let tex = makeImage(
            width: 16384,
            height: 16384,
            formatCode: WPETexFormat.rgba8888.rawValue,
            payload: png,
            sourceImageFormatCode: 0
        )

        let extracted = WPETexDecoder().extractTexturePayload(data: tex)
        guard case let .failure(.invalidDimensions(width, height)) = extracted else {
            Issue.record("Expected invalidDimensions for 20000x20000 PNG (\(png.count) bytes), got \(extracted)")
            return
        }
        #expect(width == 20000 && height == 20000)
    }

    @Test("Multi-image encoded TEXB without TEXS synthesises a default-cadence animation track")
    func encodedAnimationWithoutTEXSSynthesisesDefaultCadenceTrack() throws {
        let png = try makeSolidColorPNG(width: 2, height: 2, red: 0, green: 0, blue: 255, alpha: 255)
        let tex = makeAnimatedImage(
            width: 2,
            height: 2,
            formatCode: WPETexFormat.rgba8888.rawValue,
            framePayloads: [png, png],
            sourceImageFormatCode: 0
        )

        let extracted = try WPETexDecoder().extractTexturePayload(data: tex).get()
        let track = try #require(extracted.animationTrack)

        #expect(extracted.hasAnimationFrames == true)
        #expect(track.frames.count == 2)
        #expect(track.frames[0].imageID == 0)
        #expect(track.frames[1].imageID == 1)
        #expect(track.frames[0].subRect == nil)
        #expect(track.frames[1].subRect == nil)
    }

    @Test("Single-image encoded TEXB without TEXS degrades to static payload")
    func encodedSingleImageWithoutTEXSDegradesToStaticPayload() throws {
        let png = try makeSolidColorPNG(width: 2, height: 2, red: 0, green: 0, blue: 255, alpha: 255)
        let tex = makeAnimatedImage(
            width: 2,
            height: 2,
            formatCode: WPETexFormat.rgba8888.rawValue,
            framePayloads: [png],
            sourceImageFormatCode: 0
        )

        let extracted = try WPETexDecoder().extractTexturePayload(data: tex).get()

        #expect(extracted.animationTrack == nil)
        #expect(extracted.hasAnimationFrames == false)
        let mip = try #require(extracted.largestMipmap)
        #expect(mip.width == 2)
        #expect(mip.height == 2)
    }

    @Test("Extracts raw RGBA8888 mip payload without creating CGImage")
    func extractsRGBA8888Payload() throws {
        let payload = Data(repeating: 0xaa, count: 4 * 4 * 4)
        let tex = makeImage(
            width: 4,
            height: 4,
            formatCode: WPETexFormat.rgba8888.rawValue,
            payload: payload
        )

        let extracted = try WPETexDecoder().extractTexturePayload(data: tex).get()

        #expect(extracted.info.format == .rgba8888)
        #expect(extracted.largestMipmap?.bytes == payload)
        #expect(extracted.largestMipmap?.width == 4)
        #expect(extracted.largestMipmap?.height == 4)
    }

    @Test("Extracts BC7 payload for native Metal sampling")
    func extractsBC7Payload() throws {
        let payload = Data(repeating: 0x3f, count: WPETexFormat.bc7.expectedByteCount(width: 4, height: 4))
        let tex = makeImage(
            width: 4,
            height: 4,
            formatCode: WPETexFormat.bc7.rawValue,
            payload: payload
        )

        let extracted = try WPETexDecoder().extractTexturePayload(data: tex).get()

        #expect(extracted.info.format == .bc7)
        #expect(extracted.largestMipmap?.bytes == payload)
        #expect(extracted.hasAnimationFrames == false)
    }

    @Test("Routes MP4-backed TEX payloads to the videoPayload field")
    func extractsVideoPayloadFromMP4Tex() throws {
        let mp4 = mp4HeaderPayload()
        let tex = makeImage(
            width: 1,
            height: 1,
            formatCode: WPETexFormat.rgba8888.rawValue,
            payload: mp4
        )

        let extracted = try WPETexDecoder().extractTexturePayload(data: tex).get()

        let video = try #require(extracted.videoPayload)
        #expect(video.bytes == mp4)
        #expect(extracted.animationTrack == nil)
        #expect(extracted.mipmaps.isEmpty)
    }

    private func makeAnimatedImage(
        width: Int,
        height: Int,
        formatCode: Int,
        framePayloads: [Data],
        sourceImageFormatCode: Int
    ) -> Data {
        var buffer = Data()
        appendMagic(&buffer, magic: "TEXV0005")
        appendMagic(&buffer, magic: "TEXI0001")
        appendInt32(&buffer, Int32(formatCode))
        appendUInt32(&buffer, 0)
        appendInt32(&buffer, Int32(width))
        appendInt32(&buffer, Int32(height))
        appendInt32(&buffer, Int32(width))
        appendInt32(&buffer, Int32(height))
        appendInt32(&buffer, 0)

        appendMagic(&buffer, magic: "TEXB0003")
        appendInt32(&buffer, Int32(framePayloads.count))
        appendInt32(&buffer, Int32(sourceImageFormatCode))
        for payload in framePayloads {
            appendInt32(&buffer, 1)
            appendInt32(&buffer, Int32(width))
            appendInt32(&buffer, Int32(height))
            appendUInt32(&buffer, 0)
            appendUInt32(&buffer, UInt32(payload.count))
            appendUInt32(&buffer, UInt32(payload.count))
            buffer.append(payload)
        }
        return buffer
    }

    private func makeImage(
        width: Int,
        height: Int,
        formatCode: Int,
        payload: Data,
        isLZ4Compressed: Bool = false,
        decompressedByteCount: Int? = nil,
        sourceImageFormatCode: Int = -1
    ) -> Data {
        var buffer = Data()
        appendMagic(&buffer, magic: "TEXV0005")
        appendMagic(&buffer, magic: "TEXI0001")
        appendInt32(&buffer, Int32(formatCode))
        appendUInt32(&buffer, 0)
        appendInt32(&buffer, Int32(width))
        appendInt32(&buffer, Int32(height))
        appendInt32(&buffer, Int32(width))
        appendInt32(&buffer, Int32(height))
        appendInt32(&buffer, 0)

        appendMagic(&buffer, magic: "TEXB0003")
        appendInt32(&buffer, 1)
        appendInt32(&buffer, Int32(sourceImageFormatCode))
        appendInt32(&buffer, 1)
        appendInt32(&buffer, Int32(width))
        appendInt32(&buffer, Int32(height))
        appendUInt32(&buffer, isLZ4Compressed ? 1 : 0)
        appendUInt32(&buffer, UInt32(decompressedByteCount ?? payload.count))
        appendUInt32(&buffer, UInt32(payload.count))
        buffer.append(payload)
        return buffer
    }

    private func makeSolidColorPNG(
        width: Int,
        height: Int,
        red: UInt8,
        green: UInt8,
        blue: UInt8,
        alpha: UInt8
    ) throws -> Data {
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = Data(count: bytesPerRow * height)
        pixels.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for y in 0..<height {
                for x in 0..<width {
                    let offset = y * bytesPerRow + x * bytesPerPixel
                    base[offset]     = red
                    base[offset + 1] = green
                    base[offset + 2] = blue
                    base[offset + 3] = alpha
                }
            }
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        let context = pixels.withUnsafeMutableBytes { buffer -> CGContext? in
            guard let base = buffer.baseAddress else { return nil }
            return CGContext(
                data: base,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo.rawValue
            )
        }
        guard let context, let cgImage = context.makeImage() else {
            throw NSError(domain: "WPETexTexturePayloadTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not synthesise CGImage fixture"])
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw NSError(domain: "WPETexTexturePayloadTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not create PNG destination"])
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "WPETexTexturePayloadTests", code: 3, userInfo: [NSLocalizedDescriptionKey: "PNG finalisation failed"])
        }
        return output as Data
    }

    /// Valid all-black 1-bit grayscale PNG; rows are streamed into deflate so the raw image is never held in memory.
    private func blankOneBitPNG(width: Int, height: Int) throws -> Data {
        let rowBytes = 1 + (width + 7) / 8
        var deflated = Data()
        let filter = try OutputFilter(.compress, using: .zlib) { chunk in
            if let chunk {
                deflated.append(chunk)
            }
        }
        let row = Data(count: rowBytes)
        for _ in 0 ..< height {
            try filter.write(row)
        }
        try filter.finalize()

        // Compression's .zlib is raw deflate; PNG wants the zlib wrapper. All-zero Adler-32: a = 1, b = n mod 65521.
        let adler = UInt32((rowBytes * height) % 65521) << 16 | 1
        var idat = Data([0x78, 0x01])
        idat.append(deflated)
        idat.append(bigEndian(adler))

        var ihdr = bigEndian(UInt32(width)) + bigEndian(UInt32(height))
        ihdr.append(contentsOf: [1, 0, 0, 0, 0])
        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        png.append(pngChunk("IHDR", ihdr))
        png.append(pngChunk("IDAT", idat))
        png.append(pngChunk("IEND", Data()))
        return png
    }

    private func pngChunk(_ type: String, _ body: Data) -> Data {
        let typed = Data(type.utf8) + body
        return bigEndian(UInt32(body.count)) + typed + bigEndian(crc32(typed))
    }

    private func bigEndian(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }

    private func crc32(_ bytes: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0 ..< 8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
        }
        return ~crc
    }

    private func mp4HeaderPayload() -> Data {
        Data([
            0x00, 0x00, 0x00, 0x18,
            0x66, 0x74, 0x79, 0x70,
            0x6d, 0x70, 0x34, 0x32,
            0x00, 0x00, 0x00, 0x00
        ])
    }

    private func appendMagic(_ data: inout Data, magic: String) {
        data.append(contentsOf: magic.utf8)
        data.append(0x00)
    }

    private func appendInt32(_ data: inout Data, _ value: Int32) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    private func appendUInt32(_ data: inout Data, _ value: UInt32) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }
}
