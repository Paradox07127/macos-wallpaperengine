import Compression
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import LiveWallpaperProWPE
import Testing
import UniformTypeIdentifiers
@testable import LiveWallpaper

@Suite("WPETexDecoder — container + RGBA8888")
struct WPETexDecoderTests {
    private static let officialFlag0x40Fixtures: [(name: String, tailBits: UInt32, sha256: String)] = [
        ("lutx32_daisy.tex", 0xFF30_B1C5, "28151a832fee1ffa0cc18c2081c49639ceaf82a7b60b3063e355fb12c75ae352"),
        ("neutral.tex", 0xFF55_55AA, "967ea45d38c40eda283d440bd80b914587c779ec6fbe1981e761d2443a68fa3b"),
    ]

    private static var officialFlag0x40FixtureRoot: URL {
        SteamLibraryPaths.wallpaperEngineInstallRoot()
            .appendingPathComponent("assets/materials/lut", isDirectory: true)
    }

    private static var officialFlag0x40FixturesAvailable: Bool {
        officialFlag0x40Fixtures.allSatisfy { fixture in
            FileManager.default.fileExists(
                atPath: officialFlag0x40FixtureRoot.appendingPathComponent(fixture.name).path
            )
        }
    }

    // MARK: - Container guards

    @Test("Empty data fails with truncatedBlock at offset 0")
    func emptyDataTruncated() {
        let result = WPETexDecoder().decode(data: Data())
        guard case .failure(.truncatedBlock(_, let offset)) = result else {
            Issue.record("Expected truncatedBlock failure, got \(result)")
            return
        }
        #expect(offset == 0)
    }

    @Test("RG88 alphaChannelPriority expands to luminance+alpha (R,R,R,G)")
    func rg88AlphaChannelPriorityExpandsToLuminanceAlpha() throws {
        let input = Data([200, 50, 10, 255])

        let normal = try WPETexPixelDecoder.decodeRG88(input, width: 2, height: 1, mipmap: 0)
        #expect(
            Array(normal.pixels) == [200, 50, 0, 255, 10, 255, 0, 255],
            "default RG88 must stay (R, G, 0, 255) so normal maps read .xy correctly"
        )

