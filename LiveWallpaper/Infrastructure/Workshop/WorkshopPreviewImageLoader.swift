#if !LITE_BUILD
import AppKit
import Foundation

/// Fetches one preview's encoded bytes. A seam, so a test can count fetches and
/// prove that a disk hit does not make one.
typealias WorkshopPreviewByteFetch = @Sendable (URL) async -> Data?

/// Workshop preview fetch: allow-list redirects, image/* only, capped, cookieless session.
@MainActor
final class WorkshopPreviewImageLoader {

    static let shared = WorkshopPreviewImageLoader()

    // Sync with WorkshopAnimatedGIF.maxBytes (32 MiB blanked real GIF previews).
    nonisolated static let maxBytes = 32 * 1024 * 1024
    /// Sized for a screenful plus scroll headroom, not the browsing history: a tile poster caps at 800px on its long edge, so a 16:9 preview decodes to 800×450×4 ≈ 1.44 MB (the meter's 84 live entries averaged 1.52 MiB); the default window shows ~12 tiles (4 columns × ~3 rows), a maximised 1440p window ~50 (one whole query page).
    /// 48 MB ≈ 33 posters, so the cost limit is what binds for tiles and the count limit only catches unusually small entries.
    /// Undersizing is cheap now that `WorkshopPreviewDiskCache` backs this (a miss costs a disk read and decode, not a download), and a mounted tile holds its own asset via `GIFAnimationController`, so eviction never blanks a visible card.
    /// Was 128 MB / 128 entries, which metered at 127.65 MiB live with 177 evictions against 261 inserts — full to the brim and thrashing.
    nonisolated static let cacheCountLimit = 40
    nonisolated static let cacheCostLimit = 48 * 1024 * 1024

    /// Keyed by URL *and* decode size: Steam serves one `preview_url` for both
    /// the grid tile and the detail hero, and a tile-sized poster must not be
    /// handed to the hero (or the hero's cost charged to a grid page). Not
    /// `private`: `LocalImageCacheReclaimerTests` observes that the last window closing empties this too, the same way it observes the three local-source caches.
    let assetCache = NSCache<NSString, CachedWorkshopPreviewAsset>()
    private var assetInflight: [String: InflightLoad] = [:]
    private let diskCache: WorkshopPreviewDiskCache
    private let fetch: WorkshopPreviewByteFetch

    /// One shared load, plus how many tiles are still waiting on it. Sweeping
    /// through pages used to leave every started download running to completion:
    /// the loader's task is deliberately detached from the view's `.task` so
    /// several tiles can share one fetch, and nothing counted when the last of them went away.
    @MainActor
    private final class InflightLoad {
        var task: Task<CachedWorkshopPreviewAsset?, Never>!
        var waiters = 0
    }

    /// Both the normal and the cancelled path release the same waiter, and on
    /// cancellation both can run. `@unchecked Sendable` so the cancellation
    /// handler — which runs on the cancelling task's executor — can carry it
    /// back to the main actor, where every read and write of `released` happens.
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
        // Reclaimed with the local caches once the last window closes — safe
        // only because these bytes now survive on disk: a rebuild is a 0.05 ms
        // read plus a decode (measured p50 1.5 ms, p95 8.2 ms), never a
        // re-download. The budget itself stays, since that decode tail is why the tier must keep its size while a window is open.
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

    /// Cookieless and cache-less on purpose: nothing about a browsing session is
    /// offered to Steam's CDN or written to disk by the URL loading system.
    /// `WorkshopPreviewDiskCache` is the disk layer instead and holds image bytes
    /// only — switching `urlCache` on here would put response headers, and anything cookie-shaped in them, back on disk.
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
            WPEImageCacheMeter.recordInsert(
                cached, cost: cached.estimatedCacheCost, in: .workshopPreview
            )
            self.assetCache.setObject(cached, forKey: cacheKey as NSString, cost: cached.estimatedCacheCost)
            return cached
        }
        assetInflight[cacheKey] = load
        return load
    }

    /// Cancels the shared load once nothing is waiting on it any more. Takes the
    /// `InflightLoad` the caller actually joined rather than looking the key up
    /// again: by the time the last waiter of an old load lets go, a new tile may already have registered a different load under the same key.
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
        // Allow-list before anything else, and key the disk entry on the
        // canonical URL: a disk hit never reaches `fetchData`, so this is the
        // only remaining gate that can stop a host dropped from the allow-list
        // in a later version from still being served out of an old entry.
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
            // No cancellation check here on purpose: the store below now happens
            // after the decode, and bailing out at this point would drop bytes
            // that were already paid for. A cancelled tile reaches the decode
            // and comes back `.abandoned`, which still stores.
            guard let data else { return nil }
            // Decode off the main actor — the CGImageSource work is CPU-bound.
            let decoding = PreviewSignpost.begin("workshop.decode")
            // `Task.detached` does not inherit cancellation, so an abandoned tile
            // used to hold its gate slot until the decode finished anyway.
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
            // The disk entry is written here, after the verdict, not before the
            // decode: a body that passed every network check (200, `image/*`,
            // under the byte cap) but still wasn't an image used to be persisted
            // anyway, so every later visit hit that dead entry and the card stayed blank until the TTL or cap caught it. `.abandoned` still stores — those bytes are already paid for and nothing ever judged them.
            if !servedFromDisk, outcome.keepsBytes {
                await diskCache.store(data, for: canonicalURL, size: size)
            }
            guard case .decoded(let asset) = outcome else { return nil }
            return asset
        }
    }

    /// How one decode attempt ended. "These bytes are not an image" and "nobody
    /// was left waiting to find out" have to be told apart, because only the
    /// first of them must keep the bytes off disk.
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
/// Not `private`: `LocalImageCacheReclaimerTests` builds one to prove the last
/// window closing empties this cache too.
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
