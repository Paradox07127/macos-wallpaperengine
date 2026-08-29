#if !LITE_BUILD
import Foundation
import WebKit

/// URL builder for Valve's public Workshop browse page — the zero-key search
/// path. Parameters verified live against `steamcommunity.com` on 2026-08-29:
/// `browsesort`, `days`, `searchtext`, `requiredtags[]` and `excludedtags[]`
/// all filter server-side, `p` pages (disjoint result sets), and `numperpage`
/// is ignored — the page always returns 30 items.
enum WorkshopPublicBrowseURL {
    static let itemsPerPage = 30

    private static let base = "https://steamcommunity.com/workshop/browse/"

    static func url(for request: WorkshopQueryRequest, appID: Int) -> URL {
        // The browse page has no creator parameter (`created_by` is silently
        // ignored, verified 2026-08-29) — a creator scope has its own page.
        if let creator = request.creatorSteamID {
            var components = URLComponents()
            components.scheme = "https"
            components.host = "steamcommunity.com"
            components.path = "/profiles/\(creator)/myworkshopfiles/"
            components.queryItems = [
                URLQueryItem(name: "appid", value: String(appID)),
                // This page defaults to a 9-item preview grid; unlike the
                // browse page it does honour `numperpage`.
                URLQueryItem(name: "numperpage", value: String(itemsPerPage)),
                URLQueryItem(name: "p", value: String(request.page))
            ]
            return components.url!
        }

        var items: [URLQueryItem] = [
            URLQueryItem(name: "appid", value: String(appID)),
            URLQueryItem(name: "browsesort", value: browseSort(for: request.sort)),
            URLQueryItem(name: "p", value: String(request.page))
        ]
        if !request.searchText.isEmpty {
            items.append(URLQueryItem(name: "searchtext", value: request.searchText))
        }
        if let days = request.days {
            items.append(URLQueryItem(name: "days", value: String(days)))
        }
        items += request.requiredTags.map { URLQueryItem(name: "requiredtags[]", value: $0) }
        items += request.excludedTags.map { URLQueryItem(name: "excludedtags[]", value: $0) }

        var components = URLComponents(string: base)!
        components.queryItems = items
        return components.url!
    }

    /// Public-page sort keys. Every `WorkshopSortMode` has one, so the keyless
    /// path exposes the same sort menu as the keyed one.
    static func browseSort(for sort: WorkshopSortMode) -> String {
        switch sort {
        case .mostPopular: return "trend"
        case .topRated: return "toprated"
        case .newest: return "mostrecent"
        case .lastUpdated: return "lastupdated"
        case .mostSubscribed: return "totaluniquesubscribers"
        case .search: return "textsearch"
        }
    }
}

/// The page is used as an id source only. Titles, previews, authors and vote
/// data come from `GetPublishedFileDetails`, so the whole dependency on Valve's
/// HTML is the details-page URL shape.
enum WorkshopPublicIDExtractor {
    static let hrefCollectionScript = """
    Array.from(document.querySelectorAll('a[href*="filedetails/?id="]')).map(function (a) { return a.href; })
    """

    /// De-duplicated in page order: each result contributes two anchors
    /// (thumbnail + title) pointing at the same item.
    static func publishedFileIDs(fromHrefs hrefs: [String]) -> [UInt64] {
        var seen = Set<UInt64>()
        return hrefs.compactMap(publishedFileID(fromHref:)).filter { seen.insert($0).inserted }
    }

    /// The href must live on Valve's community host: the page also carries links
    /// authored by third parties, and an off-host `filedetails/?id=` would
    /// otherwise inject an arbitrary id into the result list.
    static func publishedFileID(fromHref href: String) -> UInt64? {
        guard let components = URLComponents(string: href),
              WorkshopPublicNavigationPolicy.allows(components.url),
              let value = components.queryItems?
                  .first(where: { $0.name == "id" })?
                  .value
        else { return nil }
        return UInt64(value)
    }
}

/// Navigation allow-list for the offscreen web view.
enum WorkshopPublicNavigationPolicy {
    private static let host = "steamcommunity.com"

