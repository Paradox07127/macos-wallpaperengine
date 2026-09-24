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
        case workshop(WPEHistoryEntry)
        #endif

        fileprivate var identity: String {
            switch self {
            case let .bookmark(bookmark): "bookmark:\(bookmark.id)"
            case let .aerial(preview): preview.key.previewKey
            #if !LITE_BUILD
            case let .workshop(entry): "workshop:\(entry.id)"
            #endif
            }
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
                return await Task.detached(priority: .utility) { () -> CGImage? in
                    let url = resolved.url
                    let didStart = url.startAccessingSecurityScopedResource()
                    defer {
                        if didStart {
                            url.stopAccessingSecurityScopedResource()
                        }
                    }
                    guard let result = try? InMemoryVideoAssetLoader.loadPackageEntry(
                        packageURL: url, entryName: packageEntryName
                    ) else { return nil }
                    let asset = AVURLAsset(url: result.customURL, options: [
                        AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue,
                        AVURLAssetAllowsCellularAccessKey: false,
                        AVURLAssetAllowsExpensiveNetworkAccessKey: false,
                        AVURLAssetAllowsConstrainedNetworkAccessKey: false,
                    ])
                    asset.resourceLoader.setDelegate(result.loader, queue: DispatchQueue(
                        label: "app.livewallpaper.shelf-thumbnail-loader", qos: .utility
                    ))
                    // AVFoundation holds its resource-loader delegate weakly during image generation.
                    defer { withExtendedLifetime(result.loader) {} }
                    let generator = AVAssetImageGenerator(asset: asset)
                    generator.appliesPreferredTrackTransform = true
                    generator.maximumSize = CGSize(width: 480, height: 270)
                    generator.requestedTimeToleranceBefore = .zero
                    generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
                    return try? await generator.image(at: .zero).image
                }.value
            }
            let image = await WallpaperThumbnailService.shared.videoPosterImage(for: resolved.url, cacheKey: cacheKey)
            return image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
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

    private var inFlight: [Key: Task<CGImage?, Never>] = [:]
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
        case let .workshop(entry):
            return await sources.scene(entry.origin, pixelSize)
        #endif
        }
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
