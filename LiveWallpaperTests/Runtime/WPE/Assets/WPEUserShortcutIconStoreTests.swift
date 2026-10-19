#if !LITE_BUILD
import CoreGraphics
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import os
import Testing

@Suite("WPE usershortcut icon slots", .serialized)
@MainActor
struct WPEUserShortcutIconStoreTests {
    // MARK: - Store

    @Test("setIcon binds an rgba8Unorm texture, nil restores the authored one, identical bytes change nothing")
    func setIconSubstitutesAndDeduplicates() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let store = WPEUserShortcutIconStore(device: device)
        let changes = OSAllocatedUnfairLock(initialState: 0)
        store.onChange = { changes.withLock { $0 += 1 } }
        let authored = try Self.solidTexture(device, red: 0, green: 0, blue: 255)
        let declarations = [0: "rj1"]
        let icon = Self.icon(red: 255, green: 0, blue: 0)

        #expect(store.setIcon(icon, forKey: "rj1"))
        let bound = try #require(store.substituting(authored, slot: 0, declarations: declarations))
        #expect(bound !== authored)
        #expect(bound.pixelFormat == .rgba8Unorm)
        #expect(store.substituting(authored, slot: 1, declarations: declarations) === authored)

        #expect(!store.setIcon(icon, forKey: "rj1"), "same bytes must not rebuild the texture")
        #expect(store.substituting(authored, slot: 0, declarations: declarations) === bound)
        #expect(changes.withLock { $0 } == 1)

