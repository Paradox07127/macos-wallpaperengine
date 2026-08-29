#if !LITE_BUILD
import Foundation

/// URL builder for Valve's public Workshop browse page — the zero-key search
/// path. Parameters verified live against `steamcommunity.com` on 2026-08-29:
/// `browsesort`, `days`, `searchtext`, `requiredtags[]` and `excludedtags[]`
/// all filter server-side, `p` pages (disjoint result sets), and `numperpage`
/// is ignored — the page returns up to 30 items.
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

    static func publishedFileIDs(fromHTML html: String) -> [UInt64] {
        publishedFileIDs(fromHrefs: hrefs(inHTML: html))
    }

    /// The result anchors are in the served markup — the browse page is
    /// server-rendered, so nothing has to run scripts to see them (verified
    /// 2026-08-29: a plain GET returns all 30 ids).
    ///
    /// Values stay HTML-escaped (`?id=123&amp;searchtext=…`); harmless because
    /// `id` is Valve's first query parameter, so an escaped separator only
    /// mangles the parameter names after it.
    static func hrefs(inHTML html: String) -> [String] {
        html.matches(of: /href="(https:\/\/[^"\s]*filedetails\/\?id=[^"]*)"/)
            .map { String($0.1) }
    }

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

/// Host allow-list for the keyless path: the page we fetch, and the detail
/// links we accept ids from.
enum WorkshopPublicNavigationPolicy {
    private static let host = "steamcommunity.com"

    static func allows(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", let host = url.host()?.lowercased() else { return false }
        return host == Self.host || host.hasSuffix("." + Self.host)
    }
}

/// Zero-key Workshop search: one cookie-free GET of Valve's public browse page
/// to harvest published-file ids, which are then resolved through the key-free
/// `GetPublishedFileDetails` batch endpoint.
@MainActor
final class WorkshopPublicSearchSource {

    private let metadata: SteamWorkshopMetadataService
    private let session: URLSession
    private let appID: Int

    /// The browse page is ~0.7 MB of HTML; this only has to bound a hostile
    /// response, not a legitimate one.
    static let maxResponseBytes = 8 * 1024 * 1024

    init(
        metadata: SteamWorkshopMetadataService = SteamWorkshopMetadataService(),
        session: URLSession = WorkshopPublicSearchSource.defaultSession(),
        appID: Int = WorkshopQueryService.wallpaperEngineAppID
    ) {
        self.metadata = metadata
        self.session = session
        self.appID = appID
    }

    func fetch(_ request: WorkshopQueryRequest) async throws -> WorkshopQueryPage {
        let url = WorkshopPublicBrowseURL.url(for: request, appID: appID)
        let html = try await loadHTML(at: url)
        let ids = WorkshopPublicIDExtractor.publishedFileIDs(fromHTML: html)
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

        return WorkshopQueryPage(
            items: items,
            nextCursor: Self.nextCursor(after: request.page, idCount: ids.count),
            totalAvailable: nil
        )
    }

    /// The page publishes no machine-readable total, so only an empty page ends
    /// the result set. Comparing the id count against 30 instead cut browsing
    /// short: a full page legitimately returns 29 (verified 2026-08-29, p=2).
    /// The 1000-page ceiling is Steam's and is enforced by `BrowseViewModel`.
    nonisolated static func nextCursor(after page: Int, idCount: Int) -> String? {
        idCount > 0 ? String(page + 1) : nil
    }

    /// The keyless path's only metadata -> browse-item mapping. `tags` feeds
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
            subscriptionCount: entry.subscriptionCount,
            // Keyless `GetPublishedFileDetails` carries no vote data at all, so
            // the rating pill stays hidden rather than showing a made-up score.
            voteScore: nil,
            tags: entry.tags,
            visibility: entry.visibility,
            isBanned: entry.isBanned,
            steamCommunityURL: entry.steamCommunityURL
        )
    }

    // MARK: - Page fetch

    private func loadHTML(at url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.setValue("text/html", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await BoundedNetworkFetch.fetch(
                request,
                session: session,
                byteCap: Self.maxResponseBytes
            )
        } catch let urlError as URLError {
            throw Self.mapped(urlError)
        } catch is BoundedNetworkFetch.ResponseTooLarge {
            throw WorkshopQueryError.responseParseFailure
        }

        guard let http = response as? HTTPURLResponse else {
            throw WorkshopQueryError.responseParseFailure
        }
        // A rate-limit or challenge response still renders as HTML with no
        // result links, which would read as "no matches"; the status separates
        // them. Likewise a redirect off the allow-list (login/interstitial) is
        // a retriable failure, not an empty result set.
        guard (200..<300).contains(http.statusCode) else {
            throw Self.mapped(status: http.statusCode)
        }
        guard WorkshopPublicNavigationPolicy.allows(http.url) else {
            throw WorkshopQueryError.responseParseFailure
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw WorkshopQueryError.responseParseFailure
        }
        return html
    }

    private static func mapped(status: Int) -> WorkshopQueryError {
        status == 429 ? .rateLimited(retryAfter: nil) : .http(status: status)
    }

    private static func mapped(_ error: URLError) -> WorkshopQueryError {
        switch error.code {
        case .timedOut: return .timeout
        case .cancelled: return .cancelled
        case .notConnectedToInternet, .networkConnectionLost, .dnsLookupFailed: return .networkUnreachable
        default: return .networkUnreachable
        }
    }

    // MARK: - URLSession factory

    /// Deliberately cookie-free: the browse page needs no session, and sending
    /// one would tie these searches to the user's Steam login.
    private static func defaultSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        config.httpAdditionalHeaders = [
            "User-Agent": "Loomscreen/Workshop (+https://loomscreen.app/)"
        ]
        return URLSession(configuration: config)
    }
}
#endif
