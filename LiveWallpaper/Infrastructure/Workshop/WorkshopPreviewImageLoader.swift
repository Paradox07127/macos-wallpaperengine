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

    /// Keyed by URL *and* decode size: Steam serves one `preview_url` for the
    /// grid tile and the detail hero, and a tile-sized poster must not be handed
    /// to the hero (or the hero's cost charged to a grid page).
    private let assetCache = NSCache<NSString, CachedWorkshopPreviewAsset>()
    private var assetInflight: [String: InflightLoad] = [:]
    private let session: URLSession

    /// One shared load, plus how many tiles are still waiting on it. Sweeping
    /// through pages used to leave every started download running to completion:
    /// the view's `.task` was cancelled, but the loader's task was deliberately
    /// detached from it so several tiles could share one fetch, and nothing
    /// counted when the last of them went away.
    @MainActor
    private final class InflightLoad {
        var task: Task<CachedWorkshopPreviewAsset?, Never>!
        var waiters = 0
    }

    /// Both the normal and the cancelled path release the same waiter, and on
    /// cancellation both can run.
    ///
    /// `@unchecked Sendable` so the cancellation handler — which runs on the
    /// cancelling task's executor — can carry it back to the main actor; every
    /// read and write of `released` happens there.
    @MainActor
    private final class WaiterRelease: @unchecked Sendable {
        private var released = false
        func callOnce(_ body: () -> Void) {
            guard !released else { return }
            released = true
            body()
        }
    }

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
    func load(_ url: URL, size: WorkshopPreviewSize = .tile) async -> NSImage? {
        // Route through `loadAsset` so the poster goes through the same byte /
        // frame-count / decoded-pixel caps (paste-flow thumbnails included).
        await loadCachedAsset(url, size: size)?.posterImage
    }

    /// Load as still vs bounded animation for hover-to-play.
    func loadAsset(_ url: URL, size: WorkshopPreviewSize = .tile) async -> WorkshopPreviewAsset? {
        await loadCachedAsset(url, size: size)?.asset
    }

    private func loadCachedAsset(
        _ url: URL,
        size: WorkshopPreviewSize
    ) async -> CachedWorkshopPreviewAsset? {
        let cacheKey = "\(size.rawValue)|\(url.absoluteString)"
        if let cached = assetCache.object(forKey: cacheKey as NSString) {
            PreviewSignpost.event("workshop.cacheHit")
            return cached
        }

        let load = inflightLoad(for: cacheKey, url: url, size: size)
        load.waiters += 1
        let release = WaiterRelease()
        let result = await withTaskCancellationHandler {
            await load.task.value
        } onCancel: {
            // Fires on the cancelling task's executor, so hop back.
            Task { @MainActor [weak self] in
                release.callOnce { self?.dropWaiter(load, forKey: cacheKey) }
            }
        }
        release.callOnce { dropWaiter(load, forKey: cacheKey) }
        return result
    }

    private func inflightLoad(
        for cacheKey: String,
        url: URL,
        size: WorkshopPreviewSize
    ) -> InflightLoad {
        if let existing = assetInflight[cacheKey] { return existing }
        let load = InflightLoad()
        load.task = Task<CachedWorkshopPreviewAsset?, Never> { @MainActor [weak self] in
            defer { self?.retire(load, forKey: cacheKey) }
            guard let self,
                  let asset = await self.performAssetLoad(url, size: size) else { return nil }
            let cached = CachedWorkshopPreviewAsset(asset: asset)
            self.assetCache.setObject(cached, forKey: cacheKey as NSString, cost: cached.estimatedCacheCost)
            return cached
        }
        assetInflight[cacheKey] = load
        return load
    }

    /// Cancels the shared load once nothing is waiting on it any more.
    ///
    /// Takes the `InflightLoad` the caller actually joined rather than looking
    /// the key up again: by the time the last waiter of an old load lets go, a
    /// new tile may already have registered a different load under the same key.
    private func dropWaiter(_ load: InflightLoad, forKey cacheKey: String) {
        load.waiters -= 1
        guard load.waiters <= 0 else { return }
        load.task.cancel()
        retire(load, forKey: cacheKey)
    }

    /// Unregisters `load` only if it is still the load registered for that key.
    /// A cancelled load finishes *after* its replacement has been registered,
    /// and removing by key alone would unregister the live one — leaving it
    /// impossible to cancel and making the next tile re-download the same bytes.
    private func retire(_ load: InflightLoad, forKey cacheKey: String) {
        guard assetInflight[cacheKey] === load else { return }
        assetInflight.removeValue(forKey: cacheKey)
    }

    fileprivate static func nsImage(from image: CGImage) -> NSImage {
        NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    private func performAssetLoad(
        _ url: URL,
        size: WorkshopPreviewSize
    ) async -> WorkshopPreviewAsset? {
        let session = session
        return await PreviewWorkGate.shared.run {
            // First act inside the gate: a tile that scrolled away while queued
            // must free its slot rather than make a visible tile wait for it.
            guard !Task.isCancelled else { return nil }
            let fetching = PreviewSignpost.begin("workshop.fetch")
            let data = await Self.fetchData(url, session: session)
            PreviewSignpost.end("workshop.fetch", fetching)
            guard let data, !Task.isCancelled else { return nil }
            // Decode off the main actor — the CGImageSource work is CPU-bound.
            let decoding = PreviewSignpost.begin("workshop.decode")
            // `Task.detached` does not inherit cancellation, so an abandoned tile
            // used to hold its gate slot until the decode finished anyway.
            let decode = Task.detached(priority: .userInitiated) { () -> WorkshopPreviewAsset? in
                guard !Task.isCancelled else { return nil }
                return WorkshopAnimatedGIF.make(from: data, size: size)
            }
            let asset = await withTaskCancellationHandler {
                await decode.value
            } onCancel: {
                decode.cancel()
            }
            PreviewSignpost.end("workshop.decode", decoding)
            return asset
        }
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

        do {
            return try await BoundedNetworkFetch.collect(
                bytes,
                expectedContentLength: http.expectedContentLength,
                byteCap: maxBytes
            )
        } catch {
            return nil
        }
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