        #expect(store.setIcon(nil, forKey: "rj1"))
        #expect(store.substituting(authored, slot: 0, declarations: declarations) === authored)
        #expect(changes.withLock { $0 } == 2)
        #expect(!store.setIcon(nil, forKey: "rj1"))
    }

    @Test("setVideo publishes the bound file and wakes the renderer only when the file changes")
    func setVideoPublishesTheFile() throws {
        let store = try WPEUserShortcutIconStore(device: #require(MTLCreateSystemDefaultDevice()))
        let changes = OSAllocatedUnfairLock(initialState: 0)
        store.onChange = { changes.withLock { $0 += 1 } }
        let clip = URL(filePath: "/tmp/clip.mp4")

        #expect(store.setVideo(clip, forKey: "background"))
        #expect(!store.setVideo(clip, forKey: "background"), "rebinding the same file must not restart its player")
        #expect(store.videoURLs == ["background": clip])
        #expect(changes.withLock { $0 } == 1)
        #expect(store.setVideo(nil, forKey: "background"))
        #expect(store.videoURLs.isEmpty)
        #expect(changes.withLock { $0 } == 2)
    }

    // MARK: - Slot aspect

    @Test("A scene texture image is centre-cropped to the slot aspect with truncated size and halved offset")
    func cropRectTable() {
        let table: [(width: Int, height: Int, aspect: Float, rect: [Int])] = [
            (6, 3, 1, [1, 0, 3, 3]),
            (4, 4, 2, [0, 1, 4, 2]),
            (4, 2, 2, [0, 0, 4, 2]),
            (5, 2, 1, [1, 0, 2, 2]),
        ]
        for row in table {
            let rect = WPEUserShortcutIconImage.cropRect(width: row.width, height: row.height, aspect: row.aspect)
            #expect([rect.x, rect.y, rect.width, rect.height] == row.rect, "\(row)")
        }
        let strip = WPEUserShortcutIconImage(rgba: [1, 1, 1, 255, 2, 2, 2, 255, 3, 3, 3, 255], width: 3, height: 1)
        #expect(strip.fitted(toAspect: 1, pads: false) == WPEUserShortcutIconImage(rgba: [2, 2, 2, 255], width: 1, height: 1))
        #expect(strip.fitted(toAspect: 3, pads: false) == nil, "a matching aspect keeps the image")
    }

    @Test("A usershortcut icon is centred on a transparent canvas of the slot aspect")
    func padRectCentresTheIcon() {
        let wide = WPEUserShortcutIconImage.padRect(width: 4, height: 2, aspect: 1)
        #expect([wide.x, wide.y, wide.width, wide.height] == [0, 1, 4, 4] as [Int])
        let tall = WPEUserShortcutIconImage.padRect(width: 2, height: 4, aspect: 2)
        #expect([tall.x, tall.y, tall.width, tall.height] == [3, 0, 8, 4] as [Int])
        let icon = WPEUserShortcutIconImage(rgba: [9, 9, 9, 255], width: 1, height: 1)
        #expect(icon.fitted(toAspect: 3, pads: true)
            == WPEUserShortcutIconImage(rgba: [0, 0, 0, 0, 9, 9, 9, 255, 0, 0, 0, 0], width: 3, height: 1))
    }

    @Test("Fitted textures are cached per rounded aspect and dropped when the image changes")
    func fittedTexturesFollowTheImage() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let store = WPEUserShortcutIconStore(device: device)
        store.setIcon(WPEUserShortcutIconImage(rgba: [UInt8](repeating: 255, count: 12 * 12 * 4), width: 12, height: 12),
                      forKey: "photo")
        let whole = try #require(store.substituting(nil, slot: 0, declarations: [0: "photo"]))
        let slot = WPEUserImageSlot(key: "photo", aspect: 3, pads: false)
        let cropped = try #require(store.texture(for: slot))
        #expect([cropped.width, cropped.height] == [12, 4] as [Int])
        #expect(store.texture(for: slot) === cropped)
        #expect(store.texture(for: WPEUserImageSlot(key: "photo", aspect: 3.04, pads: false)) === cropped)
        #expect(store.texture(for: WPEUserImageSlot(key: "photo", aspect: nil, pads: false)) === whole)
        #expect(store.texture(for: WPEUserImageSlot(key: "photo", aspect: 1, pads: false)) === whole)
        let padded = try #require(store.texture(for: WPEUserImageSlot(key: "photo", aspect: 3, pads: true)))
        #expect([padded.width, padded.height] == [36, 12] as [Int])

        store.setIcon(WPEUserShortcutIconImage(rgba: [UInt8](repeating: 128, count: 12 * 12 * 4), width: 12, height: 12),
                      forKey: "photo")
        let replaced = try #require(store.texture(for: slot))
        #expect(replaced !== cropped, "a new image must not reuse the previous image's crop")
        #expect([replaced.width, replaced.height] == [12, 4] as [Int])
        store.setIcon(nil, forKey: "photo")
        #expect(store.texture(for: slot) == nil)
    }

    #if DEBUG
    @Test("A transparent icon samples on the GPU as straight RGBA")
    func transparentIconPreservesStraightAlpha() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        // Premultiplied source pixels: straight RGB is (192,128,64) at alpha 128.
        let pixel: [UInt8] = [96, 64, 32, 128]
        let source = try Self.premultipliedImage(rgba: (0 ..< 8 * 8).flatMap { _ in pixel }, edge: 8)
        let image = try #require(UserShortcutIconRenderer.rasterize(source))
        let store = WPEUserShortcutIconStore(device: device)
        store.setIcon(image, forKey: "rj1")
        let texture = try #require(store.substituting(nil, slot: 0, declarations: [0: "rj1"]))

        let center = image.width / 2
        let probe = try WPEOraclePixelProbe.sample(
            texture: texture, coordinates: [[center, center]], commandQueue: queue
        )
        let samples = try #require(probe["samples"] as? [[String: Any]])
        let sample = try #require(samples.first?["storageRGBA"] as? [Double])
        let expected = [192.0, 128, 64, 128].map { $0 / 255 }
        #expect(zip(sample, expected).allSatisfy { abs($0 - $1) <= 2.0 / 255 },
                "icon must not publish premultiplied RGB as a straight image: \(sample)")
    }
    #endif

    // MARK: - Fixtures

    static func icon(red: UInt8, green: UInt8, blue: UInt8) -> WPEUserShortcutIconImage {
        WPEUserShortcutIconImage(rgba: (0 ..< 4 * 4).flatMap { _ in [red, green, blue, 255] }, width: 4, height: 4)
    }

    private static func solidTexture(_ device: MTLDevice, red: UInt8, green: UInt8, blue: UInt8) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm_srgb, width: 4, height: 4, mipmapped: false
        )
        descriptor.usage = .shaderRead
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        let bytes: [UInt8] = (0 ..< 4 * 4).flatMap { _ in [red, green, blue, 255] }
        texture.replace(region: MTLRegionMake2D(0, 0, 4, 4), mipmapLevel: 0, withBytes: bytes, bytesPerRow: 4 * 4)
        return texture
    }

    private static func premultipliedImage(rgba: [UInt8], edge: Int) throws -> CGImage {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let provider = try #require(CGDataProvider(data: Data(rgba) as CFData))
        return try #require(CGImage(
            width: edge, height: edge, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: edge * 4, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
    }

}
#endif