    static func allows(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", let host = url.host()?.lowercased() else { return false }
        return host == Self.host || host.hasSuffix("." + Self.host)
    }
}

/// The single in-flight page load. `BrowseViewModel.reload()` cancels its task
/// and starts the next fetch immediately, so a second `load` can arrive while
/// the first is still suspended: taking the slot over settles the previous
/// waiter with `.cancelled` rather than leaving its continuation suspended
/// forever, and every callback is matched against the token it belongs to so a
/// stale one cannot resume the load that replaced it.
@MainActor
final class WorkshopPublicLoadSlot {

    private var token: UInt64 = 0
    private var resume: ((Result<Void, Error>) -> Void)?

    /// Supersedes any in-flight load and returns the new load's token.
    @discardableResult
    func begin(_ resume: @escaping (Result<Void, Error>) -> Void) -> UInt64 {
        finish(token: token, .failure(WorkshopQueryError.cancelled))
        token &+= 1
        self.resume = resume
        return token
    }

    /// No-op unless `token` still owns the slot — so it also never resumes twice.
    func finish(token: UInt64, _ result: Result<Void, Error>) {
        guard token == self.token, let resume else { return }
        self.resume = nil
        resume(result)
    }

    func isCurrent(_ token: UInt64) -> Bool {
        token == self.token && resume != nil
    }

    var currentToken: UInt64? { resume == nil ? nil : token }
}

/// Zero-key Workshop search: an offscreen, ephemeral `WKWebView` loads Valve's
/// public browse page purely to harvest published-file ids, which are then
/// resolved through the key-free `GetPublishedFileDetails` batch endpoint.
@MainActor
final class WorkshopPublicSearchSource: NSObject, WKNavigationDelegate {

    private let metadata: SteamWorkshopMetadataService
    private let appID: Int
    private var webView: WKWebView?
    private let loadSlot = WorkshopPublicLoadSlot()
    /// The main-document navigation of the current load. Sub-frame callbacks
    /// carry a different object (Valve's page embeds `login.`/`store.` iframes),
    /// and their failures must not end the search.
    private var mainNavigation: WKNavigation?

    /// Steam's page is server-rendered; this only has to cover a slow round trip.
    private static let loadTimeout: Duration = .seconds(20)

    init(
        metadata: SteamWorkshopMetadataService = SteamWorkshopMetadataService(),
        appID: Int = WorkshopQueryService.wallpaperEngineAppID
    ) {
        self.metadata = metadata
        self.appID = appID
    }

    func fetch(_ request: WorkshopQueryRequest) async throws -> WorkshopQueryPage {
        let url = WorkshopPublicBrowseURL.url(for: request, appID: appID)
        let hrefs = try await collectHrefs(at: url)
        let ids = WorkshopPublicIDExtractor.publishedFileIDs(fromHrefs: hrefs)
        guard !ids.isEmpty else {
            return WorkshopQueryPage(items: [], nextCursor: nil, totalAvailable: nil)
        }

        let details = await metadata.fetch(publishedFileIDs: ids)
        let items = ids.compactMap { id -> WorkshopQueryItem? in
            guard case .success(let entry)? = details[id] else { return nil }
            return Self.queryItem(from: entry)
        }
        // A page of ids that resolved to nothing is a failed lookup, not an
        // empty result set — surface it instead of showing "no matches".
        guard !items.isEmpty else { throw WorkshopQueryError.responseParseFailure }

        // The page has no machine-readable total; a full page means there is more.
        let nextCursor = ids.count >= WorkshopPublicBrowseURL.itemsPerPage
            ? String(request.page + 1)
            : nil
        return WorkshopQueryPage(items: items, nextCursor: nextCursor, totalAvailable: nil)
    }

