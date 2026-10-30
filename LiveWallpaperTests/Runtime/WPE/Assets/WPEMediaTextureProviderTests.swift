import CoreGraphics
import Foundation
import ImageIO
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import Testing
import UniformTypeIdentifiers

/// 本文件不许触到 `NowPlayingMonitor.shared`(用户真实播放器):
/// 只走注入的 `FakeNowPlayingSource`(在 WPESceneMediaEventDispatchTests)。
@Suite("WPE $mediaThumbnail system texture", .serialized)
@MainActor
struct WPEMediaTextureProviderTests {
    @Test("Artwork is downsampled to the system-texture cap")
    func artworkIsDownsampledOnUpload() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let store = WPEMediaTextureStore(device: device)

        let pair = try store.paritySnapshot(revision: 1, currentArtwork: MonitorNowPlayingArtwork(Self.artwork(red: 0.9, size: 1024)),
                                            previousArtwork: nil, currentSystemName: "cover", previousSystemName: nil)
        let texture = try #require(pair.snapshot.current)
        #expect(texture.width <= 256)
        #expect(texture.height <= 256)
    }

    @Test("Cover bytes stay sRGB-encoded in a raw UNORM texture, like authored and video textures")
    func coverTextureKeepsEncodedBytesUndecoded() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let store = WPEMediaTextureStore(device: device)

        let pair = try store.paritySnapshot(revision: 1,
                                            currentArtwork: MonitorNowPlayingArtwork(Self.artwork(red: 128.0 / 255, green: 128, blue: 128)),
                                            previousArtwork: nil, currentSystemName: "cover", previousSystemName: nil)
        let texture = try #require(pair.snapshot.current)
        var pixel = [UInt8](repeating: 0, count: 4)
        texture.getBytes(
            &pixel,
            bytesPerRow: texture.width * 4,
            from: MTLRegionMake2D(texture.width / 2, texture.height / 2, 1, 1),
            mipmapLevel: 0
        )
        #expect(
            texture.pixelFormat == .rgba8Unorm,
            "an _srgb cover (bytes \(pixel)) is decoded on sample and again at present"
        )
        for channel in pixel.prefix(3) {
            #expect(abs(Int(channel) - 128) <= 1, "cover byte \(channel) is not the sRGB-encoded 128")
        }
        #expect(pixel[3] == 255)
    }

    // MARK: - Name mapping

    @Test("Only the two corpus names map to a system texture")
    func onlyTheTwoCorpusNamesMap() {
        #expect(WPEMediaSystemTexture(bindingName: "$mediaThumbnail") == .thumbnail)
        #expect(WPEMediaSystemTexture(bindingName: "$mediaPreviousThumbnail") == .previousThumbnail)
        // WPE resolves these case-insensitively, as it does every other authored name.
        #expect(WPEMediaSystemTexture(bindingName: "$MEDIATHUMBNAIL") == .thumbnail)
        #expect(WPEMediaSystemTexture(bindingName: "$mediaStatus") == nil)
        #expect(WPEMediaSystemTexture(bindingName: "$instanceSource") == nil)
    }

    /// 按 `red` 取值不同,使两张封面字节级不相同。
    private static func artwork(red: Double, green: UInt8 = 40, blue: UInt8 = 40, size: Int = 64) throws -> Data {
        var bytes = [UInt8](repeating: 255, count: size * size * 4)
        for index in stride(from: 0, to: bytes.count, by: 4) {
            bytes[index] = UInt8((red * 255).rounded())
            bytes[index + 1] = green
            bytes[index + 2] = blue
            bytes[index + 3] = 255
        }
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        let image = try #require(CGImage(
            width: size,
            height: size,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: size * 4,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            output, UTType.png.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }
}

/// `usertextures` 的数组下标就是被覆盖的纹理槽位:把 `null` 空洞
/// compactMap 掉会让每条声明整体下移。
@Suite("WPE usertextures slot alignment")
struct WPEUserTextureSlotAlignmentTests {
    @Test("Document parser keeps instance usertextures aligned across null holes")
    func documentParserKeepsInstanceSlotAlignment() throws {
        let scene: [String: Any] = [
            "camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 1920, "height": 1080, "auto": true]],
            "objects": [[
                "id": 201,
                "name": "Album",
                "image": "models/album.json",
                "instance": [
                    "id": 2258,
                    "textures": ["cover", "cover", "cover"],
                    "usertextures": [
                        NSNull(),
                        ["name": "$mediaPreviousThumbnail", "type": "system"],
                        ["name": "$mediaThumbnail", "type": "system"]
                    ]
                ]
            ]]
        ]
        let data = try JSONSerialization.data(withJSONObject: scene)
        let document = try WPESceneDocumentParser.parse(data: data)
        let instance = try #require(document.imageObjects.first?.materialInstance)

        #expect(instance.userTextures.count == 2)
        #expect(instance.userTextures[0].name == "$mediaPreviousThumbnail")
        #expect(instance.userTextures[0].slot == 1)
        #expect(instance.userTextures[1].name == "$mediaThumbnail")
        #expect(instance.userTextures[1].slot == 2)
    }

}
