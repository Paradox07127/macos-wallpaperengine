#if !LITE_BUILD
import AppKit
import Foundation

/// Workshop preview fetch: allow-list redirects, image/* only, capped, cookieless session.
@MainActor
final class WorkshopPreviewImageLoader {

    static let shared = WorkshopPreviewImageLoader()

    // Sync with WorkshopAnimatedGIF.maxBytes (8 MiB blanked real GIF previews).
    nonisolated static let maxBytes = 32 * 1024 * 1024
    nonisolated static let cacheCountLimit = 128
    nonisolated static let cacheCostLimit = 128 * 1024 * 1024

    private let assetCache = NSCache<NSURL, CachedWorkshopPreviewAsset>()
    private var assetInflight: [
        URL: Task<CachedWorkshopPreviewAsset?, Never>
    ] = [:]
    private let session: URLSession

    init() {
        assetCache.countLimit = Self.cacheCountLimit
        assetCache.totalCostLimit = Self.cacheCostLimit

        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 30
        // `URLSession` retains its delegate, so no stored reference is needed.
        self.session = URLSession(configuration: config, delegate: RedirectGuardDelegate(), delegateQueue: nil)
    }

    /// Returns `nil` if any allow-list / content-type / size check fails —
    /// callers fall back to a placeholder.
    func load(_ url: URL) async -> NSImage? {
        // Route through `loadAsset` so the poster goes through the same byte /
        // frame-count / decoded-pixel caps (paste-flow thumbnails included).
        await loadCachedAsset(url)?.posterImage
    }

    /// Load as still vs bounded animation for hover-to-play.
    func loadAsset(_ url: URL) async -> WorkshopPreviewAsset? {
        await loadCachedAsset(url)?.asset
    }

    private func loadCachedAsset(_ url: URL) async -> CachedWorkshopPreviewAsset? {
        let cacheKey = url as NSURL
        if let cached = assetCache.object(forKey: cacheKey) {
            return cached
        }
        if let task = assetInflight[url] { return await task.value }
        let task = Task<CachedWorkshopPreviewAsset?, Never> { @MainActor [weak self] in
            guard let self,
                  let asset = await self.performAssetLoad(url) else { return nil }
            return CachedWorkshopPreviewAsset(asset: asset)
        }
        assetInflight[url] = task
        let result = await task.value
        assetInflight.removeValue(forKey: url)
        if let result {
            assetCache.setObject(
                result,
                forKey: cacheKey,
                cost: result.estimatedCacheCost
            )
        }
        return result
    }

    fileprivate static func nsImage(from image: CGImage) -> NSImage {
        NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    private func performAssetLoad(_ url: URL) async -> WorkshopPreviewAsset? {
        let session = session
        guard let data = await Self.fetchData(url, session: session) else { return nil }
        // Decode off the main actor — the CGImageSource work is CPU-bound.
        return await Task.detached(priority: .userInitiated) {
            WorkshopAnimatedGIF.make(from: data)
        }.value
    }

    /// Stream body with size cap; re-check allow-list; require 200 + image/*.
    private nonisolated static func fetchData(_ url: URL, session: URLSession) async -> Data? {
        guard case .allowed(let canonicalURL) = WorkshopCDNHostAllowList.evaluate(url.absoluteString) else {
            return nil
        }
        var request = URLRequest(url: canonicalURL)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            return nil
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let mime = http.value(forHTTPHeaderField: "Content-Type")?.lowercased(),
              mime.hasPrefix("image/"),
              http.expectedContentLength <= Int64(maxBytes) else {
            return nil
        }

        var data = Data()
        if http.expectedContentLength > 0 {
            data.reserveCapacity(Int(http.expectedContentLength))
        }
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > maxBytes { return nil }
            }
        } catch {
            return nil
        }
        return data
    }
}

/// One cache entry owns both the decoded asset and its AppKit poster wrapper.
/// Keeping these together removes the prior duplicate URL→poster dictionary.
@MainActor
private final class CachedWorkshopPreviewAsset {
    let asset: WorkshopPreviewAsset
    let posterImage: NSImage
    let estimatedCacheCost: Int

    init(asset: WorkshopPreviewAsset) {
        self.asset = asset
        posterImage = WorkshopPreviewImageLoader.nsImage(from: asset.posterFrame)
        estimatedCacheCost = asset.estimatedCacheCost
    }
}

/// Cancel redirects that fail WorkshopCDNHostAllowList.
private final class RedirectGuardDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url else {
            completionHandler(nil)
            return
        }
        switch WorkshopCDNHostAllowList.evaluate(url.absoluteString) {
        case .allowed:
            completionHandler(request)
        case .rejected:
            completionHandler(nil)
        }
    }
}
#endif
