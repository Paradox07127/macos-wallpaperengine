import Foundation
import LiveWallpaperProWPE
import Metal
import Testing
@testable import LiveWallpaper

@Suite("TEX mip validation")
struct WPETexMipValidationTests {
    @Test("Geometry rejects duplicate, enlarged, skipped and excess tail levels",
          arguments: [[(8, 8), (8, 8)], [(8, 8), (2, 2)], [(8, 8), (4, 5)], [(1, 1), (1, 1)]])
    func malformedGeometry(sizes: [(Int, Int)]) {
        #expect(throws: WPETexMipValidation.Invalid.self) {
            try WPETexMipValidation.geometry(sizes.enumerated().map { ($0.offset, $0.element.0, $0.element.1) })
        }
    }

    @Test("NPOT, one-dimensional and partial chains use floor-halved geometry")
    func validGeometry() throws {
        try WPETexMipValidation.geometry([(0, 7, 3), (1, 3, 1), (2, 1, 1)])
        try WPETexMipValidation.geometry([(0, 1, 8), (1, 1, 4)])
        #expect(throws: WPETexMipValidation.Invalid.self) {
            try WPETexMipValidation.geometry([(1, 8, 8)])
        }
    }

    @Test("Byte layout handles BC tails and rejects integer overflow")
    func layout() throws {
        #expect(try WPETexMipValidation.layout(format: .dxt1, width: 1, height: 1).byteCount == 8)
        #expect(try WPETexMipValidation.layout(format: .bc7, width: 5, height: 3).byteCount == 32)
        for format in [WPETexFormat.rgba8888, .dxt5] {
            #expect(throws: WPETexMipValidation.Invalid.self) {
                try WPETexMipValidation.layout(format: format, width: Int.max, height: Int.max)
            }
        }
    }

    @Test("Sparse decode metadata is allowed but nonempty truncated BC payload is rejected")
    func sparseAndTruncated() throws {
        try WPETexMipValidation.decoded([
            .init(index: 0, width: 4, height: 4, bytes: Data(repeating: 0, count: 16)),
            .init(index: 1, width: 2, height: 2, bytes: Data())
        ], format: .bc7)
        #expect(throws: WPETexMipValidation.Invalid.self) {
            try WPETexMipValidation.decoded([
                .init(index: 0, width: 4, height: 4, bytes: Data(repeating: 0, count: 15))
            ], format: .bc7)
        }
    }

    @Test("Raw malformed tail is rejected even when the inflate scope selects only level zero")
    func malformedFixture() {
        for scope in [WPETexMipInflateScope.fullChain, .init(maxSourceEdge: nil, uploadsChain: false)] {
            switch WPETexDecoder().extractTexturePayload(data: fixture(sizes: [(8, 8), (8, 8)]), scope: scope) {
            case .success: Issue.record("Malformed mip chain escaped parser")
            case .failure: break
            }
        }
    }

    @Test("Loader validates full geometry before Metal allocation even with mip upload disabled")
    func loaderRejectsMalformed() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let valid = try WPETexDecoder().extractTexturePayload(data: fixture(sizes: [(8, 8)])).get()
        let payload = WPETexTexturePayload(info: valid.info, mipmaps: [
            valid.mipmaps[0], .init(index: 1, width: 8, height: 8, bytes: Data())
        ], hasAnimationFrames: false)
        #expect(throws: WPETexMipValidation.Invalid.self) {
            try WPEMetalTextureLoader.makeTextureSynchronously(
                from: payload, label: "malformed", device: device,
                capabilities: WPEMetalTextureCapabilities(device: device)
            )
        }
    }

    @Test("Streaming payload bounds reject negative, short and oversized declarations before inflate")
    func streamingBounds() throws {
        for count in [-1, 63, WPETexCompressedMipmap.maxDecompressedByteCount + 1] {
            let mip = WPETexCompressedMipmap(index: 0, width: 4, height: 4, isCompressed: false,
                                             compressedBytes: Data(repeating: 0, count: 64), decompressedByteCount: count)
            #expect(throws: WPETexMipValidation.Invalid.self) {
                try WPETexMipValidation.decodedBytes(mip, format: .rgba8888)
            }
        }
    }

    private func fixture(sizes: [(Int, Int)]) -> Data {
        var data = Data()
        func magic(_ value: String) { data.append(contentsOf: value.utf8); data.append(0) }
        func integer(_ value: Int) {
            var little = Int32(value).littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        magic("TEXV0005"); magic("TEXI0001")
        integer(0); integer(0)
        integer(sizes[0].0); integer(sizes[0].1)
        integer(sizes[0].0); integer(sizes[0].1); integer(0)
        magic("TEXB0003"); integer(1); integer(-1); integer(sizes.count)
        for (width, height) in sizes {
            let count = width * height * 4
            integer(width); integer(height); integer(0); integer(count); integer(count)
            data.append(Data(repeating: 0, count: count))
        }
        return data
    }
}
