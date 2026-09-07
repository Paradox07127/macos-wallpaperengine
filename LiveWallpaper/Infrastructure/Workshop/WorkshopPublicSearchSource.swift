#if !LITE_BUILD
import Foundation
import LiveWallpaperCore

/// URL builder for Valve's public Workshop browse page — the zero-key search path. Parameters verified live against `steamcommunity.com` on 2026-08-29: `browsesort`, `days`, `searchtext`, `requiredtags[]` and `excludedtags[]` all filter server-side, `p` pages (disjoint result sets), and `numperpage` is ignored — the page returns up to 30 items.
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
            var items = [
                URLQueryItem(name: "appid", value: String(appID)),
                // This page defaults to a 9-item preview grid; unlike the
                // browse page it does honour `numperpage`.
                URLQueryItem(name: "numperpage", value: String(itemsPerPage)),
                URLQueryItem(name: "p", value: String(request.page))
            ]
            // Honoured here too, and several AND (verified live 2026-09-07:
            // `Video` kept 4/4, `Scene` 0/4, `Video`+`Abstract` 3/4).
            items += request.requiredTagsIncludingMiscellaneous.map { URLQueryItem(name: "requiredtags[]", value: $0) }
            components.percentEncodedQueryItems = WorkshopQueryService.percentEncodedQueryItems(items)
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
        if request.searchTextTarget != .all {
            items.append(URLQueryItem(name: "search_text_target", value: String(request.searchTextTarget.rawValue)))
        }
        if let days = request.days {
            items.append(URLQueryItem(name: "days", value: String(days)))
        }
        // Several `requiredtags[]` are all-of on the page, which is what the
        // feature tags mean.
        items += request.requiredTagsIncludingMiscellaneous.map { URLQueryItem(name: "requiredtags[]", value: $0) }
        items += request.excludedTags.map { URLQueryItem(name: "excludedtags[]", value: $0) }

        var components = URLComponents(string: base)!
        components.percentEncodedQueryItems = WorkshopQueryService.percentEncodedQueryItems(items)
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

/// Fallback id source when the SSR payload is unusable. Titles, previews and
/// counts then come from `GetPublishedFileDetails`, so this path's whole
/// dependency on Valve's markup is the details-page URL shape.
enum WorkshopPublicIDExtractor {

    static func publishedFileIDs(fromHTML html: String) -> [UInt64] {
        publishedFileIDs(fromHrefs: hrefs(inHTML: html))
    }

    /// The result anchors are in the served markup — the browse page is server-rendered, so nothing has to run scripts to see them (verified 2026-08-29: a plain GET returns all 30 ids).
    /// Values stay HTML-escaped (`?id=123&amp;searchtext=…`); harmless because `id` is Valve's first query parameter, so an escaped separator only mangles the parameter names after it.
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

/// Zero-key Workshop search: one cookie-free GET of Valve's public browse page,
/// read through its SSR payload (`WorkshopPublicBrowsePayload`). When that
/// payload is missing, unreadable or answers another request, the page falls
/// back to harvesting published-file ids from the result anchors and resolving
/// them through the key-free `GetPublishedFileDetails` batch endpoint.
@MainActor
final class WorkshopPublicSearchSource {

    private let metadata: SteamWorkshopMetadataService
    private let session: URLSession
    private let appID: Int
    /// Same disk cache the keyed path uses: one keyless page costs ~0.7 MB of
    /// HTML plus a details POST, so paging back to page 1 must not pay it again.
    private let cache: WorkshopQueryCache
    private let retryPolicy: WorkshopRetryPolicy
    private var inflight: [String: Task<WorkshopQueryPage, Error>] = [:]

    /// The browse page is ~0.7 MB of HTML; this only has to bound a hostile
    /// response, not a legitimate one.
    static let maxResponseBytes = 8 * 1024 * 1024

    init(
        metadata: SteamWorkshopMetadataService = SteamWorkshopMetadataService(),
        session: URLSession = WorkshopPublicSearchSource.defaultSession(),
        appID: Int = WorkshopQueryService.wallpaperEngineAppID,
        cache: WorkshopQueryCache = WorkshopQueryCache(),
        retryPolicy: WorkshopRetryPolicy = WorkshopRetryPolicy()
    ) {
        self.metadata = metadata
        self.session = session
        self.appID = appID
        self.cache = cache
        self.retryPolicy = retryPolicy
    }