    /// The keyless path's only metadata -> browse-item mapping. Static so the
    /// tag hand-off can be pinned without a `WKWebView`: `tags` feeds
    /// `isMatureRated`, and dropping it silently defeats the mature blur.
    nonisolated static func queryItem(from entry: SteamWorkshopMetadata) -> WorkshopQueryItem {
        WorkshopQueryItem(
            id: entry.publishedFileID,
            title: entry.title,
            shortDescription: entry.shortDescription,
            creatorID: nil,
            creatorPersonaName: nil,
            previewImageURL: entry.previewImageURL,
            fileSizeBytes: entry.fileSizeBytes,
            timeUpdated: entry.timeUpdated,
            subscriptionCount: nil,
            voteScore: nil,
            tags: entry.tags,
            visibility: entry.visibility,
            isBanned: entry.isBanned,
            steamCommunityURL: entry.steamCommunityURL
        )
    }

    // MARK: - Web view

    private func collectHrefs(at url: URL) async throws -> [String] {
        let view = existingOrNewWebView()
        try await load(url, in: view)
        let result = try? await view.evaluateJavaScript(WorkshopPublicIDExtractor.hrefCollectionScript)
        guard let hrefs = result as? [String] else { throw WorkshopQueryError.responseParseFailure }
        return hrefs
    }

    private func existingOrNewWebView() -> WKWebView {
        if let webView { return webView }
        let configuration = WKWebViewConfiguration()
        // Ephemeral: nothing is written to disk and no cookie from Safari or
        // the Steam client is ever visible to this view.
        configuration.websiteDataStore = .nonPersistent()
        configuration.suppressesIncrementalRendering = true
        let view = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 1280, height: 900),
            configuration: configuration
        )
        view.navigationDelegate = self
        webView = view
        return view
    }

    private func load(_ url: URL, in view: WKWebView) async throws {
        var timeout: Task<Void, Never>?
        defer { timeout?.cancel() }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let token = loadSlot.begin { continuation.resume(with: $0) }
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            mainNavigation = view.load(request)

            timeout = Task { [weak self] in
                try? await Task.sleep(for: Self.loadTimeout)
                guard !Task.isCancelled, let self else { return }
                // Only this load's timeout may stop the view — by the time a
                // stale one fires, a newer load already owns it.
                guard self.loadSlot.isCurrent(token) else { return }
                self.webView?.stopLoading()
                self.loadSlot.finish(token: token, .failure(WorkshopQueryError.timeout))
            }
        }
    }

    /// Settles the load that owns the slot; stale callbacks find no match.
    private func finishCurrentLoad(_ result: Result<Void, Error>) {
        guard let token = loadSlot.currentToken else { return }
        loadSlot.finish(token: token, result)
    }

    /// True only for the main document of the load in flight.
    private func isMainDocument(_ navigation: WKNavigation?) -> Bool {
        guard let navigation, let mainNavigation else { return false }
        return navigation === mainNavigation
    }

    private static func mapped(status: Int) -> WorkshopQueryError {
        status == 429 ? .rateLimited(retryAfter: nil) : .http(status: status)
    }

    private static func mapped(_ error: Error) -> WorkshopQueryError {
        guard let urlError = error as? URLError else { return .responseParseFailure }
        switch urlError.code {
        case .timedOut: return .timeout
        case .cancelled: return .cancelled
        case .notConnectedToInternet, .networkConnectionLost, .dnsLookupFailed: return .networkUnreachable
        default: return .networkUnreachable
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard !WorkshopPublicNavigationPolicy.allows(navigationAction.request.url) else {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        // Only the main document leaving the allow-list ends the search — the
        // page's third-party iframes get cancelled on every single load.
        if navigationAction.targetFrame?.isMainFrame == true {
            finishCurrentLoad(.failure(WorkshopQueryError.responseParseFailure))
        }
    }

    /// A rate-limit or challenge response still renders as HTML with no result
    /// links, which would read as "no matches"; the status separates them.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        guard navigationResponse.isForMainFrame,
              let http = navigationResponse.response as? HTTPURLResponse,
              !(200..<300).contains(http.statusCode)
        else {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        finishCurrentLoad(.failure(Self.mapped(status: http.statusCode)))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard isMainDocument(navigation) else { return }
        finishCurrentLoad(.success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard isMainDocument(navigation) else { return }
        finishCurrentLoad(.failure(Self.mapped(error)))
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        guard isMainDocument(navigation) else { return }
        finishCurrentLoad(.failure(Self.mapped(error)))
    }
}
#endif
