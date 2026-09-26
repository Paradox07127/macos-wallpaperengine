import AppKit
import AVFoundation
import ImageIO
import LiveWallpaperCore
#if !LITE_BUILD
import LiveWallpaperProWPE
#endif

@MainActor
final class ShelfThumbnailCache {
    enum Request: Equatable, Sendable {
        case bookmark(WallpaperBookmark)
        case aerial(AerialPreview)
        #if !LITE_BUILD
        /// `coverRevision`: the revision of the import's saved cover, new with every write of it; nil while it has none.
        case workshop(WPEHistoryEntry, coverRevision: Int? = nil)
        #endif

        fileprivate var identity: String {
            switch self {
            case let .bookmark(bookmark): "bookmark:\(bookmark.id)"
            case let .aerial(preview): preview.key.previewKey
            #if !LITE_BUILD
            case let .workshop(entry, _): "workshop:\(entry.id)"
            #endif
            }
        }

        /// The scene whose preview file `sourceImage(for:)` draws for this request; nil when a saved
        /// cover, a video poster or a web snapshot is drawn instead.
        var scenePreviewOrigin: WPEOrigin? {
            #if LITE_BUILD
            return nil
            #else
            switch self {
            case let .bookmark(bookmark):
                guard bookmark.coverFileName == nil, case .scene = bookmark.content else { return nil }
                return bookmark.wpeOrigin
            case .aerial:
                return nil
            case let .workshop(entry, coverRevision):
                guard coverRevision == nil, entry.origin.originalType != .video else { return nil }
                return entry.origin
            }
            #endif
        }
    }

    struct AerialPreview: Equatable, Sendable {
        let key: AerialThumbnailCacheKey
        let bookmarkData: Data

        init(_ asset: AerialAsset) {
            key = AerialThumbnailCacheKey(asset: asset)
            bookmarkData = asset.bookmarkData
        }