        let glow = try WPETexPixelDecoder.decodeRG88(
            input, width: 2, height: 1, mipmap: 0, alphaChannelPriority: true
        )
        #expect(
            Array(glow.pixels) == [200, 200, 200, 50, 10, 10, 10, 255],
            "alphaChannelPriority RG88 must expand to (R, R, R, G) = luminance + alpha"
        )
    }

    @Test("Unknown container magic surfaces unsupportedContainer")
    func unknownContainerMagic() {
        var buffer = Data()
        appendMagic(&buffer, magic: "FAKE9999")
        let result = WPETexDecoder().decode(data: buffer)
        guard case .failure(.unsupportedContainer(let magic)) = result else {
            Issue.record("Expected unsupportedContainer, got \(result)")
            return
        }
        #expect(magic.hasPrefix("FAKE"))
    }

    @Test("Container without TEXI block fails with missingInfoBlock")
    func missingInfoBlock() {
        var buffer = Data()
        appendMagic(&buffer, magic: "TEXV0005")
        let result = WPETexDecoder().decode(data: buffer)
        guard case .failure(.missingInfoBlock) = result else {
            Issue.record("Expected missingInfoBlock, got \(result)")
            return
        }
    }

    @Test("Non-TEXI second block fails with unsupportedBlock")
    func unsupportedSecondBlock() {
        var buffer = Data()
        appendMagic(&buffer, magic: "TEXV0005")
        appendMagic(&buffer, magic: "WHAT0001")
        let result = WPETexDecoder().decode(data: buffer)
        guard case .failure(.unsupportedBlock(let magic)) = result else {
            Issue.record("Expected unsupportedBlock, got \(result)")
            return
        }
        #expect(magic.hasPrefix("WHAT"))
    }

    @Test("Probe of a complete RGBA8888 file yields valid info")
    func probeReturnsInfo() {
        let buffer = makeRGBA8888TestImage(width: 4, height: 4)
        let result = WPETexDecoder().probe(span: WPEMappedByteSpan(data: buffer))
        guard case .success(let info) = result else {
            Issue.record("Expected probe success, got \(result)")
            return
        }
        #expect(info.width == 4)
        #expect(info.height == 4)
        #expect(info.format == .rgba8888)
        #expect(info.containerVersion == 5)
    }

    // MARK: - RGBA8888 round-trip

    @Test("Decode of synthetic RGBA8888 returns a CGImage with correct dimensions")
    func decodeRGBA8888RoundTrip() throws {
        let buffer = makeRGBA8888TestImage(width: 4, height: 4)
        let result = WPETexDecoder().decode(data: buffer)
        guard case .success(let image) = result else {
            Issue.record("Expected decode success, got \(result)")
            return
        }
        #expect(image.width == 4)
        #expect(image.height == 4)
    }

    @Test("Single-frame static .tex decodes eagerly at full size and declines the streaming path")
    func singleFrameStaticDecodesEagerlyAndDeclinesStreaming() throws {
        let buffer = makeRGBA8888TestImage(width: 256, height: 256)

        let eager = try WPETexDecoder().extractTexturePayload(data: buffer).get()
        #expect(eager.info.format == .rgba8888)
        #expect(eager.hasAnimationFrames == false)
        #expect(eager.animationTrack == nil)
        #expect(eager.videoPayload == nil)
        let mip = try #require(eager.largestMipmap)
        #expect(mip.width == 256)
        #expect(mip.height == 256)
        #expect(mip.bytes.count == 256 * 256 * 4)

        let streaming = WPETexDecoder().extractStreamingPayload(data: buffer)
        guard case .failure(.unsupportedAnimation) = streaming else {
            Issue.record("Expected single-frame static to decline streaming with unsupportedAnimation, got \(streaming)")
            return
        }
    }

    @Test("Decode accepts TEXB0003 PNG-backed texture")
    func decodeTEXB0003PNGBackedTexture() throws {
        let buffer = makeTEXB0003PNGBackedImage()
        let result = WPETexDecoder().decode(data: buffer)
        guard case .success(let image) = result else {
            Issue.record("Expected decode success for PNG-backed layout, got \(result)")
            return
        }

        #expect(image.width == 1)
        #expect(image.height == 1)
    }

    @Test("Unknown format code surfaces unsupportedFormat with the offending code")
    func unsupportedFormatCode() {
        let buffer = makeImage(width: 2, height: 2, formatCode: 99, payload: Data(count: 16))
        let result = WPETexDecoder().decode(data: buffer)
        guard case .failure(.unsupportedFormat(let code)) = result else {
            Issue.record("Expected unsupportedFormat, got \(result)")
            return
        }
        #expect(code == 99)
    }

    @Test("LZ4-compressed mip payload decompresses to the expected uncompressed size")
    func lz4InflateOnSizeMismatch() throws {
        let width = 4
        let height = 4
        let raw = Data((0..<(width * height * 4)).map { UInt8(($0 * 7) & 0xff) })
        let compressed = try lz4RawCompress(raw)
        try #require(compressed.count != raw.count,
                     "LZ4 must yield a different byte count to exercise the inflate fallback")

        let buffer = makeImage(
            width: width,
            height: height,
            formatCode: WPETexFormat.rgba8888.rawValue,
            payload: compressed,
            isLZ4Compressed: true,
            decompressedByteCount: raw.count
        )

        let result = WPETexDecoder().decode(data: buffer)
        guard case .success(let image) = result else {
            Issue.record("Expected decode success after LZ4 inflate, got \(result)")
            return
        }
        #expect(image.width == width)
        #expect(image.height == height)
    }

    @Test("MP4-backed TEXB payload is rejected instead of decoded as raw RGBA")
    func mp4PayloadIsUnsupportedAnimation() {
        let buffer = makeImage(
            width: 1,
            height: 1,
            formatCode: WPETexFormat.rgba8888.rawValue,
            payload: mp4HeaderPayload()
        )

        let result = WPETexDecoder().decode(data: buffer)
        guard case .failure(.unsupportedAnimation) = result else {
            Issue.record("Expected unsupportedAnimation for MP4-backed TEXB payload, got \(result)")
            return
        }
    }

    @Test("Encoded PNG + TEXS animation extracts an animation track with per-frame sub-rects")
    func encodedPNGWithTEXSExtractsAnimationTrack() throws {
        let buffer = makeEncodedPNGAtlasWithTEXS()
        let payload = try WPETexDecoder().extractTexturePayload(data: buffer).get()
        let track = try #require(payload.animationTrack)

        #expect(payload.hasAnimationFrames == true)
        #expect(payload.info.format == .rgba8888)
        #expect(track.frames.count == 2)
        #expect(track.frames[0].subRect == CGRect(x: 0, y: 0, width: 2, height: 2))
        #expect(track.frames[1].subRect == CGRect(x: 2, y: 0, width: 2, height: 2))
        #expect(track.frames[0].samplingDescriptor == WPETexSpriteSamplingDescriptor(
            rotation: SIMD4<Float>(0.5, 0, 0, 0.5),
            translation: SIMD2<Float>(0, 0)
        ))
        // Cross-axis TEXS lanes must survive; CGRect cannot represent these.
        #expect(track.frames[1].samplingDescriptor == WPETexSpriteSamplingDescriptor(
            rotation: SIMD4<Float>(0.5, 0.25, -0.25, 0.5),
            translation: SIMD2<Float>(0.5, 0)
        ))
        #expect(track.frames[0].mipmaps.first?.bytes == track.frames[1].mipmaps.first?.bytes)
    }

    @Test("Non-square TEXS cross-axis components use the coordinate axis dimension")
    func nonSquareTEXSUsesCoordinateAxisDimensions() throws {
        var buffer = makeImageWithTEXIImageDimensions(textureWidth: 4, textureHeight: 2,
                                                      imageWidth: 4, imageHeight: 2, unknownInt0: 0, flags: 4)
        appendMagic(&buffer, magic: "TEXS0002")
        appendInt32(&buffer, 1)
        appendInt32(&buffer, 0)
        for value: Float in [0.125, 1, 0, 2, 1, -1, 1] {
            appendFloat32(&buffer, value)
        }
        let payload = try WPETexDecoder().extractTexturePayload(data: buffer).get()
        let frame = try #require(payload.animationTrack?.frames.first)
        #expect(frame.samplingDescriptor == WPETexSpriteSamplingDescriptor(
            rotation: SIMD4<Float>(0.5, 0.5, -0.25, 0.5), translation: SIMD2<Float>(0.25, 0)
        ))
    }

    @Test("TEXI imageWidth/imageHeight/unkInt0 surface into WPETexInfo")
    func texiUnknownFieldsAreRetained() throws {
        let buffer = makeImageWithTEXIImageDimensions(
            textureWidth: 4,
            textureHeight: 4,
            imageWidth: 3,
            imageHeight: 2,
            unknownInt0: 7,
            flags: WPETexInfo.clampUVsFlag
        )

        let info = try WPETexDecoder().probe(span: WPEMappedByteSpan(data: buffer)).get()

        #expect(info.width == 4)
        #expect(info.height == 4)
        #expect(info.imageWidth == 3)
        #expect(info.imageHeight == 2)
        #expect(info.unknownInt0 == 7)
        #expect(info.flags == WPETexInfo.clampUVsFlag)
        #expect(info.flag0x40Extension == nil)
    }

    @Test("Shared TEX header rejects unknown versions and keeps bounded decoder errors typed")
    func sharedHeaderRetainsTypedDecoderErrors() throws {
        let bytes = makeImageWithTEXIImageDimensions(textureWidth: 4, textureHeight: 2,
                                                     imageWidth: 4, imageHeight: 2, unknownInt0: 0)
        #expect(throws: WPETexDecodeError.truncatedBlock(block: "TEXI.header", offset: 26)) {
            _ = try WPETexDecoder().probe(span: WPEMappedByteSpan(data: Data(bytes.prefix(26)))).get()
        }
        var unknown = bytes
        unknown.replaceSubrange(9 ..< 17, with: Data("TEXI0002".utf8))
        #expect(throws: WPETexDecodeError.unsupportedBlock(magic: "TEXI0002")) {
            _ = try WPETexDecoder().probe(span: WPEMappedByteSpan(data: unknown)).get()
        }
    }

    @Test("TEXI depth precedes the versioned tail word and every volume mip retains depth")
    func texiFlag0x40DepthPrecedesVersionedTail() throws {
        let expectedRawBits: [UInt32] = [0xff30_b1c5, 0xff22_7322]

        for rawBits in expectedRawBits {
            let buffer = makeImageWithTEXIImageDimensions(
                textureWidth: 32,
                textureHeight: 32,
                imageWidth: 1_024,
                imageHeight: 32,
                unknownInt0: Int32(bitPattern: rawBits),
                flags: 0x42,
                flag0x40RawBits: 32
            )

            // Parsing through TEXB (rather than header-only probe) proves the
            // extra field was consumed and the following block magic is aligned.
            let metadata = try WPETexDecoder().extractRawMetadata(data: buffer).get()
            let rawExtension = try #require(metadata.info.flag0x40Extension)
            #expect(rawExtension.rawValue == 32)
            #expect(rawExtension.sourceRange == 42 ..< 46)
            #expect(metadata.info.depth == 32)
            #expect(metadata.info.isVolume)
            #expect(UInt32(bitPattern: metadata.info.unknownInt0) == rawBits)
            #expect(metadata.info.imageWidth == 1_024)
            #expect(metadata.info.imageHeight == 32)
            #expect(metadata.bitmap.version == 3)
            #expect(metadata.bitmap.frames.count == 1)
            #expect(metadata.bitmap.largestMipmap?.depth == 32)
            #expect(throws: WPETexDecodeError.unsupportedTextureDimension(depth: 32)) {
                _ = try WPETexDecoder().extractTexturePayload(data: buffer).get()
            }
        }
    }

    @Test("Raw volume keeps every depth mip and raw/LZ4 bits; legacy 2D callers still reject it")
    func rawVolumePayloadPreservesThreeAxisMipChain() throws {
        let levels: [(Int, Int, UInt32, Data)] = [
            (1, 1, 4, Data([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16])),
            (1, 1, 2, Data([17, 18, 19, 20, 21, 22, 23, 24])),
            (1, 1, 1, Data([25, 26, 27, 28])),
        ]
        for compressed in [false, true] {
            let data = try makeRawVolume(levels: levels, compressed: compressed)
            #expect(throws: WPETexDecodeError.unsupportedTextureDimension(depth: 4)) {
                _ = try WPETexDecoder().extractTexturePayload(data: data).get()
            }
            let payload = try WPETexDecoder().extractTexturePayload(data: data, allowRawVolume: true).get()
            #expect(payload.info.depth == 4)
            #expect(payload.info.isVolume)
            #expect(payload.mipmaps.map(\.depth) == [4, 2, 1])
            #expect(payload.mipmaps.map(\.bytes) == levels.map(\.3))
            #expect(payload.animationTrack == nil)
            #expect(payload.videoPayload == nil)
            #expect(payload.hasAnimationFrames == false)
            #expect(throws: WPETexDecodeError.unsupportedTextureDimension(depth: 4)) {
                _ = try WPETexDecoder().decode(data: data).get()
            }
        }
    }

    @Test("Malformed volume geometry, truncated z planes and oversized chains fail before materializing")
    func rawVolumeRejectsInvalidGeometryAndByteBudgetsBeforeAllocation() throws {
        let invalid: [[(Int, Int, UInt32, Data)]] = [
            [(1, 1, 4, Data(count: 12))], // Missing the last z plane, although slice zero is complete.
            [(1, 1, 4, Data(count: 16)), (1, 1, 1, Data(count: 4))], // Skips depth=2.
            [(1, 1, 0, Data())],
        ]
        for levels in invalid {
            let meter = WPETexInflateMeter()
            let data = try makeRawVolume(levels: levels)
            let result = WPETexDecoder.$inflateMeter.withValue(meter) {
                WPETexDecoder().extractTexturePayload(data: data, allowRawVolume: true)
            }
            guard case .failure = result else { Issue.record("Malformed volume was accepted"); return }
            #expect(meter.materializedMipBytes == 0)
        }
        // The first LZ4 mip declares exactly the existing 256 MiB budget. Its additional authored mip
        // makes the complete chain too large. Tiny wire payloads ensure this guard never allocates it.
        for compressed in [false, true] {
            let levels: [(Int, Int, UInt32, Data)] = compressed
                ? [(1024, 1024, 64, Data([1])), (512, 512, 32, Data([2]))]
                : [(2048, 2048, 128, Data())]
            let data = try makeRawVolume(levels: levels, compressed: compressed, declaredByteCount: UInt32.max)
            let meter = WPETexInflateMeter()
            let result = WPETexDecoder.$inflateMeter.withValue(meter) {
                WPETexDecoder().extractTexturePayload(data: data, allowRawVolume: true)
            }
            guard case let .failure(.decodeFailed(_, detail)) = result else {
                Issue.record("Expected the volume byte budget failure, got \(result)"); return
            }
            #expect(detail.contains("byte budget"))
            #expect(meter.materializedMipBytes == 0)
        }
        // Independently exercise checked row, slice and total-byte multiplication without large Data.
        for size in [(Int.max, 1, 1), (1, Int.max, 1), (1, 1, Int.max)] {
            #expect(throws: WPETexMipValidation.Invalid.self) {
                _ = try WPETexMipValidation.layout(format: .rgba8888, width: size.0, height: size.1, depth: size.2)
            }
        }
        let mismatched = try makeRawVolume(levels: [(1, 1, 2, Data(count: 8))], declaredDepth: 4)
        #expect(throws: WPETexDecodeError.self) {
            _ = try WPETexDecoder().extractTexturePayload(data: mismatched, allowRawVolume: true).get()
        }
    }

    @Test("TEXI version zero omits the tail word after depth")
    func texiVersionZeroOmitsTail() throws {
        for volume in [false, true] {
            let buffer = makeImageWithTEXIImageDimensions(textureWidth: 2, textureHeight: 2,
                                                          imageWidth: 2, imageHeight: 2, unknownInt0: 0x1234,
                                                          flags: volume ? 0x40 : 0, flag0x40RawBits: volume ? 3 : nil, infoVersion: 0)
            let metadata = try WPETexDecoder().extractRawMetadata(data: buffer).get()
            #expect(metadata.info.infoVersion == 0)
            #expect(metadata.info.unknownInt0 == 0)
            #expect(metadata.info.depth == (volume ? 3 : 1))
            #expect(metadata.bitmap.largestMipmap?.depth == (volume ? 3 : 1))
        }
    }

    @Test(
        "Pinned official LUT bytes retain depth at 42 and the asset-specific tail at 46",
        .enabled(if: officialFlag0x40FixturesAvailable)
    )
    func officialLUTFlag0x40RetainsNativeFieldPositions() throws {
        for fixture in Self.officialFlag0x40Fixtures {
            let url = Self.officialFlag0x40FixtureRoot.appendingPathComponent(fixture.name)
            let data = try Data(contentsOf: url)
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            #expect(hash == fixture.sha256)
            let info = try WPETexDecoder().probe(span: WPEMappedByteSpan(data: data)).get()
            let rawExtension = try #require(info.flag0x40Extension, "\(url.lastPathComponent)")
            #expect(info.flags == 0x42, "\(url.lastPathComponent)")
            #expect(info.imageWidth == 1024, "\(url.lastPathComponent)")
            #expect(info.imageHeight == 32, "\(url.lastPathComponent)")
            #expect(info.depth == 32, "\(url.lastPathComponent)")
            #expect(UInt32(bitPattern: info.unknownInt0) == fixture.tailBits, "\(url.lastPathComponent)")
            #expect(rawExtension.sourceRange == 42 ..< 46, "\(url.lastPathComponent)")
            // 在扩展字段之后的偏移读 TEXB magic,才是对齐的真正证据。
            #expect(data.subdata(in: 50 ..< 58) == Data("TEXB0004".utf8), "\(url.lastPathComponent)")
            #expect(data[58] == 0, "\(url.lastPathComponent)")
        }
    }

    private static var engineNeutralLUT: URL {
        ProcessInfo.processInfo.environment["WPE_ASSETS_DIR"].map {
            URL(fileURLWithPath: $0).appendingPathComponent("materials/lut/neutral.tex")
        } ?? officialFlag0x40FixtureRoot.appendingPathComponent("neutral.tex")
    }

    @Test(
        "Engine neutral.tex PNG unfolds to an identity 32³ RGBA8 volume",
        .enabled(if: FileManager.default.fileExists(atPath: engineNeutralLUT.path))
    )
    func engineNeutralLUTDecodesToIdentityVolume() throws {
        let data = try Data(contentsOf: Self.engineNeutralLUT)
        let payload = try WPETexDecoder().extractTexturePayload(data: data, allowRawVolume: true).get()
        #expect(payload.info.format == .rgba8888)
        #expect(payload.info.isVolume)
        #expect(payload.mipmaps.count == 1)
        let mip = try #require(payload.mipmaps.first)
        #expect([mip.index, mip.width, mip.height, mip.depth] as [Int] == [0, 32, 32, 32])
        let bytes = [UInt8](mip.bytes)
        try #require(bytes.count == 32 * 32 * 32 * 4)
        func level(_ value: Int) -> UInt8 {
            UInt8((Double(255 * value) / 31).rounded())
        }
        var mismatches: [String] = []
        for z in 0 ..< 32 {
            for y in 0 ..< 32 {
                for x in 0 ..< 32 {
                    let offset = ((z * 32 + y) * 32 + x) * 4
                    let texel = Array(bytes[offset ..< offset + 4])
                    if texel != [level(x), level(y), level(z), 255] {
                        mismatches.append("(\(x),\(y),\(z))=\(texel)")
                    }
                }
            }
        }
        #expect(mismatches.isEmpty, "\(mismatches.count) texels differ, first: \(mismatches.prefix(4))")
    }

    @Test("Streaming extraction preserves TEXS sub-rects and compressed image payloads")
    func streamingExtractionPreservesSubRectsAndCompressedPayloads() throws {
        let width = 4
        let height = 4
        let raw0 = Data(repeating: 0x11, count: width * height * 4)
        let raw1 = Data(repeating: 0x22, count: width * height * 4)
        let compressed0 = try lz4RawCompress(raw0)
        let compressed1 = try lz4RawCompress(raw1)
        let buffer = makeStreamingTestImage(
            width: width,
            height: height,
            declaredWidth: 8,
            declaredHeight: 8,
            compressedPayloads: [compressed0, compressed1],
            decompressedByteCount: width * height * 4
        )

        let payload = try WPETexDecoder().extractStreamingPayload(data: buffer).get()

        #expect(payload.compressedImages.count == 2)
        #expect(payload.compressedImages[0].payloads[0].compressedBytes.materializedData() == compressed0)
        #expect(payload.compressedImages[0].payloads[0].isCompressed == true)
        #expect(payload.compressedImages[0].payloads[0].decompressedByteCount == width * height * 4)
        #expect(payload.frames.count == 4)
        #expect(payload.frames[0].imageID == 0)
        #expect(payload.frames[0].subRect == CGRect(x: 0, y: 0, width: 4, height: 2))
        #expect(payload.frames[1].imageID == 0)
        // TEXI may describe a larger logical surface; TEXS clamps and
        // normalizes against the selected source image's actual dimensions.
        #expect(payload.frames[1].subRect == CGRect(x: 2, y: 2, width: 2, height: 2))
        #expect(payload.frames[1].samplingDescriptor == WPETexSpriteSamplingDescriptor(
            rotation: SIMD4<Float>(1, 0, 0, 0.5),
            translation: SIMD2<Float>(0.5, 0.5)
        ))
        #expect(payload.frames[2].imageID == 1)
        #expect(payload.frameRate > 0)
        #expect(payload.loop == true)
    }

    // MARK: - Fixture helpers

    private func makeRawVolume(levels: [(Int, Int, UInt32, Data)], compressed: Bool = false,
                               declaredDepth: UInt32? = nil, declaredByteCount: UInt32? = nil) throws -> Data {
        let first = levels[0]
        var data = Data()
        appendMagic(&data, magic: "TEXV0005")
        appendMagic(&data, magic: "TEXI0001")
        for word in [UInt32(0), 0x40, UInt32(first.0), UInt32(first.1), UInt32(first.0), UInt32(first.1),
                     declaredDepth ?? first.2, 0] {
            appendUInt32(&data, word)
        }
        appendMagic(&data, magic: "TEXB0003")
        for word in [UInt32(1), UInt32.max, UInt32(levels.count)] {
            appendUInt32(&data, word)
        }
        // Official LZ4 block format: the final sequence is literals only, without a match offset.
        // These fixed tiny blocks avoid Compression's encoder declining non-compressible input.
        // https://github.com/lz4/lz4/blob/dev/doc/lz4_Block_format.md (revised 2022-07-31)
        let literalHeaders: [Int: [UInt8]] = [1: [0x10], 4: [0x40], 8: [0x80], 16: [0xF0, 0x01]]
        for (width, height, depth, bytes) in levels {
            let wire: Data
            if compressed {
                guard let header = literalHeaders[bytes.count] else {
                    throw NSError(domain: "LZ4LiteralFixture", code: bytes.count)
                }
                wire = Data(header) + bytes
            } else {
                wire = bytes
            }
            let header: [UInt32] = [UInt32(width), UInt32(height), depth, compressed ? 1 : 0,
                                    declaredByteCount ?? UInt32(bytes.count), UInt32(wire.count)]
            for word in header {
                appendUInt32(&data, word)
            }
            data.append(wire)
        }
        return data
    }

    private func makeRGBA8888TestImage(width: Int, height: Int) -> Data {
        let pixel: [UInt8] = [0xff, 0x80, 0x33, 0xff]
        var raw = Data()
        raw.reserveCapacity(width * height * 4)
        for _ in 0..<(width * height) { raw.append(contentsOf: pixel) }
        return makeImage(
            width: width,
            height: height,
            formatCode: WPETexFormat.rgba8888.rawValue,
            payload: raw
        )
    }

    private func makeImage(
        width: Int,
        height: Int,
        formatCode: Int,
        payload: Data,
        isLZ4Compressed: Bool = false,
        decompressedByteCount: Int? = nil
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
        appendInt32(&buffer, -1)
        appendInt32(&buffer, 1)
        appendInt32(&buffer, Int32(width))
        appendInt32(&buffer, Int32(height))
        appendUInt32(&buffer, isLZ4Compressed ? 1 : 0)
        appendUInt32(&buffer, UInt32(decompressedByteCount ?? payload.count))
        appendUInt32(&buffer, UInt32(payload.count))
        buffer.append(payload)
        return buffer
    }

    private func makeTEXB0003PNGBackedImage() -> Data {
        let payload = onePixelPNG()
        var buffer = Data()
        appendMagic(&buffer, magic: "TEXV0005")
        appendMagic(&buffer, magic: "TEXI0001")
        appendInt32(&buffer, Int32(WPETexFormat.rgba8888.rawValue))
        appendUInt32(&buffer, 2)
        appendInt32(&buffer, 1)
        appendInt32(&buffer, 1)
        appendInt32(&buffer, 1)
        appendInt32(&buffer, 1)
        appendInt32(&buffer, 0)

        appendMagic(&buffer, magic: "TEXB0003")
        appendInt32(&buffer, 1)
        appendInt32(&buffer, 13)
        appendInt32(&buffer, 1)
        appendInt32(&buffer, 1)
        appendInt32(&buffer, 1)
        appendUInt32(&buffer, 0)
        appendUInt32(&buffer, 0)
        appendUInt32(&buffer, UInt32(payload.count))
        buffer.append(payload)
        return buffer
    }

    private func onePixelPNG() -> Data {
        Data([
            0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
            0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
            0x08, 0x06, 0x00, 0x00, 0x00, 0x1f, 0x15, 0xc4,
            0x89, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x44, 0x41,
            0x54, 0x78, 0x9c, 0x63, 0xf8, 0xcf, 0xc0, 0xf0,
            0x1f, 0x00, 0x05, 0x00, 0x01, 0xff, 0x89, 0x99,
            0x3d, 0x1d, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45,
            0x4e, 0x44, 0xae, 0x42, 0x60, 0x82
        ])
    }

    private func mp4HeaderPayload() -> Data {
        Data([
            0x00, 0x00, 0x00, 0x18,
            0x66, 0x74, 0x79, 0x70,
            0x6d, 0x70, 0x34, 0x32,
            0x00, 0x00, 0x00, 0x00,
            0x6d, 0x70, 0x34, 0x32,
            0x69, 0x73, 0x6f, 0x6d
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

    private func appendFloat32(_ data: inout Data, _ value: Float) {
        var bits = value.bitPattern.littleEndian
        withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
    }

    private func makeStreamingTestImage(
        width: Int,
        height: Int,
        declaredWidth: Int? = nil,
        declaredHeight: Int? = nil,
        compressedPayloads: [Data],
        decompressedByteCount: Int
    ) -> Data {
        var buffer = Data()
        appendMagic(&buffer, magic: "TEXV0005")
        appendMagic(&buffer, magic: "TEXI0001")
        appendInt32(&buffer, Int32(WPETexFormat.rgba8888.rawValue))
        appendUInt32(&buffer, 0)
        appendInt32(&buffer, Int32(declaredWidth ?? width))
        appendInt32(&buffer, Int32(declaredHeight ?? height))
        appendInt32(&buffer, Int32(declaredWidth ?? width))
        appendInt32(&buffer, Int32(declaredHeight ?? height))
        appendInt32(&buffer, 0)

        appendMagic(&buffer, magic: "TEXB0004")
        appendInt32(&buffer, Int32(compressedPayloads.count))
        appendInt32(&buffer, -1)
        appendInt32(&buffer, 0)
        for payload in compressedPayloads {
            appendInt32(&buffer, 1)
            appendInt32(&buffer, Int32(width))
            appendInt32(&buffer, Int32(height))
            appendUInt32(&buffer, 1)
            appendUInt32(&buffer, UInt32(decompressedByteCount))
            appendUInt32(&buffer, UInt32(payload.count))
            buffer.append(payload)
        }

        appendMagic(&buffer, magic: "TEXS0003")
        appendInt32(&buffer, 4)
        appendInt32(&buffer, Int32(width))
        appendInt32(&buffer, Int32(height))
        let fullWidth = Float(width)
        let halfWidth = Float(width / 2)
        let halfHeight = Float(height / 2)
        let regions: [(Int, (Float, Float, Float, Float))] = [
            (0, (0, 0, fullWidth, halfHeight)),
            (0, (halfWidth, halfHeight, fullWidth, halfHeight)),
            (1, (0, 0, fullWidth, halfHeight)),
            (1, (0, halfHeight, fullWidth, halfHeight)),
        ]
        for (imageID, rect) in regions {
            appendInt32(&buffer, Int32(imageID))
            appendFloat32(&buffer, 0.03)
            appendFloat32(&buffer, rect.0)
            appendFloat32(&buffer, rect.1)
            appendFloat32(&buffer, rect.2)
            appendFloat32(&buffer, 0)
            appendFloat32(&buffer, 0)
            appendFloat32(&buffer, rect.3)
        }
        return buffer
    }

    private func makeEncodedPNGAtlasWithTEXS() -> Data {
        let pngBytes = twoByTwoPNGAtlas()
        var buffer = Data()
        appendMagic(&buffer, magic: "TEXV0005")
        appendMagic(&buffer, magic: "TEXI0001")
        appendInt32(&buffer, Int32(WPETexFormat.rgba8888.rawValue))
        appendUInt32(&buffer, 2)
        appendInt32(&buffer, 4)
        appendInt32(&buffer, 4)
        appendInt32(&buffer, 4)
        appendInt32(&buffer, 4)
        appendInt32(&buffer, 0)

        appendMagic(&buffer, magic: "TEXB0003")
        appendInt32(&buffer, 1)
        appendInt32(&buffer, 13)
        appendInt32(&buffer, 1)
        appendInt32(&buffer, 4)
        appendInt32(&buffer, 4)
        appendUInt32(&buffer, 0)
        appendUInt32(&buffer, UInt32(pngBytes.count))
        appendUInt32(&buffer, UInt32(pngBytes.count))
        buffer.append(pngBytes)

        appendMagic(&buffer, magic: "TEXS0003")
        appendInt32(&buffer, 2)
        appendInt32(&buffer, 4)
        appendInt32(&buffer, 4)
        for (imageID, transform) in [
            (0, (Float(0), Float(0), Float(2), Float(0), Float(0), Float(2))),
            (0, (Float(2), Float(0), Float(2), Float(1), Float(-1), Float(2)))
        ] {
            appendInt32(&buffer, Int32(imageID))
            appendFloat32(&buffer, 0.04)
            appendFloat32(&buffer, transform.0)
            appendFloat32(&buffer, transform.1)
            appendFloat32(&buffer, transform.2)
            appendFloat32(&buffer, transform.3)
            appendFloat32(&buffer, transform.4)
            appendFloat32(&buffer, transform.5)
        }
        return buffer
    }

    private func twoByTwoPNGAtlas() -> Data {
        var pixels = Data()
        pixels.reserveCapacity(4 * 4 * 4)
        for row in 0..<4 {
            for col in 0..<4 {
                let red: UInt8 = col < 2 ? 0xff : 0x00
                let green: UInt8 = row < 2 ? 0xff : 0x00
                pixels.append(contentsOf: [red, green, 0x00, 0xff])
            }
        }
        let provider = CGDataProvider(data: pixels as CFData)!
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)
        let image = CGImage(
            width: 4, height: 4,
            bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 16,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
        let mutable = NSMutableData()
        let destination = CGImageDestinationCreateWithData(mutable, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return mutable as Data
    }

    private func makeImageWithTEXIImageDimensions(
        textureWidth: Int,
        textureHeight: Int,
        imageWidth: Int,
        imageHeight: Int,
        unknownInt0: Int32,
        flags: UInt32 = 0,
        flag0x40RawBits: UInt32? = nil,
        infoVersion: Int = 1
    ) -> Data {
        precondition((flags & WPETexInfo.rawExtensionFlag != 0) == (flag0x40RawBits != nil))
        let pixel: [UInt8] = [0xff, 0x80, 0x33, 0xff]
        var raw = Data()
        raw.reserveCapacity(textureWidth * textureHeight * 4)
        for _ in 0..<(textureWidth * textureHeight) { raw.append(contentsOf: pixel) }
        var buffer = Data()
        appendMagic(&buffer, magic: "TEXV0005")
        appendMagic(&buffer, magic: infoVersion == 0 ? "TEXI0000" : "TEXI0001")
        appendInt32(&buffer, Int32(WPETexFormat.rgba8888.rawValue))
        appendUInt32(&buffer, flags)
        appendInt32(&buffer, Int32(textureWidth))
        appendInt32(&buffer, Int32(textureHeight))
        appendInt32(&buffer, Int32(imageWidth))
        appendInt32(&buffer, Int32(imageHeight))
        if let rawBits = flag0x40RawBits {
            appendInt32(&buffer, Int32(bitPattern: rawBits))
        }
        if infoVersion > 0 {
            appendInt32(&buffer, unknownInt0)
        }

        appendMagic(&buffer, magic: "TEXB0003")
        appendInt32(&buffer, 1)
        appendInt32(&buffer, -1)
        appendInt32(&buffer, 1)
        appendInt32(&buffer, Int32(textureWidth))
        appendInt32(&buffer, Int32(textureHeight))
        if let depth = flag0x40RawBits {
            appendUInt32(&buffer, depth)
        }
        appendUInt32(&buffer, 0)
        appendUInt32(&buffer, UInt32(raw.count))
        appendUInt32(&buffer, UInt32(raw.count))
        buffer.append(raw)
        return buffer
    }

    private func lz4RawCompress(_ data: Data) throws -> Data {
        let dstCapacity = data.count + 64
        var dst = Data(count: dstCapacity)
        let written = dst.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) -> Int in
            data.withUnsafeBytes { (input: UnsafeRawBufferPointer) -> Int in
                guard let dstPtr = out.bindMemory(to: UInt8.self).baseAddress,
                      let srcPtr = input.bindMemory(to: UInt8.self).baseAddress else {
                    return -1
                }
                return compression_encode_buffer(
                    dstPtr, dstCapacity,
                    srcPtr, data.count,
                    nil,
                    COMPRESSION_LZ4_RAW
                )
            }
        }
        guard written > 0 else {
            throw NSError(domain: "lz4", code: -1)
        }
        return dst.prefix(written)
    }
}

extension WPETexDecoderTests {
    // MARK: - TEXB0004 conditional variants

    @Test("TEXB0004 conditional-variant table parses and the base image still decodes")
    func conditionalVariantTexB0004DecodesBaseImage() throws {
        let png = twoByTwoPNGAtlas()
        let buffer = makeConditionalVariantTexB0004(png: png)

        let image = try WPETexDecoder().decode(data: buffer).get()
        #expect(image.width == 4 && image.height == 4)

        let metadata = try WPETexDecoder().extractRawMetadata(data: buffer).get()
        #expect(metadata.bitmap.frames.count == 1)
        #expect(metadata.bitmap.isVideoPayload == false)
        let variants = metadata.bitmap.conditionalVariants
        #expect(variants.map(\.variantID) == [1, 2])
        #expect(String(bytes: variants[0].conditionBytes, encoding: .utf8)?.contains("blank") == true)
        #expect(String(bytes: variants[1].conditionBytes, encoding: .utf8)?.contains("discord") == true)
        let records = metadata.bitmap.conditionalRecords
        #expect(records.map(\.variantID) == [1, 2])
        #expect(records[1].x == 1 && records[1].y == 1)
        #expect(records[1].width == 2 && records[1].height == 2)

        let payload = try WPETexDecoder().extractTexturePayload(data: buffer).get()
        #expect(payload.hasConditionalVariants)
        #expect(payload.hasAnimationFrames == false)
        #expect(payload.mipmaps.first?.width == 4)
    }

    /// Mirrors `WiiButtonLight.tex` (Workshop 3536863181): a TEXB0004 whose
    /// third field counts conditional images — a `[1][id][0][condition]`
    /// table, then one `[1][id][x][y][w][h][fmt][size][payload]` record per
    /// variant after every base mip.
    private func makeConditionalVariantTexB0004(png: Data) -> Data {
        var buffer = Data()
        appendMagic(&buffer, magic: "TEXV0005")
        appendMagic(&buffer, magic: "TEXI0001")
        appendInt32(&buffer, Int32(WPETexFormat.rgba8888.rawValue))
        appendUInt32(&buffer, 0)
        appendInt32(&buffer, 4)
        appendInt32(&buffer, 4)
        appendInt32(&buffer, 4)
        appendInt32(&buffer, 4)
        appendInt32(&buffer, 0)

        appendMagic(&buffer, magic: "TEXB0004")
        appendInt32(&buffer, 1)
        appendInt32(&buffer, 13)
        appendInt32(&buffer, 2)
        for (imageID, condition) in [
            (1, #"{"condition":{"condition":"blank","name":"buttoniconleft"}}"#),
            (2, #"{"condition":{"condition":"discord","name":"buttoniconleft"}}"#),
        ] {
            appendInt32(&buffer, 1)
            appendInt32(&buffer, Int32(imageID))
            appendInt32(&buffer, 0)
            buffer.append(contentsOf: condition.utf8)
            buffer.append(0x00)
        }

        appendInt32(&buffer, 1)
        appendInt32(&buffer, 4)
        appendInt32(&buffer, 4)
        appendUInt32(&buffer, 0)
        appendUInt32(&buffer, 0)
        appendUInt32(&buffer, UInt32(png.count))
        buffer.append(png)
        appendInt32(&buffer, 1)
        appendInt32(&buffer, 2)
        for (imageID, x, y, w, h) in [(1, 0, 0, 4, 4), (2, 1, 1, 2, 2)] {
            appendInt32(&buffer, 1)
            appendInt32(&buffer, Int32(imageID))
            appendInt32(&buffer, Int32(x))
            appendInt32(&buffer, Int32(y))
            appendInt32(&buffer, Int32(w))
            appendInt32(&buffer, Int32(h))
            appendInt32(&buffer, 13)
            appendUInt32(&buffer, UInt32(png.count))
            buffer.append(png)
        }
        return buffer
    }

    @Test("TEXS rejects nonfinite time and every geometry lane before publishing either payload",
          arguments: [Float.nan, Float.infinity, -Float.infinity], Array(0 ... 6))
    func rejectsNonfiniteTEXS(value: Float, field: Int) throws {
        var data = try makeStreamingTestImage(width: 4, height: 4,
                                              compressedPayloads: [lz4RawCompress(Data(repeating: 0, count: 64))], decompressedByteCount: 64)
        _ = try WPETexDecoder().extractStreamingPayload(data: data).get()
        _ = try WPETexDecoder().extractTexturePayload(data: data).get()
        let marker = try #require(data.range(of: Data("TEXS0003\0".utf8)))
        // TEXS3: frameCount, gifWidth, gifHeight, imageID, then time and six geometry floats.
        let offset = marker.upperBound + 16 + field * 4
        var bits = value.bitPattern.littleEndian
        withUnsafeBytes(of: &bits) { data.replaceSubrange(offset ..< (offset + 4), with: $0) }
        #expect(throws: (any Error).self) { try WPETexDecoder().extractStreamingPayload(data: data).get() }
        #expect(throws: (any Error).self) { try WPETexDecoder().extractTexturePayload(data: data).get() }
    }
}
