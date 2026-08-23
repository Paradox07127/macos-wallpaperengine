import Foundation
import LiveWallpaperProWPE
import Metal
import Testing
@testable import LiveWallpaper

/// W5: the decoder must LZ4-inflate only the mip levels the Metal upload will
/// actually read, and the uploaded texels must stay byte-identical to what the
/// inflate-everything decode produced.
@Suite("WPE .tex mip inflate scope")
struct WPETexMipInflateScopeTests {

    // 256×256 chain: min(level0) > 64 so the data-texture exemption is off.
    private static let levelSizes = [256, 128, 64, 32]
    private static func levelByteCount(_ edge: Int) -> Int { edge * edge * 4 }
    private static var wholeChainBytes: Int { levelSizes.reduce(0) { $0 + levelByteCount($1) } }

    // MARK: - How many bytes get inflated

    @Test("Default configuration inflates level 0 only, not the whole chain")
    func defaultConfigurationInflatesLevelZeroOnly() throws {
        try withMipChainDefault(nil) {
            let meter = WPETexInflateMeter()
            let payload = try decode(
                Self.mipChainTex(),
                scope: WPEMetalTextureLoader.mipInflateScope(maxSourceEdge: nil),
                meter: meter
            )

            #expect(
                meter.materializedMipBytes == Self.levelByteCount(256),
                "expected level 0 only (\(Self.levelByteCount(256))B), whole chain is \(Self.wholeChainBytes)B"
            )
            #expect(payload.mipmaps.count == 4, "every level keeps its metadata row")
            #expect(payload.mipmaps[0].bytes.count == Self.levelByteCount(256))
            #expect(payload.mipmaps.dropFirst().allSatisfy { $0.bytes.isEmpty })
        }
    }

    @Test("mipChainOverride ON inflates the whole chain")
    func mipChainOverrideInflatesWholeChain() throws {
        try withMipChainDefault(true) {
            let meter = WPETexInflateMeter()
            let payload = try decode(
                Self.mipChainTex(),
                scope: WPEMetalTextureLoader.mipInflateScope(maxSourceEdge: nil),
                meter: meter
            )

            #expect(meter.materializedMipBytes == Self.wholeChainBytes)
            #expect(payload.mipmaps.allSatisfy { !$0.bytes.isEmpty })
        }
    }

    @Test("Render-scale cap inflates the selected levels only")
    func renderScaleCapInflatesSelectedLevelsOnly() throws {
        try withMipChainDefault(nil) {
            let meter = WPETexInflateMeter()
            // cap 100 → smallest level still covering it is 128 (index 1).
            let payload = try decode(
                Self.mipChainTex(),
                scope: WPEMetalTextureLoader.mipInflateScope(maxSourceEdge: 100),
                meter: meter
            )

            let expected = Self.levelByteCount(128) + Self.levelByteCount(64) + Self.levelByteCount(32)
            #expect(
                meter.materializedMipBytes == expected,
                "expected levels 1…3 (\(expected)B); level 0 alone is \(Self.levelByteCount(256))B"
            )
            #expect(payload.mipmaps[0].bytes.isEmpty, "level 0 is above the cap and must stay compressed")
            #expect(payload.mipmaps.dropFirst().allSatisfy { !$0.bytes.isEmpty })
        }
    }

    @Test("noInterpolation data textures keep level 0 under a cap")
    func noInterpolationDataTextureKeepsLevelZeroUnderCap() throws {
        try withMipChainDefault(nil) {
            let meter = WPETexInflateMeter()
            let payload = try decode(
                Self.mipChainTex(flags: WPETexInfo.noInterpolationFlag),
                scope: WPEMetalTextureLoader.mipInflateScope(maxSourceEdge: 100),
                meter: meter
            )

            #expect(payload.info.noInterpolation)
            #expect(payload.mipmaps[0].bytes.count == Self.levelByteCount(256), "level 0 must not be cropped away")
            #expect(meter.materializedMipBytes == Self.wholeChainBytes)
        }
    }

    @Test("Strip-shaped LUTs keep level 0 under a cap")
    func stripShapedLUTKeepsLevelZeroUnderCap() throws {
        try withMipChainDefault(nil) {
            let meter = WPETexInflateMeter()
            // 256×64: min edge ≤ 64 → data texture, exempt from the cap.
            let tex = Self.tex(levels: [(256, 64), (128, 32)], flags: 0)
            let payload = try decode(
                tex,
                scope: WPEMetalTextureLoader.mipInflateScope(maxSourceEdge: 100),
                meter: meter
            )

            #expect(payload.mipmaps[0].bytes.count == 256 * 64 * 4)
            #expect(meter.materializedMipBytes == 256 * 64 * 4 + 128 * 32 * 4)
        }
    }

    // MARK: - Paths that must be untouched

    @Test("Streaming payload extraction inflates nothing under any scope")
    func streamingPayloadInflatesNothing() throws {
        let meter = WPETexInflateMeter()
        let tex = Self.animatedTex()
        let payload = try WPETexDecoder.$mipInflateScope.withValue(
            WPEMetalTextureLoader.mipInflateScope(maxSourceEdge: 100)
        ) {
            try WPETexDecoder.$inflateMeter.withValue(meter) {
                try WPETexDecoder().extractStreamingPayload(data: tex).get()
            }
        }

        #expect(payload.compressedImages.count == 2)
        #expect(meter.materializedMipBytes == 0)
    }

    @Test("Animation track keeps every level even when the scope is narrowed")
    func animationTrackKeepsEveryLevel() throws {
        try withMipChainDefault(nil) {
            let meter = WPETexInflateMeter()
            let payload = try decode(
                Self.animatedTex(),
                scope: WPEMetalTextureLoader.mipInflateScope(maxSourceEdge: 100),
                meter: meter
            )

            let track = try #require(payload.animationTrack)
            #expect(track.frames.count == 2)
            for frame in track.frames {
                let atlas = try #require(frame.mipmaps.first)
                #expect(atlas.bytes.count == Self.levelByteCount(256))
            }
            #expect(!payload.mipmaps.isEmpty, "attachAtlasProvider keys off this staying non-empty")
        }
    }

    @Test("Video payload is unaffected by the scope")
    func videoPayloadUnaffectedByScope() throws {
        let meter = WPETexInflateMeter()
        let payload = try decode(
            Self.videoTex(),
            scope: WPEMetalTextureLoader.mipInflateScope(maxSourceEdge: 100),
            meter: meter
        )

        #expect(payload.videoPayload != nil)
        #expect(meter.materializedMipBytes == 0)
    }

    // MARK: - Byte-for-byte upload equality

    @Test("Uploaded texels are byte-identical with and without the scope (no cap)")
    func uploadedTexelsIdenticalWithoutCap() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let restore = Self.pinMipChainDefault(nil)
        defer { restore() }
        let tex = Self.mipChainTex()
        let full = try decode(tex, scope: .fullChain, meter: nil)
        let scoped = try decode(tex, scope: WPEMetalTextureLoader.mipInflateScope(maxSourceEdge: nil), meter: nil)

        let loader = WPEMetalTextureLoader(device: device)
        let fullTexture = try await loader.makeTexture(from: full, label: "w5-full")
        let scopedTexture = try await loader.makeTexture(from: scoped, label: "w5-scoped")

        #expect(scopedTexture.mipmapLevelCount == fullTexture.mipmapLevelCount)
        #expect(scopedTexture.width == fullTexture.width && scopedTexture.height == fullTexture.height)
        // Positive control: the comparison below must not be two empty buffers.
        #expect(Self.readBack(scopedTexture, level: 0).allSatisfy { $0 == Self.fillByte(level: 0) })
        for level in 0..<fullTexture.mipmapLevelCount {
            #expect(Self.readBack(fullTexture, level: level) == Self.readBack(scopedTexture, level: level))
        }
    }

    @Test("Uploaded texels are byte-identical with and without the scope (render-scale cap)")
    func uploadedTexelsIdenticalUnderCap() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let restore = Self.pinMipChainDefault(nil)
        defer { restore() }
        let tex = Self.mipChainTex()
        let cap = 100
        let full = try decode(tex, scope: .fullChain, meter: nil)
        let scoped = try decode(tex, scope: WPEMetalTextureLoader.mipInflateScope(maxSourceEdge: cap), meter: nil)

        let loader = WPEMetalTextureLoader(device: device)
        let fullTexture = try await loader.makeTexture(from: full, label: "w5-full-cap", maxSourceEdge: cap)
        let scopedTexture = try await loader.makeTexture(from: scoped, label: "w5-scoped-cap", maxSourceEdge: cap)

        #expect(fullTexture.width == 128, "the cap must actually have moved the upload off level 0")
        #expect(fullTexture.mipmapLevelCount == 3)
        #expect(scopedTexture.mipmapLevelCount == fullTexture.mipmapLevelCount)
        #expect(scopedTexture.width == fullTexture.width && scopedTexture.height == fullTexture.height)
        // Positive control: mip 0 of the capped upload is SOURCE level 1.
        #expect(Self.readBack(scopedTexture, level: 0).allSatisfy { $0 == Self.fillByte(level: 1) })
        #expect(Self.readBack(scopedTexture, level: 2).allSatisfy { $0 == Self.fillByte(level: 3) })
        for level in 0..<fullTexture.mipmapLevelCount {
            #expect(Self.readBack(fullTexture, level: level) == Self.readBack(scopedTexture, level: level))
        }
    }

    // MARK: - Helpers

    private func decode(
        _ tex: Data,
        scope: WPETexMipInflateScope,
        meter: WPETexInflateMeter?
    ) throws -> WPETexTexturePayload {
        try WPETexDecoder.$mipInflateScope.withValue(scope) {
            try WPETexDecoder.$inflateMeter.withValue(meter) {
                try WPETexDecoder().extractTexturePayload(data: tex).get()
            }
        }
    }

    /// `mipChainOverride` is read from `UserDefaults.standard`; pin it and hand
    /// back the restore closure for whatever the machine had.
    private static func pinMipChainDefault(_ value: Bool?) -> () -> Void {
        let defaults = UserDefaults.standard
        let key = WPEMetalTextureLoader.mipChainDefaultsKey
        let previous = defaults.object(forKey: key)
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        return {
            if let previous { defaults.set(previous, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
    }

    private func withMipChainDefault(_ value: Bool?, _ body: () throws -> Void) throws {
        let restore = Self.pinMipChainDefault(value)
        defer { restore() }
        try body()
    }

    private static func readBack(_ texture: MTLTexture, level: Int) -> Data {
        let width = max(texture.width >> level, 1)
        let height = max(texture.height >> level, 1)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { raw in
            texture.getBytes(
                raw.baseAddress!,
                bytesPerRow: width * 4,
                from: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: level
            )
        }
        return Data(bytes)
    }

    // MARK: - `.tex` fixtures

    private static func mipChainTex(flags: UInt32 = 0) -> Data {
        tex(levels: levelSizes.map { ($0, $0) }, flags: flags)
    }

    /// Single-image TEXV0005/TEXI0001/TEXB0003 with an uncompressed RGBA8888
    /// chain; each level is filled with a distinct byte so a wrong-level upload
    /// shows up in the read-back comparison.
    private static func tex(levels: [(Int, Int)], flags: UInt32) -> Data {
        var buffer = Data()
        appendHeader(&buffer, width: levels[0].0, height: levels[0].1, flags: flags)
        appendMagic(&buffer, "TEXB0003")
        appendInt32(&buffer, 1)   // imageCount
        appendInt32(&buffer, -1)  // imageFormat: raw
        appendImage(&buffer, levels: levels, fillOffset: 0)
        return buffer
    }

    private static func animatedTex() -> Data {
        var buffer = Data()
        appendHeader(&buffer, width: 256, height: 256, flags: 0)
        appendMagic(&buffer, "TEXB0003")
        appendInt32(&buffer, 2)
        appendInt32(&buffer, -1)
        appendImage(&buffer, levels: [(256, 256)], fillOffset: 0)
        appendImage(&buffer, levels: [(256, 256)], fillOffset: 1)
        return buffer
    }

    /// TEXB0003 + an MP4 magic payload: `makeVideoPayload`'s `looksLikeMP4Payload`
    /// route, same shape the existing `WPETexTexturePayloadTests` fixture uses.
    private static func videoTex() -> Data {
        var buffer = Data()
        appendHeader(&buffer, width: 4, height: 4, flags: 0)
        appendMagic(&buffer, "TEXB0003")
        appendInt32(&buffer, 1)
        appendInt32(&buffer, -1)
        let mp4 = Data([
            0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70,
            0x6d, 0x70, 0x34, 0x32, 0x00, 0x00, 0x00, 0x00,
            0x6d, 0x70, 0x34, 0x32, 0x69, 0x73, 0x6f, 0x6d
        ])
        appendInt32(&buffer, 1)  // mipCount
        appendInt32(&buffer, 4)
        appendInt32(&buffer, 4)
        appendUInt32(&buffer, 0)
        appendUInt32(&buffer, UInt32(mp4.count))
        appendUInt32(&buffer, UInt32(mp4.count))
        buffer.append(mp4)
        return buffer
    }

    /// Distinct constant per level so a wrong-level upload shows up in read-back.
    static func fillByte(level: Int, image: Int = 0) -> UInt8 {
        UInt8((level * 17 + image * 3 + 1) & 0xFF)
    }

    private static func appendImage(_ buffer: inout Data, levels: [(Int, Int)], fillOffset: Int) {
        appendInt32(&buffer, Int32(levels.count))
        for (position, level) in levels.enumerated() {
            let bytes = Data(
                repeating: fillByte(level: position, image: fillOffset),
                count: level.0 * level.1 * 4
            )
            appendInt32(&buffer, Int32(level.0))
            appendInt32(&buffer, Int32(level.1))
            appendUInt32(&buffer, 0)                      // not LZ4
            appendUInt32(&buffer, UInt32(bytes.count))
            appendUInt32(&buffer, UInt32(bytes.count))
            buffer.append(bytes)
        }
    }

    private static func appendHeader(_ buffer: inout Data, width: Int, height: Int, flags: UInt32) {
        appendMagic(&buffer, "TEXV0005")
        appendMagic(&buffer, "TEXI0001")
        appendInt32(&buffer, Int32(WPETexFormat.rgba8888.rawValue))
        appendUInt32(&buffer, flags)
        appendInt32(&buffer, Int32(width))
        appendInt32(&buffer, Int32(height))
        appendInt32(&buffer, Int32(width))
        appendInt32(&buffer, Int32(height))
        appendInt32(&buffer, 0)
    }

    private static func appendMagic(_ data: inout Data, _ magic: String) {
        data.append(contentsOf: magic.utf8)
        data.append(0x00)
    }

    private static func appendInt32(_ data: inout Data, _ value: Int32) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    private static func appendUInt32(_ data: inout Data, _ value: UInt32) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }
}
