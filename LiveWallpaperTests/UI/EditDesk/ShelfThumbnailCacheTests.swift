import AppKit
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

@MainActor
@Suite("Shelf thumbnail cache")
struct ShelfThumbnailCacheTests {
    private let size = CGSize(width: 200, height: 112)

    @MainActor
    private final class Fixture {
        var calls: [String] = []
        var cover: CGImage?
        var video: CGImage?
        var web: CGImage?
        #if !LITE_BUILD
        var scene: CGImage?
        #endif

        func sources() -> ShelfThumbnailCache.Sources {
            var sources = ShelfThumbnailCache.Sources()
            sources.cover = { name in
                self.calls.append("cover:\(name)")
                return self.cover
            }
            sources.video = { _, _, _ in
                self.calls.append("video")
                return self.video
            }
            sources.web = { _, _ in
                self.calls.append("web")
                return self.web
            }
            #if !LITE_BUILD
            sources.scene = { _, _ in
                self.calls.append("scene")
                return self.scene
            }
            #endif
            return sources
        }
    }

    private func bookmark(cover: String? = nil) -> WallpaperBookmark {
        WallpaperBookmark(label: "", content: .video(bookmarkData: Data([1])), coverFileName: cover)
    }

    private func makeImage() throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: 1000, height: 560, bitsPerComponent: 8, bytesPerRow: 4000,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        return try #require(context.makeImage())
    }

    @Test("A saved cover wins and is immediately available from the synchronous cache")
    func bookmarkCoverHit() async throws {
        let fixture = Fixture()
        fixture.cover = try makeImage()
        fixture.video = try makeImage()
        let cache = ShelfThumbnailCache(sources: fixture.sources())
        let request = ShelfThumbnailCache.Request.bookmark(bookmark(cover: "cover.png"))
        #expect(cache.cached(request, pixelSize: size, scale: 2) == nil)
        let image = try #require(await cache.image(request, pixelSize: size, scale: 2))
        #expect(cache.cached(request, pixelSize: size, scale: 2) === image)
        #expect(await cache.image(request, pixelSize: size, scale: 2) === image)
        #expect(fixture.calls == ["cover:cover.png"])
    }

    @Test("Video supplies the poster when the saved cover cannot be read")
    func videoFallback() async throws {
        let fixture = Fixture()
        fixture.video = try makeImage()
        let cache = ShelfThumbnailCache(sources: fixture.sources())
        #expect(await cache.image(.bookmark(bookmark(cover: "missing.png")), pixelSize: size, scale: 1) != nil)
        #expect(fixture.calls == ["cover:missing.png", "video"])
    }

    @Test("Packaged videos pass their entry name and cache each entry separately")
    func packagedVideoEntries() async throws {
        let fixture = Fixture()
        fixture.video = try makeImage()
        let data = Data([1])
        var entryNames: [String?] = []
        var cacheKeys: [String] = []
        var sources = fixture.sources()
        sources.video = { actualData, entryName, cacheKey in
            #expect(actualData == data)
            entryNames.append(entryName)
            cacheKeys.append(cacheKey)
            return fixture.video
        }
        let cache = ShelfThumbnailCache(sources: sources)
        let before = WallpaperBookmark(
            label: "", content: .video(bookmarkData: data, packageEntryName: "first.mp4")
        )
        var after = before
        after.content = .video(bookmarkData: data, packageEntryName: "second.mp4")
        let firstRequest = ShelfThumbnailCache.Request.bookmark(before)
        let secondRequest = ShelfThumbnailCache.Request.bookmark(after)
        let first = try #require(await cache.image(firstRequest, pixelSize: size, scale: 1))
        #expect(cache.cached(secondRequest, pixelSize: size, scale: 1) == nil)
        let second = try #require(await cache.image(secondRequest, pixelSize: size, scale: 1))
        #expect(first !== second)
        #expect(cache.cached(firstRequest, pixelSize: size, scale: 1) === first)
        #expect(cache.cached(secondRequest, pixelSize: size, scale: 1) === second)
        #expect(await cache.image(firstRequest, pixelSize: size, scale: 1) === first)
        #expect(await cache.image(secondRequest, pixelSize: size, scale: 1) === second)
        #expect(entryNames == ["first.mp4", "second.mp4"])
        #expect(cacheKeys.count == 2)
        #expect(Set(cacheKeys).count == 2)
    }

    @Test("HTML uses a snapshot with its source and configuration")
    func webFallback() async throws {
        let fixture = Fixture()
        fixture.web = try makeImage()
        let source = HTMLSource.inline("<html></html>")
        let config = HTMLConfig()
        var sources = fixture.sources()
        sources.web = { actualSource, actualConfig in
            #expect(actualSource == source)
            #expect(actualConfig == config)
            fixture.calls.append("web")
            return fixture.web
        }
        let cache = ShelfThumbnailCache(sources: sources)
        let bookmark = WallpaperBookmark(label: "", content: .html(source: source, config: config))
        #expect(await cache.image(.bookmark(bookmark), pixelSize: size, scale: 1) != nil)
        #expect(fixture.calls == ["web"])
    }

    #if !LITE_BUILD
    @Test("Workshop preview is the last fallback for bookmarks and history")
    func sceneFallback() async throws {
        let fixture = Fixture()
        fixture.scene = try makeImage()
        let origin = WPEOrigin(
            workshopID: "123", title: "", originalType: .scene,
            sourceFolderBookmark: Data([2]), cacheRelativePath: nil, previewFileName: "preview.png"
        )
        var bookmark = bookmark(cover: "missing.png")
        bookmark.wpeOrigin = origin
        let cache = ShelfThumbnailCache(sources: fixture.sources())
        #expect(await cache.image(.bookmark(bookmark), pixelSize: size, scale: 1) != nil)
        #expect(fixture.calls == ["cover:missing.png", "video", "scene"])
        fixture.calls.removeAll()
        let entry = WPEHistoryEntry(origin: origin, importedAt: Date(timeIntervalSince1970: 0))
        #expect(await cache.image(.workshop(entry), pixelSize: size, scale: 1) != nil)
        #expect(fixture.calls == ["scene"])
    }
    #endif

    @Test("Pixel dimensions and backing scale have independent cache entries")
    func differentPixelSize() async throws {
        let fixture = Fixture()
        fixture.cover = try makeImage()
        let cache = ShelfThumbnailCache(sources: fixture.sources())
        let request = ShelfThumbnailCache.Request.bookmark(bookmark(cover: "cover.png"))
        let first = try #require(await cache.image(request, pixelSize: size, scale: 1))
        let larger = CGSize(width: 237, height: 133)
        #expect(cache.cached(request, pixelSize: larger, scale: 1) == nil)
        #expect(cache.cached(request, pixelSize: size, scale: 2) == nil)
        let second = try #require(await cache.image(request, pixelSize: larger, scale: 1))
        let retina = try #require(await cache.image(request, pixelSize: size, scale: 2))
        #expect(second.width == 237 && second.height == 133)
        #expect(retina.width == 200 && retina.height == 112)
        #expect(first !== second && first !== retina)
        #expect(cache.cached(request, pixelSize: size, scale: 1) === first)
        #expect(fixture.calls.count == 3)
    }

    @Test("Changing the cover revision under the same bookmark ID misses")
    func revisionChange() async throws {
        let fixture = Fixture()
        fixture.cover = try makeImage()
        let cache = ShelfThumbnailCache(sources: fixture.sources())
        let before = bookmark(cover: "first.png")
        var after = before
        after.coverFileName = "second.png"
        let first = try #require(await cache.image(.bookmark(before), pixelSize: size, scale: 1))
        #expect(cache.cached(.bookmark(after), pixelSize: size, scale: 1) == nil)
        let second = try #require(await cache.image(.bookmark(after), pixelSize: size, scale: 1))
        #expect(first !== second)
        #expect(fixture.calls == ["cover:first.png", "cover:second.png"])
    }

    @Test("Downscaling produces the requested pixel size")
    func downscaleProducesRequestedSize() async throws {
        let fixture = Fixture()
        fixture.cover = try makeImage()
        let cache = ShelfThumbnailCache(sources: fixture.sources())
        let image = try #require(await cache.image(.bookmark(bookmark(cover: "cover.png")), pixelSize: size, scale: 2))
        #expect(image.width == 200 && image.height == 112)
    }

    @Test("Concurrent readers and prewarm share one producer")
    func concurrentRequests() async throws {
        let fixture = Fixture()
        fixture.cover = try makeImage()
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let secondStarted = AsyncStream<Void>.makeStream()
        var sources = fixture.sources()
        sources.cover = { _ in
            fixture.calls.append("cover")
            started.continuation.yield(())
            for await _ in release.stream {
                break
            }
            return fixture.cover
        }
        let cache = ShelfThumbnailCache(sources: sources)
        let request = ShelfThumbnailCache.Request.bookmark(bookmark(cover: "cover.png"))
        cache.prewarm([request, request], pixelSize: size, scale: 1)
        var start = started.stream.makeAsyncIterator()
        _ = await start.next()
        let first = Task { await cache.image(request, pixelSize: size, scale: 1) }
        let second = Task {
            secondStarted.continuation.yield(())
            return await cache.image(request, pixelSize: size, scale: 1)
        }
        var secondStart = secondStarted.stream.makeAsyncIterator()
        _ = await secondStart.next()
        release.continuation.finish()
        let firstImage = try #require(await first.value)
        let secondImage = try #require(await second.value)
        #expect(firstImage === secondImage)
        #expect(fixture.calls == ["cover"])
        #expect(cache.cached(request, pixelSize: size, scale: 1) === firstImage)
    }
}
