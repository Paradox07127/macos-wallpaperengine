import AppKit
@testable import LiveWallpaper
import LiveWallpaperCore
import SwiftUI
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
        /// While true a cover decode is logged but does not return, so a test can look at the tiles before it lands.
        var holding = false

        func sources() -> ShelfThumbnailCache.Sources {
            var sources = ShelfThumbnailCache.Sources()
            sources.cover = { name in
                self.calls.append("cover:\(name)")
                while self.holding {
                    try? await Task.sleep(for: .milliseconds(5))
                }
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

    private func makeImage(filled color: CGColor? = nil) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: 1000, height: 560, bitsPerComponent: 8, bytesPerRow: 4000,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        if let color {
            context.setFillColor(color)
            context.fill(CGRect(x: 0, y: 0, width: 1000, height: 560))
        }
        return try #require(context.makeImage())
    }

    private func gridItem(cover: String) -> LiveWallpaper.LibraryItem {
        let bookmark = bookmark(cover: cover)
        return LiveWallpaper.LibraryItem(
            id: "bookmark:\(bookmark.id)", title: cover, kind: .video, source: .bookmark(bookmark),
            isSteam: false, createdAt: bookmark.createdAt, lastUsedAt: nil, onDisplays: [],
            thumbnail: .bookmark(bookmark), metadata: nil, isVariant: false, parentID: nil, isSupported: true
        )
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

    @Test("A grid tile asks for its own size in pixels and shows the shelf's copy until that decodes")
    func gridTileUpgradesFromTheShelfCopy() async throws {
        let fixture = Fixture()
        fixture.video = try makeImage()
        let cache = ShelfThumbnailCache(sources: fixture.sources())
        let request = ShelfThumbnailCache.Request.bookmark(bookmark())
        let tile = StageGeometry.gridCellSize(windowWidth: 1280, size: .small).width
        let own = LibraryGridTile.Thumbnail(request, tileWidth: tile, scale: 2)
        #expect(own.pixelSize == CGSize(width: 512, height: 288), Comment(rawValue: "a \(tile)pt tile asked for \(own.pixelSize)"))
        #expect(HomePage.gridImage(own, in: cache) == nil)
        // The shelf keeps decoding at its own size, and that copy stands in while the tile's decodes.
        let shelf = try #require(await cache.image(request, pixelSize: CGSize(width: 400, height: 224), scale: 2))
        #expect(HomePage.gridImage(own, in: cache) === shelf, "the tile is blank while its own size decodes")
        let decoded = try #require(await cache.image(request, pixelSize: own.pixelSize, scale: 2))
        #expect(decoded.width == 512 && decoded.height == 288)
        #expect(HomePage.gridImage(own, in: cache) === decoded)
        // A live resize inside one step keeps asking for the same pixels instead of a decode per frame.
        for window in [CGFloat(1240), 1320] {
            let width = StageGeometry.gridCellSize(windowWidth: window, size: .small).width
            let resized = LibraryGridTile.Thumbnail(request, tileWidth: width, scale: 2)
            #expect(resized == own, Comment(rawValue: "a \(width)pt tile asked for \(resized.pixelSize)"))
        }
    }

    @Test(
        "Grid tiles keep what they decoded: a cache that holds two of eight stops decoding and every tile still shows its own",
        .timeLimit(.minutes(1))
    )
    func gridTilesDecodeOnceUnderCachePressure() async throws {
        let fixture = Fixture()
        fixture.cover = try makeImage(filled: CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        let count = 8
        // Room for two 64×36 tile images, so every decode evicts another tile's.
        let cache = ShelfThumbnailCache(sources: fixture.sources(), costLimit: 2 * 64 * 4 * 36)
        let items = (0 ..< count).map { gridItem(cover: "cover-\($0).png") }
        let size = CGSize(width: 1280, height: 820)
        let grid = ScrollView {
            LibraryGalleryGrid(size: .small, aspect: .wide, initialWidth: size.width) {
                ForEach(items) { item in
                    LibraryGridTile(
                        item: item, thumbnail: item.thumbnail.map { LibraryGridTile.Thumbnail($0, tileWidth: 32, scale: 2) },
                        thumbnails: cache, badges: LibraryCardBadges()
                    )
                }
            }
        }
        let host = NSHostingView(rootView: grid.frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        window.orderBack(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        host.layoutSubtreeIfNeeded()
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        host.layoutSubtreeIfNeeded()

        let decodes = Dictionary(grouping: fixture.calls) { $0 }.mapValues(\.count)
        #expect(decodes.count == count, Comment(rawValue: "\(decodes.count) of \(count) tiles decoded"))
        #expect(
            decodes.values.allSatisfy { $0 == 1 },
            Comment(rawValue: "\(fixture.calls.count) decodes for \(count) tiles: \(decodes.sorted { $0.key < $1.key }.map(\.value))")
        )
        let tilePixels = CGSize(width: 64, height: 36)
        let cached = items.compactMap(\.thumbnail).filter { cache.cached($0, pixelSize: tilePixels, scale: 2) != nil }.count
        #expect(cached < count, "the cache kept every tile, so nothing was evicted and nothing was tested")

        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / size.width
        let blank = (0 ..< count).filter { index in
            let frame = DesignTokens.LibraryGrid.tileFrame(
                index: index, size: .small, aspect: .wide, fitting: size.width, tileAspectRatio: StageGeometry.cardAspectRatio
            )
            let pixel = bitmap.colorAt(x: Int(frame.midX * scale), y: Int((frame.minY + frame.height * 0.3) * scale))
            let color = pixel?.usingColorSpace(.sRGB)
            return !(color.map { $0.redComponent > 0.8 && $0.greenComponent < 0.3 && $0.blueComponent < 0.3 } ?? false)
        }
        #expect(blank.isEmpty, Comment(rawValue: "tiles \(blank) show the placeholder while the cache holds \(cached) of \(count)"))
    }

    @Test(
        "A grid tile lets its image go when it scrolls away and asks for it once more when it comes back",
        .timeLimit(.minutes(1))
    )
    func gridTilesReleaseTheirImagesOffScreen() async throws {
        let fixture = Fixture()
        fixture.cover = try makeImage(filled: CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        defer { fixture.holding = false }
        // Room for six and a half 64×36 tile images: the first three rows' all stay cached until the
        // six decoded at the bottom push every one of them out.
        let tilePixels = CGSize(width: 64, height: 36)
        let cache = ShelfThumbnailCache(sources: fixture.sources(), costLimit: 13 * 64 * 4 * 36 / 2)
        let items = (0 ..< 40).map { gridItem(cover: "cover-\($0).png") }
        let size = CGSize(width: 600, height: 400)
        let grid = ScrollView {
            LibraryGalleryGrid(size: .small, aspect: .wide, initialWidth: size.width) {
                ForEach(items) { item in
                    LibraryGridTile(
                        item: item, thumbnail: item.thumbnail.map { LibraryGridTile.Thumbnail($0, tileWidth: 32, scale: 2) },
                        thumbnails: cache, badges: LibraryCardBadges()
                    )
                }
            }
        }
        let host = NSHostingView(rootView: grid.frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        window.orderBack(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        host.layoutSubtreeIfNeeded()

        func findScroll(_ view: NSView) -> NSScrollView? {
            (view as? NSScrollView) ?? view.subviews.lazy.compactMap(findScroll).first
        }
        let scrollView = try #require(findScroll(host))
        func scrollGrid(to y: CGFloat) {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        /// Waits for the log to grow past `baseline`, then for a quarter second without growth.
        func settle(past baseline: Int) async {
            var seen = -1
            let deadline = Date().addingTimeInterval(5)
            while fixture.calls.count != seen || fixture.calls.count == baseline, Date() < deadline {
                seen = fixture.calls.count
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        /// Decodes finish off the main actor, after the request is logged.
        func eventually(_ condition: () throws -> Bool) async throws -> Bool {
            let deadline = Date().addingTimeInterval(5)
            while try !condition() {
                guard Date() < deadline else { return false }
                try await Task.sleep(for: .milliseconds(50))
            }
            return true
        }
        func cached(_ indices: [Int]) -> [Int] {
            indices.filter { index in
                items[index].thumbnail.map { cache.cached($0, pixelSize: tilePixels, scale: 2) != nil } ?? false
            }
        }
        /// Sampled high in the tile, clear of the title gradient.
        func samplePoint(_ index: Int) -> CGPoint {
            let frame = DesignTokens.LibraryGrid.tileFrame(
                index: index, size: .small, aspect: .wide, fitting: scrollView.contentSize.width, tileAspectRatio: StageGeometry.cardAspectRatio
            )
            return CGPoint(x: frame.midX, y: frame.minY + frame.height * 0.3)
        }
        /// The tiles among `indices` drawing the red cover.
        func showingTheirImage(_ indices: [Int]) throws -> [Int] {
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let scale = CGFloat(bitmap.pixelsWide) / size.width
            return indices.filter { index in
                let point = samplePoint(index)
                let color = bitmap.colorAt(x: Int(point.x * scale), y: Int(point.y * scale))?.usingColorSpace(.sRGB)
                return color.map { $0.redComponent > 0.8 && $0.greenComponent < 0.3 && $0.blueComponent < 0.3 } ?? false
            }
        }

        await settle(past: 0)
        let top = Set(fixture.calls)
        try #require(!top.isEmpty && fixture.calls.count == top.count, Comment(rawValue: "first load: \(fixture.calls.sorted())"))
        let topTiles = items.indices.filter { top.contains("cover:cover-\($0).png") }
        try #require(topTiles.count < items.count / 2, "most of the grid appeared at once, so little can scroll away")
        let visible = topTiles.filter { samplePoint($0).y < size.height }
        try #require(!visible.isEmpty)
        try #require(await eventually { try showingTheirImage(visible) == visible }, "the first rows never showed their images")
        // A tile that redraws from the cache once it is off screen keeps that copy alive with it.
        try #require(await eventually { cached(topTiles) == topTiles }, "the first rows' images are not all cached as they leave")

        let maxY = (scrollView.documentView?.frame.height ?? 0) - scrollView.contentSize.height
        try #require(maxY > 4 * size.height, Comment(rawValue: "the grid only scrolls \(maxY)pt"))
        scrollGrid(to: maxY)
        await settle(past: top.count)
        let away = fixture.calls.dropFirst(top.count)
        #expect(
            Set(away).isDisjoint(with: top),
            Comment(rawValue: "tiles off screen decoded again: \(Set(away).intersection(top).sorted())")
        )
        let evicted = try await eventually { cached(topTiles).isEmpty }
        try #require(
            evicted,
            Comment(rawValue: "tiles \(cached(topTiles)) are still cached after \(away.count) newer decodes, so coming back to them tests nothing")
        )

        // Decodes asked for on the way back are held, so the tiles show only what they kept while away.
        let returning = fixture.calls.count
        fixture.holding = true
        scrollGrid(to: 0)
        await settle(past: returning)
        let back = fixture.calls.dropFirst(returning)
        #expect(
            back.sorted() == top.sorted(),
            Comment(rawValue: "\(top.count) tiles came back and asked for \(back.count) decodes: \(back.sorted())")
        )
        let kept = try showingTheirImage(visible)
        #expect(kept.isEmpty, Comment(rawValue: "tiles \(kept) kept their images while they were off screen"))

        fixture.holding = false
        #expect(try await eventually { try showingTheirImage(visible) == visible }, "the tiles came back without their images")
        try await Task.sleep(for: .milliseconds(500))
        #expect(
            fixture.calls.count == 2 * top.count + away.count,
            Comment(rawValue: "\(fixture.calls.count) decodes for \(top.count) tiles seen twice and \(away.count) seen once")
        )
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

    @Test("An Apple Aerials file keeps its thumbnail when a rescan bookmarks it again")
    func aerialRescanHitsTheCache() async throws {
        let fixture = Fixture()
        fixture.video = try makeImage()
        var bookmarks: [Data] = []
        var sources = fixture.sources()
        sources.video = { data, entryName, _ in
            #expect(entryName == nil)
            bookmarks.append(data)
            return fixture.video
        }
        let cache = ShelfThumbnailCache(sources: sources)
        let url = URL(fileURLWithPath: "/Aerials/sky.mov")
        let scanned = AerialAsset(id: "sky", url: url, displayName: "Sky", category: nil, fileSize: 100, bookmarkData: Data([1]))
        let rescanned = AerialAsset(id: "sky", url: url, displayName: "Sky", category: nil, fileSize: 100, bookmarkData: Data([2]))
        let image = try #require(await cache.image(.aerial(.init(scanned)), pixelSize: size, scale: 1))
        #expect(cache.cached(.aerial(.init(rescanned)), pixelSize: size, scale: 1) === image, "the rescan's new bookmark missed the cache")
        #expect(bookmarks == [scanned.bookmarkData])
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