    /// Keyless pages need no per-account namespace on the cache key — there is
    /// no account — so the canonical request hash is the key as it stands.
    func fetch(_ request: WorkshopQueryRequest) async throws -> WorkshopQueryPage {
        let cacheKey = WorkshopQueryCacheKey.canonical(request)
        if let task = inflight[cacheKey] {
            return try await task.value
        }
        // The cache read happens inside the task, not before it: awaiting first
        // would let a second caller past the `inflight` check and issue its own
        // page fetch.
        let task = Task { [weak self] () -> WorkshopQueryPage in
            guard let self else { throw CancellationError() }
            if let cached = await cache.read(forKey: cacheKey) {
                return cached
            }
            let page = try await fetchFromNetwork(request)
            await cache.write(page, forKey: cacheKey)
            return page
        }
        inflight[cacheKey] = task
        defer { inflight[cacheKey] = nil }
        return try await task.value
    }

    private func fetchFromNetwork(_ request: WorkshopQueryRequest) async throws -> WorkshopQueryPage {
        let url = WorkshopPublicBrowseURL.url(for: request, appID: appID)
        let html = try await loadHTML(at: url)
        // The creator page is not the browse page: nothing in a `workshop_browse`
        // query could be checked against the creator, so it is never adopted.
        if request.creatorSteamID == nil {
            do {
                let ssr = try WorkshopPublicBrowsePayload.page(fromHTML: html, matching: request, appID: appID)
                return WorkshopQueryPage(
                    items: ssr.items,
                    nextCursor: request.page < ssr.totalPages ? String(request.page + 1) : nil,
                    totalAvailable: ssr.totalCount,
                    sourceItemCount: ssr.sourceItemCount,
                    totalPages: ssr.totalPages
                )
            } catch let failure as WorkshopPublicBrowsePayload.ParseFailure {
                switch failure {
                // The page answered another request: its anchors are that
                // other page's items, so harvesting them would show and cache
                // them under this page's number.
                case .identityMismatch, .resultNotOK:
                    Logger.notice(
                        "Workshop browse page SSR payload not usable (\(failure)); not adopting this page",
                        category: .workshop
                    )
                    throw WorkshopQueryError.responseParseFailure
                case .markerNotFound, .malformedLiteral, .malformedJSON, .browseQueryNotFound:
                    Logger.notice(
                        "Workshop browse page SSR payload not usable (\(failure)); falling back to id harvesting",
                        category: .workshop
                    )
                }
            }
        }
        return try await harvestedPage(fromHTML: html, request: request)
    }

    /// The pre-SSR path: ids from the result anchors, everything else from
    /// `GetPublishedFileDetails`.
    private func harvestedPage(fromHTML html: String, request: WorkshopQueryRequest) async throws -> WorkshopQueryPage {
        let ids = WorkshopPublicIDExtractor.publishedFileIDs(fromHTML: html)
        // A same-host 200 with no result anchors is a challenge or login page,
        // not an empty result set — unless the page itself says it is empty.
        guard !ids.isEmpty else {
            guard html.contains(Self.emptyCreatorPageMarker) else { throw WorkshopQueryError.responseParseFailure }
            return WorkshopQueryPage(items: [], nextCursor: nil, totalAvailable: nil, sourceItemCount: 0, totalPages: nil)
        }

        let details: [UInt64: Result<SteamWorkshopMetadata, SteamWorkshopMetadataError>]
        do {
            let response = try await retryPolicy.run(host: SteamWorkshopMetadataService.endpoint.host() ?? "") { [metadata] in
                try await metadata.post(publishedFileIDs: ids)
            }
            details = SteamWorkshopMetadataService.results(from: response, requestedIDs: ids)
        } catch let urlError as URLError {
            throw Self.mapped(urlError)
        } catch let error as SteamWorkshopMetadataError {
            throw Self.mapped(error)
        } catch is CancellationError {
            throw WorkshopQueryError.cancelled
        }
        var items: [WorkshopQueryItem] = []
        for id in ids {
            switch details[id] {
            case let .success(entry)?:
                items.append(Self.queryItem(from: entry))
            // Permanently invisible on Valve's side; the page is complete
            // without it — even when that leaves the page empty.
            case .failure(.itemNotFound)?, .failure(.itemPrivate)?, .failure(.itemBanned)?, .failure(.schemaMismatch)?:
                continue
            // Transient (`.unknown` carries any other result code): an
            // incomplete page must not be cached as a complete one.
            case let .failure(error)?:
                throw Self.mapped(error)
            case nil:
                throw WorkshopQueryError.responseParseFailure
            }
        }

        return WorkshopQueryPage(
            items: items,
            nextCursor: Self.nextCursor(after: request.page, idCount: ids.count),
            totalAvailable: nil,
            sourceItemCount: ids.count,
            totalPages: nil
        )
    }

