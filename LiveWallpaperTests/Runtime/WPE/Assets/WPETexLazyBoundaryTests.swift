import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import Testing

@Suite("Lazy TEX input boundaries")
@MainActor
struct WPETexLazyBoundaryTests {
    @Test("Whole BC frames preserve partial edge blocks", arguments: [WPETexFormat.dxt1, .dxt3, .dxt5, .bc7], [1, 2, 5])
    func wholeBCFrame(format: WPETexFormat, width: Int) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let height = width == 5 ? 3 : width
        let payload = try payload(format: format, width: width, height: height,
                                  rect: CGRect(x: 0, y: 0, width: width, height: height))
        let source = try WPETexLazyAnimatedTextureSource(payload: payload, device: device, label: "BC edge")
        let texture = try #require(source.texture(at: 0))
        #expect(texture.width == width && texture.height == height)
        #expect(try rawBytes(texture, format: format) == payload.compressedImages[0].payloads[0].compressedBytes.materializedData())
    }

    @Test("BC edge crop uses ceil block counts and preserves the final block", arguments: [WPETexFormat.dxt1, .dxt3, .dxt5, .bc7])
    func bcEdgeCrop(format: WPETexFormat) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let payload = try payload(format: format, width: 5, height: 3, rect: CGRect(x: 4, y: 0, width: 1, height: 3))
        let source = try WPETexLazyAnimatedTextureSource(payload: payload, device: device, label: "BC crop")
        let texture = try #require(source.texture(at: 0))
        #expect(texture.width == 1 && texture.height == 3)
        let all = payload.compressedImages[0].payloads[0].compressedBytes.materializedData()
        #expect(try rawBytes(texture, format: format) == Data(all.suffix(#require(format.bytesPerBlock))))
    }

    @Test("BC interior nonaligned crop is still rejected")
    func rejectsInteriorBCPartialBlock() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let payload = try payload(format: .dxt1, width: 8, height: 8, rect: CGRect(x: 0, y: 0, width: 1, height: 1))
        let source = try WPETexLazyAnimatedTextureSource(payload: payload, device: device, label: "invalid BC crop")
        #expect(source.texture(at: 0) == nil)
    }

    @Test("Direct streaming payload rejects nonfinite geometry and timing", arguments: [Double.nan, Double.infinity, -Double.infinity])
    func rejectsNonfinite(value: Double) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        for field in 0 ..< 5 {
            var coordinates = [CGFloat(0), 0, 4, 4]
            if field < 4 {
                coordinates[field] = CGFloat(value)
            }
            let payload = try payload(format: .rgba8888, width: 4, height: 4,
                                      rect: CGRect(x: coordinates[0], y: coordinates[1], width: coordinates[2], height: coordinates[3]),
                                      duration: field == 4 ? value : 0.1)
            #expect(throws: WPETexLazyAnimatedTextureSource.Failure.invalidFrameGeometryOrTiming) {
                try WPETexLazyAnimatedTextureSource(payload: payload, device: device, label: "invalid TEXS")
            }
        }
    }

    @Test("Finite coordinates outside Int range clamp safely before conversion")
    func hugeFiniteCropCoordinates() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let payload = try payload(format: .rgba8888, width: 4, height: 4,
                                  rect: CGRect(x: 1e100, y: -1e100, width: 1e100, height: 1e100))
        let source = try WPETexLazyAnimatedTextureSource(payload: payload, device: device, label: "large TEXS")
        let texture = try #require(source.texture(at: 0))
        #expect(texture.width == 1 && texture.height == 4)
    }

    @Test("Finite zero and negative durations retain the existing default interval", arguments: [Double(0), -1])
    func nonpositiveDurationDefaults(duration: Double) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let payload = try payload(format: .rgba8888, width: 4, height: 4,
                                  rect: CGRect(x: 0, y: 0, width: 4, height: 4), duration: duration)
        let source = try WPETexLazyAnimatedTextureSource(payload: payload, device: device, label: "default time")
        #expect(source.texture(at: 0) != nil)
    }

    private func payload(format: WPETexFormat, width: Int, height: Int, rect: CGRect, duration: Double = 0.1) throws -> WPETexStreamingPayload {
        let count = try WPETexMipValidation.layout(format: format, width: width, height: height).byteCount
        let bytes = Data((0 ..< count).map { UInt8($0 % 251) })
        let mip = WPETexCompressedMipmap(index: 0, width: width, height: height, isCompressed: false,
                                         compressedBytes: bytes, decompressedByteCount: count)
        return WPETexStreamingPayload(
            info: WPETexInfo(containerVersion: 5, infoVersion: 1, width: width, height: height,
                             textureFormatCode: format.rawValue, format: format, mipmapCount: 1, flags: 0),
            compressedImages: [.init(width: width, height: height, payloads: [mip])],
            frames: [.init(imageID: 0, subRect: rect, duration: duration)], frameRate: 10, loop: true
        )
    }

    private func rawBytes(_ texture: MTLTexture, format: WPETexFormat) throws -> Data {
        let layout = try WPETexMipValidation.layout(format: format, width: texture.width, height: texture.height)
        var bytes = Data(count: layout.byteCount)
        bytes.withUnsafeMutableBytes { raw in
            texture.getBytes(raw.baseAddress!, bytesPerRow: layout.bytesPerRow,
                             from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        return bytes
    }
}
