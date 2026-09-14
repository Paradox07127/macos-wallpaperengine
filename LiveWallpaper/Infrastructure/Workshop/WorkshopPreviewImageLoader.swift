#if !LITE_BUILD
import AppKit
import Foundation

typealias WorkshopPreviewByteFetch = @Sendable (URL) async -> Data?

@MainActor
final class WorkshopPreviewImageLoader {

    static let shared = WorkshopPreviewImageLoader()

    /// Sync with WorkshopAnimatedGIF.maxBytes.
    nonisolated static let maxBytes = 32 * 1024 * 1024
    /// Tile poster long-edge 800px: 16:9 -> 800x450x4 approx 1.44 MB; 48 MB approx 33 posters so the cost limit binds for tiles.
    nonisolated static let cacheCountLimit = 40
    nonisolated static let cacheCostLimit = 48 * 1024 * 1024

    /// Keyed by URL and decode size: one preview_url serves tile and hero. Not private (see LocalImageCacheReclaimerTests).
    let assetCache = NSCache<NSString, CachedWorkshopPreviewAsset>()
    private var assetInflight: [String: InflightLoad] = [:]
    private let diskCache: WorkshopPreviewDiskCache
    private let fetch: WorkshopPreviewByteFetch

    /// One shared load plus waiter count. The loader task is detached from the view's .task so several tiles can share one fetch; without waiters a sweep would leave every started download running to completion.
    @MainActor
    private final class InflightLoad {
        var task: Task<CachedWorkshopPreviewAsset?, Never>!
        var waiters = 0
    }

    /// Both the normal and cancelled path release the same waiter and on cancellation both can run. @unchecked Sendable so the cancellation handler can hop back to the main actor.
    @MainActor
    private final class WaiterRelease: @unchecked Sendable {
        private var released = false
        func callOnce(_ body: () -> Void) {
            guard !released else { return }
            released = true
            body()
        }
    }

    init(
        diskCache: WorkshopPreviewDiskCache = .shared,
        fetch: WorkshopPreviewByteFetch? = nil
    ) {
        assetCache.countLimit = Self.cacheCountLimit
        assetCache.totalCostLimit = Self.cacheCostLimit
        WPEImageCacheMeter.attach(assetCache, as: .workshopPreview)
        // Reclaimed with the local caches once the last window closes — safe only because these bytes now survive on disk. The budget stays: the decode tail is why the tier must keep its size while a window is open.
        LocalImageCacheRegistry.shared.register(assetCache)
        self.diskCache = diskCache

        // `URLSession` retains its delegate and the default fetch retains the
        // session, so neither needs a stored reference.
        let session = URLSession(
            configuration: Self.makeSessionConfiguration(),
            delegate: RedirectGuardDelegate(),
            delegateQueue: nil
        )
        self.fetch = fetch ?? { url in await Self.fetchData(url, session: session) }
    }

    /// Cookieless and cache-less on purpose. Switching urlCache on here would put response headers, and anything cookie-shaped in them, back on disk.
    nonisolated static func makeSessionConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 30
        return config
    }

    /// Returns `nil` if any allow-list / content-type / size check fails —
    /// callers fall back to a placeholder.
    func load(_ url: URL, size: WorkshopPreviewSize = .tile) async -> NSImage? {
        await loadCachedAsset(url, size: size)?.posterImage
    }

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
            WPEImageCacheMeter.recordInsert(
                cached, cost: cached.estimatedCacheCost, in: .workshopPreview
            )
            self.assetCache.setObject(cached, forKey: cacheKey as NSString, cost: cached.estimatedCacheCost)
            return cached
        }
        assetInflight[cacheKey] = load
        return load
    }

    /// Cancels the shared load once nothing is waiting. Takes the InflightLoad the caller joined rather than looking the key up: a new tile may already have registered a different load under the same key.
    private func dropWaiter(_ load: InflightLoad, forKey cacheKey: String) {
        load.waiters -= 1
        guard load.waiters <= 0 else { return }
        load.task.cancel()
        retire(load, forKey: cacheKey)
    }

    /// Unregister load only if it is still the load for that key. Removing by key alone would unregister a live replacement.
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
        // Allow-list before anything else, and key the disk entry on the canonical URL: a disk hit never reaches fetchData, so this is the only remaining gate for a host later dropped from the allow-list.
        guard case .allowed(let canonicalURL) =
                WorkshopCDNHostAllowList.evaluate(url.absoluteString) else { return nil }
        let diskCache = diskCache
        let fetch = fetch
        return await PreviewWorkGate.shared.run {
            // First act inside the gate: a tile that scrolled away while queued
            // must free its slot rather than make a visible tile wait for it.
            guard !Task.isCancelled else { return nil }
            var data = await diskCache.data(for: canonicalURL, size: size)
            let servedFromDisk = data != nil
            if servedFromDisk {
                PreviewSignpost.event("workshop.diskHit")
            } else {
                let fetching = PreviewSignpost.begin("workshop.fetch")
                data = await fetch(canonicalURL)
                PreviewSignpost.end("workshop.fetch", fetching)
            }
            // No cancellation check here: bailing would drop bytes already paid for. A cancelled tile reaches decode and comes back .abandoned, which still stores.
            guard let data else { return nil }
            let decoding = PreviewSignpost.begin("workshop.decode")
            // Task.detached does not inherit cancellation, so an abandoned tile would hold its gate slot until the decode finished anyway.
            let decode = Task.detached(priority: .userInitiated) { () -> PreviewDecodeOutcome in
                guard !Task.isCancelled else { return .abandoned }
                guard let asset = WorkshopAnimatedGIF.make(from: data, size: size) else {
                    return .undecodable
                }
                return .decoded(asset)
            }
            let outcome = await withTaskCancellationHandler {
                await decode.value
            } onCancel: {
                decode.cancel()
            }
            PreviewSignpost.end("workshop.decode", decoding)
            // Write the disk entry after the verdict, not before decode. A non-image body that passed network checks would persist and blank the card until TTL/cap. .abandoned still stores — those bytes are already paid for.
            if !servedFromDisk, outcome.keepsBytes {
                await diskCache.store(data, for: canonicalURL, size: size)
            }
            guard case .decoded(let asset) = outcome else { return nil }
            return asset
        }
    }

    /// undecodable vs abandoned must be told apart: only the former keeps the bytes off disk.
    private enum PreviewDecodeOutcome: Sendable {
        case decoded(WorkshopPreviewAsset)
        case undecodable
        case abandoned

        var keepsBytes: Bool {
            switch self {
            case .decoded, .abandoned: return true
            case .undecodable: return false
            }
        }
    }

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

@MainActor
final class CachedWorkshopPreviewAsset {
    let asset: WorkshopPreviewAsset
    let posterImage: NSImage
    let estimatedCacheCost: Int

    init(asset: WorkshopPreviewAsset) {
        self.asset = asset
        posterImage = WorkshopPreviewImageLoader.nsImage(from: asset.posterFrame)
        estimatedCacheCost = asset.estimatedCacheCost
    }
}

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