    private static func mapped(_ error: SteamWorkshopMetadataError) -> WorkshopQueryError {
        switch error {
        case .networkUnreachable: .networkUnreachable
        case .timeout: .timeout
        // Not `.unauthorized`: that reads as "Steam rejected the key", and
        // there is no key on this path.
        case .unauthorized: .http(status: 403)
        case let .http(status): .http(status: status)
        case let .rateLimited(retryAfter): .rateLimited(retryAfter: retryAfter)
        case .cancelled: .cancelled
        case .invalidInput, .responseParseFailure, .schemaMismatch, .itemPrivate, .itemBanned, .itemNotFound, .unknown:
            .responseParseFailure
        }
    }

    /// The creator page (`myworkshopfiles`, legacy markup, never carries the
    /// SSR payload) renders past its last page — or a creator with nothing
    /// public — as this empty-state container (verified live 2026-09-07 at
    /// `p=999`). The browse page needs no marker: its SSR payload says "no
    /// matches" itself.
    nonisolated static let emptyCreatorPageMarker = "id=\"no_items\""

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
            rawTitle: entry.title.isEmpty ? nil : entry.title,
            shortDescription: entry.shortDescription,
            creatorID: entry.creatorID,
            creatorPersonaName: nil,
            previewImageURL: entry.previewImageURL,
            fileSizeBytes: entry.fileSizeBytes,
            timeUpdated: entry.timeUpdated,
            subscriptionCount: entry.subscriptionCount,
            viewCount: entry.viewCount,
            favoriteCount: entry.favoriteCount,
            // Keyless `GetPublishedFileDetails` carries no vote data at all, so
            // the rating pill stays hidden rather than showing a made-up score.
            rating: nil,
            timeCreated: entry.timeCreated,
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
        let http: HTTPURLResponse
        do {
            (data, http) = try await retryPolicy.run(host: url.host() ?? "") { [session, request] in
                let body: Data
                let response: URLResponse
                do {
                    (body, response) = try await BoundedNetworkFetch.fetch(request, session: session, byteCap: Self.maxResponseBytes)
                } catch is BoundedNetworkFetch.ResponseTooLarge {
                    throw WorkshopQueryError.responseParseFailure
                }
                guard let http = response as? HTTPURLResponse else {
                    throw WorkshopQueryError.responseParseFailure
                }
                return (body, http)
            }
        } catch let urlError as URLError {
            throw Self.mapped(urlError)
        } catch is CancellationError {
            throw WorkshopQueryError.cancelled
        }

        // A challenge response still renders as HTML with no result links,
        // which would read as "no matches"; the status separates them (a 429
        // never gets here: the policy throws it as `.rateLimited`). Likewise a
        // redirect off the allow-list (login/interstitial) is a retriable
        // failure, not an empty result set.
        guard (200..<300).contains(http.statusCode) else {
            throw WorkshopQueryError.http(status: http.statusCode)
        }
        guard WorkshopPublicNavigationPolicy.allows(http.url) else {
            throw WorkshopQueryError.responseParseFailure
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw WorkshopQueryError.responseParseFailure
        }
        return html
    }

    private static func mapped(_ error: URLError) -> WorkshopQueryError {
        switch error.code {
        case .timedOut: .timeout
        case .cancelled: .cancelled
        case .notConnectedToInternet, .networkConnectionLost, .dnsLookupFailed: .networkUnreachable
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot,
             .clientCertificateRejected, .appTransportSecurityRequiresSecureConnection:
            .secureConnectionFailed
        // Not `networkUnreachable`: this branch has established nothing about
        // whether Steam is reachable.
        default: .networkFailure(code: error.errorCode)
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
