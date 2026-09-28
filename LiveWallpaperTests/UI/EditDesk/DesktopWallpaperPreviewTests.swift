import Foundation
import ImageIO
@testable import LiveWallpaper
import Testing
import UniformTypeIdentifiers

@Suite("Desktop wallpaper local image previews")
@MainActor
struct DesktopWallpaperPreviewTests {
    @Test("A real local PNG is decoded without changing its small dimensions")
    func localImage() throws {
        let fixture = try ImageFixture(width: 96, height: 64)
        defer { fixture.remove() }
        let image = try #require(DesktopWallpaperPreview.load(from: fixture.url))
        #expect(image.width == 96)
        #expect(image.height == 64)
    }

    @Test("Missing URLs and corrupt local data leave the preview unavailable")
    func unavailableImage() throws {
        #expect(DesktopWallpaperPreview.load(from: nil) == nil)
        let fixture = try ImageFixture(width: 32, height: 24)
        defer { fixture.remove() }
        #expect(DesktopWallpaperPreview.load(from: fixture.url.appendingPathExtension("missing")) == nil)
        try Data("not an image".utf8).write(to: fixture.url)
        #expect(DesktopWallpaperPreview.load(from: fixture.url) == nil)
    }

    @Test("DefaultDesktop placeholders are refused even if they contain a valid image",
          arguments: ["DefaultDesktop.heic", "DefaultDesktopDark.png"])
    func rejectsPlaceholder(name: String) throws {
        let fixture = try ImageFixture(width: 32, height: 24, name: name)
        defer { fixture.remove() }
        #expect(CGImageSourceCreateWithURL(fixture.url as CFURL, nil) != nil)
        #expect(DesktopWallpaperPreview.load(from: fixture.url) == nil)
    }

    @Test("Non-file URLs are refused before attempting to decode their contents")
    func rejectsNonFileURLs() throws {
        let fixture = try ImageFixture(width: 32, height: 24)
        defer { fixture.remove() }
        let encoded = try Data(contentsOf: fixture.url).base64EncodedString()
        let urls = try [
            #require(URL(string: "https://example.invalid/wallpaper.png")),
            #require(URL(string: "data:image/png;base64,\(encoded)")),
        ]
        for url in urls {
            #expect(!url.isFileURL)
            #expect(DesktopWallpaperPreview.load(from: url) == nil)
        }
    }

    @Test("Large local images are downsampled to at most 1600 pixels",
          arguments: [(3200, 2000), (2000, 3200)])
    func downsamples(dimensions: (Int, Int)) throws {
        let fixture = try ImageFixture(width: dimensions.0, height: dimensions.1)
        defer { fixture.remove() }
        let image = try #require(DesktopWallpaperPreview.load(from: fixture.url))
        #expect(image.width == dimensions.0 / 2)
        #expect(image.height == dimensions.1 / 2)
        #expect(max(image.width, image.height) <= 1600)
    }

    private struct ImageFixture {
        let directory: URL
        let url: URL

        init(width: Int, height: Int, name: String = "wallpaper.png") throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("DesktopPreview-\(UUID())")
            url = directory.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            do {
                let context = try #require(CGContext(
                    data: nil, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ))
                context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                let image = try #require(context.makeImage())
                let destination = try #require(CGImageDestinationCreateWithURL(
                    url as CFURL, UTType.png.identifier as CFString, 1, nil
                ))
                CGImageDestinationAddImage(destination, image, nil)
                #expect(CGImageDestinationFinalize(destination))
            } catch {
                try? FileManager.default.removeItem(at: directory)
                throw error
            }
        }

        func remove() {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
