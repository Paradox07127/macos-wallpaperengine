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
    #if DEBUG
    @Test("Oracle scripts and texture subscriptions share one private source; a fresh empty store has no old cover")
    func oracleSourceFeedsScriptsAndTextures() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let artwork = try Self.artwork(red: 0.9)
        let state = MonitorNowPlayingState(phase: .paused, title: "Controlled", artwork: artwork)
        try WPEOracleFrozenNowPlayingSource.validate(state)
        let source = WPEOracleFrozenNowPlayingSource(state: state)
        let dispatcher = WPESceneMediaEventDispatcher(source: source)
        let store = WPEMediaTextureStore(device: device)
        let subscription = WPEMediaTextureSubscription(store: store, source: source)
        dispatcher.start()
        subscription.start()
        defer { dispatcher.stop(); subscription.stop() }
        #expect(source.subscriberCount == 2)
        #expect(source.replayCount == 2)
        let receivedTitle = dispatcher.mailbox.drain().contains(.propertiesChanged(.init(title: "Controlled")))
        #expect(receivedTitle)
        #expect(store.uploadCount == 1)
        #expect(store.texture(for: .thumbnail) != nil)
        let receipt = source.receipt(generation: 1, scripts: true, textures: true)
        #expect(receipt.state.artwork == artwork && receipt.replayCount == 2)

        let empty = WPEOracleFrozenNowPlayingSource(state: .init(phase: .noPlayer, title: ""))
        let freshStore = WPEMediaTextureStore(device: device)
        let freshSubscription = WPEMediaTextureSubscription(store: freshStore, source: empty)
        freshSubscription.start()
        defer { freshSubscription.stop() }
        #expect(freshStore.texture(for: .thumbnail) == nil)
        #expect(freshStore.texture(for: .previousThumbnail) == nil)
        #expect(freshStore.uploadCount == 0)
        #expect(source.state.title == "Controlled")
    }
    #endif

    @Test("Subscribing replays current state, so a scene loaded mid-song has its cover")
    func subscribingReplaysCurrentArtwork() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let source = FakeNowPlayingSource()
        source.push(MonitorNowPlayingState(
            phase: .playing,
            title: "Track",
            artwork: try Self.artwork(red: 0.9)
        ))

        let store = WPEMediaTextureStore(device: device, slotsByPassID: ["1.0": [2: .thumbnail]])
        WPEMediaTextureSubscription(store: store, source: source).start()

        #expect(store.uploadCount == 1)
        #expect(store.texture(for: .thumbnail) != nil)
    }

    // MARK: - Slot substitution

    @Test("A slot declaring $mediaThumbnail binds the artwork texture once artwork exists")
    func thumbnailSlotBindsArtworkTexture() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let store = WPEMediaTextureStore(device: device)
        let placeholder = try Self.placeholderTexture(device)
        let declarations: [Int: WPEMediaSystemTexture] = [2: .thumbnail]

        store.ingest(artwork: try Self.artwork(red: 0.9))

        let bound = try #require(store.substituting(placeholder, slot: 2, declarations: declarations))
        #expect(bound !== placeholder, "the artwork must replace the authored placeholder")
        #expect(bound === store.texture(for: .thumbnail))
    }

    @Test("With no artwork the declared slot keeps the authored placeholder")
    func noArtworkKeepsAuthoredPlaceholder() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let store = WPEMediaTextureStore(device: device)
        let placeholder = try Self.placeholderTexture(device)
        let declarations: [Int: WPEMediaSystemTexture] = [2: .thumbnail]

        store.ingest(artwork: nil)

        // 断言 identity 而非仅 non-nil:这里换成空白/黑纹理会渲成一个洞,
        // 而不是作者的封面图。
        #expect(store.substituting(placeholder, slot: 2, declarations: declarations) === placeholder)
    }

    @Test("A no-artwork gap does not erase the previous cover")
    func nilArtworkKeepsPreviousCoverAcrossTheGap() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let store = WPEMediaTextureStore(device: device)
        let placeholder = try Self.placeholderTexture(device)
        let declarations: [Int: WPEMediaSystemTexture] = [1: .previousThumbnail, 2: .thumbnail]

        store.ingest(artwork: try Self.artwork(red: 0.9))
        let coverA = try #require(store.texture(for: .thumbnail))

        store.ingest(artwork: nil)
        #expect(store.substituting(placeholder, slot: 2, declarations: declarations) === placeholder,
                "no track playing → the authored placeholder")
        #expect(store.substituting(placeholder, slot: 1, declarations: declarations) === coverA,
                "the gap must not erase the cover that came before it")

        store.ingest(artwork: try Self.artwork(red: 0.2))
        #expect(store.substituting(placeholder, slot: 1, declarations: declarations) === coverA,
                "at B the previous slot still serves A, not the placeholder")
    }

    @Test("Ingest reports whether it changed anything")
    func ingestReportsChanges() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let store = WPEMediaTextureStore(device: device)

        #expect(!store.ingest(artwork: nil), "empty store, nil push: nothing changed")
        let a = try Self.artwork(red: 0.9)
        #expect(store.ingest(artwork: a))
        #expect(!store.ingest(artwork: a), "same bytes, same key: no change, no wake")
        #expect(store.ingest(artwork: nil), "clearing a live cover is a visible change")
    }

    @Test("A slot nobody declared is untouched even while artwork exists")
    func undeclaredSlotIsUntouched() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let store = WPEMediaTextureStore(device: device)
        let placeholder = try Self.placeholderTexture(device)

        store.ingest(artwork: try Self.artwork(red: 0.9))

        #expect(store.substituting(placeholder, slot: 0, declarations: [2: .thumbnail]) === placeholder)
    }

    @Test("$mediaPreviousThumbnail holds the placeholder until artwork changes, then the prior art")
    func previousThumbnailServesPriorArtworkOnlyAfterAChange() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let store = WPEMediaTextureStore(device: device)
        let placeholder = try Self.placeholderTexture(device)
        let declarations: [Int: WPEMediaSystemTexture] = [1: .previousThumbnail, 2: .thumbnail]

        let first = try Self.artwork(red: 0.9)
        store.ingest(artwork: first)

        #expect(store.substituting(placeholder, slot: 1, declarations: declarations) === placeholder)
        let current = try #require(store.substituting(placeholder, slot: 2, declarations: declarations))

        store.ingest(artwork: try Self.artwork(red: 0.1))

        let previous = try #require(store.substituting(placeholder, slot: 1, declarations: declarations))
        #expect(previous === current, "the previous slot must serve the artwork that was just replaced")
        #expect(store.substituting(placeholder, slot: 2, declarations: declarations) !== current)
    }

    @Test("A substituted cover samples with identity, not the placeholder's sprite transform")
    func substitutedCoverDropsPlaceholderSpriteTransform() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let placeholder = try Self.placeholderTexture(device)
        let cover = try Self.placeholderTexture(device)
        let sprite = WPETexSpriteSamplingDescriptor(rotation: SIMD4(0, 1, -1, 0), translation: SIMD2(0.5, 0.25))

        #expect(WPEMediaTextureStore.samplingDescriptor(
            authored: sprite, authoredTexture: placeholder, boundTexture: cover
        ) == .identity)
        #expect(WPEMediaTextureStore.samplingDescriptor(
            authored: sprite, authoredTexture: placeholder, boundTexture: placeholder
        ) == sprite, "no cover: the placeholder keeps its own sprite transform")
    }

    // MARK: - Upload cache

    @Test("Re-ingesting identical artwork bytes uploads exactly once")
    func identicalArtworkUploadsOnce() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let store = WPEMediaTextureStore(device: device)
        let artwork = try Self.artwork(red: 0.9)

        store.ingest(artwork: artwork)
        #expect(store.uploadCount == 1)

        store.ingest(artwork: artwork)
        #expect(store.uploadCount == 1, "a re-delivered unchanged cover must not decode again")

        store.ingest(artwork: try Self.artwork(red: 0.1))
        #expect(store.uploadCount == 2, "different bytes must upload — a frozen cache is not a cache")
    }

    @Test("Two draws with unchanged artwork upload nothing at all")
    func drawingTwiceUploadsNothing() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let store = WPEMediaTextureStore(device: device)
        let placeholder = try Self.placeholderTexture(device)
        let declarations: [Int: WPEMediaSystemTexture] = [2: .thumbnail]
        store.ingest(artwork: try Self.artwork(red: 0.9))

        let first = store.substituting(placeholder, slot: 2, declarations: declarations)
        let second = store.substituting(placeholder, slot: 2, declarations: declarations)

        #expect(store.uploadCount == 1, "a frame must never decode an image")
        #expect(first === second)
    }

    @Test("Artwork is downsampled to the system-texture cap")
    func artworkIsDownsampledOnUpload() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let store = WPEMediaTextureStore(device: device)

        store.ingest(artwork: try Self.artwork(red: 0.9, size: 1024))

        let texture = try #require(store.texture(for: .thumbnail))
        #expect(texture.width <= WPEMediaTextureStore.maximumEdge)
        #expect(texture.height <= WPEMediaTextureStore.maximumEdge)
    }

    @Test("Cover bytes stay sRGB-encoded in a raw UNORM texture, like authored and video textures")
    func coverTextureKeepsEncodedBytesUndecoded() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let store = WPEMediaTextureStore(device: device)

        try store.ingest(artwork: Self.artwork(red: 128.0 / 255, green: 128, blue: 128))

        let texture = try #require(store.texture(for: .thumbnail))
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

    @Test("Undecodable artwork bytes leave the placeholder in place")
    func undecodableArtworkKeepsPlaceholder() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let store = WPEMediaTextureStore(device: device)
        let placeholder = try Self.placeholderTexture(device)

        store.ingest(artwork: Data("not an image".utf8))

        #expect(store.substituting(placeholder, slot: 2, declarations: [2: .thumbnail]) === placeholder)
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

    private static func placeholderTexture(_ device: MTLDevice) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm_srgb,
            width: 8,
            height: 8,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        return try #require(device.makeTexture(descriptor: descriptor))
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