        /// Not the bookmark bytes: every scan bookmarks the same file anew, which would miss the cache after each rescan.
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.key == rhs.key
        }
    }

    struct Sources {
        var cover: @MainActor (String) async -> CGImage? = { name in
            let image = await WallpaperCoverStore.shared.cover(named: name)
            return image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }

        var video: @MainActor (Data, String?, String) async -> CGImage? = { bookmarkData, packageEntryName, cacheKey in
            let resolved = await Task.detached(priority: .utility) {
                try? SecurityScopedBookmarkResolver.shared.resolve(bookmarkData, target: .transient).get()
            }.value
            guard let resolved else { return nil }
            if let packageEntryName {
                return await ShelfThumbnailCache.frame(
                    of: resolved.url, packageEntryName: packageEntryName, maximumSize: CGSize(width: 480, height: 270)
                )
            }
            let image = await WallpaperThumbnailService.shared.videoPosterImage(for: resolved.url, cacheKey: cacheKey)
            return image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }

        /// A frame at most `box` pixels, its own aspect kept: the modal's still. Not `WallpaperThumbnailService`,
        /// whose cache key has no size and would hand back the 480×270 card poster.
        var videoFrame: @MainActor (Data, String?, CGSize) async -> CGImage? = { bookmarkData, packageEntryName, box in
            let resolved = await Task.detached(priority: .utility) {
                try? SecurityScopedBookmarkResolver.shared.resolve(bookmarkData, target: .transient).get()
            }.value
            guard let url = resolved?.url else { return nil }
            return await ShelfThumbnailCache.frame(of: url, packageEntryName: packageEntryName, maximumSize: box)
        }

        var web: @MainActor (HTMLSource, HTMLConfig) async -> CGImage? = { source, config in
            let image = await HTMLPreviewKey.fetchSnapshot(
                for: source, config: config, cacheKey: HTMLPreviewKey.key(for: source, config: config)
            )
            return image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }

        #if !LITE_BUILD
        var scene: @MainActor (WPEOrigin, CGSize) async -> CGImage? = { origin, pixelSize in
            await Task.detached(priority: .utility) { () -> CGImage? in
                guard let url = origin.sourcePreviewURL,
                      let resolved = try? SecurityScopedBookmarkResolver.shared
                      .resolve(origin.sourceFolderBookmark, target: .transient).get() else { return nil }
                return SecurityScopedBookmarkResolver.withScopedAccess(resolved.url) { _ in
                    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                    // Scene previews run to 4K and beyond; decoding one at full size to hand a
                    // 400pt card costs orders of magnitude more than the thumbnail it becomes.
                    return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceShouldCacheImmediately: true,
                        kCGImageSourceThumbnailMaxPixelSize: Int(max(pixelSize.width, pixelSize.height)),
                    ] as CFDictionary)
                }
            }.value
        }

        /// A saved cover decoded straight to at most the given long side, outside the store's full-size cache.
        var coverThumbnail: @MainActor (String, Int) async -> CGImage? = { name, maxPixelSize in
            await WallpaperCoverStore.shared.cover(named: name, maxPixelSize: maxPixelSize)
        }

        var workshopContent: @MainActor (WPEOrigin) -> WallpaperContent? = { WPECachedContentResolver().content(for: $0) }
        #endif
    }

    private final class Key: NSObject {
        let request: Request
        let pixelSize: CGSize
        let scale: CGFloat

        init(_ request: Request, pixelSize: CGSize, scale: CGFloat) {
            self.request = request
            self.pixelSize = pixelSize
            self.scale = scale
        }

        override var hash: Int {
            var hasher = Hasher()
            hasher.combine(request.identity)
            hasher.combine(pixelSize.width)
            hasher.combine(pixelSize.height)
            hasher.combine(scale)
            return hasher.finalize()
        }

        override func isEqual(_ object: Any?) -> Bool {
            guard let other = object as? Key else { return false }
            return request == other.request && pixelSize == other.pixelSize && scale == other.scale
        }
    }

    private let cache = NSCache<Key, CGImage>()
    /// The modal's newest stills, oldest first. Apart from `cache`, so paging the modal never evicts a card's thumbnail.
    private var stills: [(key: Key, image: CGImage)] = []
    private static let stillLimit = 3

    private var inFlight: [Key: Task<CGImage?, Never>] = [:]
    private var stillsInFlight: [Key: Task<CGImage?, Never>] = [:]
    private let sources: Sources

    /// `costLimit` is in bytes of decoded pixels.
    init(sources: Sources = Sources(), costLimit: Int = 32 * 1024 * 1024) {
        self.sources = sources
        cache.totalCostLimit = costLimit
    }

    /// pixelSize is already in backing pixels; scale distinguishes display backing scales without multiplying it again.
    func cached(_ request: Request, pixelSize: CGSize, scale: CGFloat) -> CGImage? {
        cache.object(forKey: Key(request, pixelSize: pixelSize, scale: scale))
    }

    func image(_ request: Request, pixelSize: CGSize, scale: CGFloat) async -> CGImage? {
        let key = Key(request, pixelSize: pixelSize, scale: scale)
        if let image = cache.object(forKey: key) {
            return image
        }
        if let task = inFlight[key] {
            return await task.value
        }
        let task = Task { () -> CGImage? in
            defer { inFlight[key] = nil }
            guard let source = await sourceImage(for: request, pixelSize: pixelSize) else { return nil }
            let image = await Task.detached(priority: .utility) {
                Self.downscale(source, pixelSize: pixelSize)
            }.value
            if let image {
                cache.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
            }
            return image
        }
        inFlight[key] = task
        return await task.value
    }

    /// The modal's still: the whole picture inside `box` (pixels), never enlarged past its source's own pixels.
    /// `video` is the file a Workshop row plays when its project is a video.
    func still(_ request: Request, box: CGSize, video: WallpaperContent? = nil) async -> CGImage? {
        let key = Key(request, pixelSize: box, scale: 1)
        if let index = stills.firstIndex(where: { $0.key == key }) {
            let hit = stills.remove(at: index)
            stills.append(hit)
            return hit.image
        }
        if let task = stillsInFlight[key] {
            return await task.value
        }
        let task = Task { () -> CGImage? in
            defer { stillsInFlight[key] = nil }
            guard let source = await stillSource(for: request, box: box, video: video) else { return nil }
            let image = await Task.detached(priority: .utility) {
                Self.fitted(source, inside: box)
            }.value
            if let image {
                stills.append((key, image))
                if stills.count > Self.stillLimit {
                    stills.removeFirst()
                }
            }
            return image
        }
        stillsInFlight[key] = task
        return await task.value
    }

    func prewarm(_ requests: [Request], pixelSize: CGSize, scale: CGFloat) {
        for request in requests {
            Task { _ = await image(request, pixelSize: pixelSize, scale: scale) }
        }
    }

    private func sourceImage(for request: Request, pixelSize: CGSize) async -> CGImage? {
        switch request {
        case let .bookmark(bookmark):
            if let name = bookmark.coverFileName, let image = await sources.cover(name) {
                return image
            }
            switch bookmark.content {
            case let .video(data, packageEntryName):
                let key = "shelf.video::\(data.base64EncodedString())::\(packageEntryName ?? "")"
                if let image = await sources.video(data, packageEntryName, key) {
                    return image
                }
            case let .html(source, config):
                if let image = await sources.web(source, config) {
                    return image
                }
            case .scene:
                break
            }
            #if !LITE_BUILD
            if let origin = bookmark.wpeOrigin {
                return await sources.scene(origin, pixelSize)
            }
            #endif
            return nil
        case let .aerial(preview):
            return await sources.video(preview.bookmarkData, nil, "shelf.\(preview.key.previewKey)")
        #if !LITE_BUILD
        case let .workshop(entry, coverRevision):
            if coverRevision != nil,
               let name = WallpaperCoverStore.workshopFileName(workshopID: entry.origin.workshopID, importedAt: entry.importedAt),
               let image = await sources.coverThumbnail(name, Int(max(pixelSize.width, pixelSize.height))) {
                return image
            }
            if entry.origin.originalType == .video,
               case let .video(data, packageEntryName)? = sources.workshopContent(entry.origin),
               let image = await sources.videoFrame(data, packageEntryName, pixelSize) {
                return image
            }
            return await sources.scene(entry.origin, pixelSize)
        #endif
        }
    }

    private func stillSource(for request: Request, box: CGSize, video: WallpaperContent?) async -> CGImage? {
        switch request {
        case let .bookmark(bookmark):
            if let name = bookmark.coverFileName, let image = await sources.cover(name) {
                return image
            }
            switch bookmark.content {
            case let .video(data, packageEntryName):
                if let image = await sources.videoFrame(data, packageEntryName, box) {
                    return image
                }
            case let .html(source, config):
                if let image = await sources.web(source, config) {
                    return image
                }
            case .scene:
                break
            }
            #if !LITE_BUILD
            if let origin = bookmark.wpeOrigin {
                return await sources.scene(origin, box)
            }
            #endif
            return nil
        case let .aerial(preview):
            return await sources.videoFrame(preview.bookmarkData, nil, box)
        #if !LITE_BUILD
        case let .workshop(entry, coverRevision):
            if coverRevision != nil,
               let name = WallpaperCoverStore.workshopFileName(workshopID: entry.origin.workshopID, importedAt: entry.importedAt),
               let image = await sources.cover(name) {
                return image
            }
            if case let .video(data, packageEntryName)? = video,
               let image = await sources.videoFrame(data, packageEntryName, box) {
                return image
            }
            return await sources.scene(entry.origin, box)
        #endif
        }
    }

    /// A source already inside `box` comes back as it is: the still is never enlarged.
    private nonisolated static func fitted(_ image: CGImage, inside box: CGSize) -> CGImage? {
        let scale = min(box.width / CGFloat(image.width), box.height / CGFloat(image.height), 1)
        guard scale < 1 else { return image }
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// `url` is the video file, or the package when `packageEntryName` names an entry inside it.
    nonisolated static func frame(of url: URL, packageEntryName: String?, maximumSize: CGSize) async -> CGImage? {
        await Task.detached(priority: .utility) { () -> CGImage? in
            let didStart = url.startAccessingSecurityScopedResource()
            defer {
                if didStart {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            let asset: AVURLAsset
            var loader: InMemoryVideoAssetLoader?
            if let packageEntryName {
                guard let result = try? InMemoryVideoAssetLoader.loadPackageEntry(
                    packageURL: url, entryName: packageEntryName
                ) else { return nil }
                asset = AVURLAsset(url: result.customURL, options: [
                    AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue,
                    AVURLAssetAllowsCellularAccessKey: false,
                    AVURLAssetAllowsExpensiveNetworkAccessKey: false,
                    AVURLAssetAllowsConstrainedNetworkAccessKey: false,
                ])
                asset.resourceLoader.setDelegate(result.loader, queue: DispatchQueue(
                    label: "app.livewallpaper.shelf-thumbnail-loader", qos: .utility
                ))
                loader = result.loader
            } else {
                asset = AVURLAsset(url: url)
            }
            // AVFoundation holds its resource-loader delegate weakly during image generation.
            defer { withExtendedLifetime(loader) {} }
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = maximumSize
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
            return try? await generator.image(at: .zero).image
        }.value
    }

    private nonisolated static func downscale(_ image: CGImage, pixelSize: CGSize) -> CGImage? {
        let width = Int(pixelSize.width)
        let height = Int(pixelSize.height)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let ratio = max(CGFloat(width) / CGFloat(image.width), CGFloat(height) / CGFloat(image.height))
        let drawSize = CGSize(width: CGFloat(image.width) * ratio, height: CGFloat(image.height) * ratio)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(
            x: (CGFloat(width) - drawSize.width) / 2, y: (CGFloat(height) - drawSize.height) / 2,
            width: drawSize.width, height: drawSize.height
        ))
        return context.makeImage()
    }
}
