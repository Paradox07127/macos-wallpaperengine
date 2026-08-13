import Foundation
import LiveWallpaperProWPE
import Metal
import Testing
@testable import LiveWallpaper

@Suite("WPETexMetalTranscoder — GPU-backed BC → RGBA8")
struct WPETexMetalTranscoderTests {

    @Test("Transcoding a single DXT5 4×4 block produces a 4×4 RGBA8 image")
    func transcodeDXT5SingleBlockReturnsRGBA() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              device.supportsBCTextureCompression else {
            return
        }
        let block = Data([
            0xFF, 0x00, 0x49, 0x92, 0x24, 0x49, 0x92, 0x24,
            0xFF, 0xFF, 0x00, 0x00, 0x55, 0x55, 0x55, 0x55
        ])
        let decoded = try WPETexMetalTranscoder.transcode(
            block,
            format: .dxt5,
            width: 4,
            height: 4,
            mipmap: 0
        )
        #expect(decoded.width == 4)
        #expect(decoded.height == 4)
        #expect(decoded.pixels.count == 4 * 4 * 4)
    }

    @Test("Transcode rejects formats that aren't BC")
    func transcodeRejectsNonBC() {
        guard let device = MTLCreateSystemDefaultDevice(),
              device.supportsBCTextureCompression else {
            return
        }
        do {
            _ = try WPETexMetalTranscoder.transcode(
                Data(count: 64),
                format: .rgba8888,
                width: 4,
                height: 4,
                mipmap: 0
            )
            Issue.record("Expected unsupportedFormat for rgba8888")
        } catch WPETexDecodeError.unsupportedFormat {
        } catch {
            Issue.record("Expected unsupportedFormat, got \(error)")
        }
    }
}
