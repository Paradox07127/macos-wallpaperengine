#if !LITE_BUILD
import CryptoKit
import Foundation
import LiveWallpaperCore

enum WorkshopSortMode: String, Sendable, Equatable, Hashable, CaseIterable, Identifiable {
    case mostPopular
    case topRated
    case newest
    case lastUpdated
    case mostSubscribed
    case search

    var id: String { rawValue }

    var queryTypeCode: Int {
        switch self {
        case .mostPopular: return 3
        case .topRated: return 0
        case .newest: return 1
        case .lastUpdated: return 21
        case .mostSubscribed: return 9
        case .search: return 12
        }
    }
}

enum WorkshopTimeFrame: String, Sendable, Equatable, Hashable, CaseIterable, Identifiable {
    case today
    case oneWeek
    case thirtyDays
    case threeMonths
    case sixMonths
    case oneYear
    case allTime

    var id: String { rawValue }

    var days: Int? {
        switch self {
        case .today: return 1
        case .oneWeek: return 7
        case .thirtyDays: return 30
        case .threeMonths: return 90
        case .sixMonths: return 180
        case .oneYear: return 365
        case .allTime: return nil
        }
    }
}

/// Steam's `search_text_target`: which text fields a search matches. Same
/// name and codes on the public page and the Web API (measured 2026-09-07).
enum WorkshopSearchTextTarget: Int, Sendable, Equatable, Hashable, CaseIterable, Identifiable {
    case all = 0
    case titleOnly = 1
    case descriptionOnly = 2

    var id: Int {
        rawValue
    }
}

struct WorkshopQueryRequest: Equatable, Hashable, Sendable {
    let sort: WorkshopSortMode
    let searchText: String
    /// `.all` whenever `searchText` is empty: the target is meaningless without
    /// a text, and normalising it keeps the default browse on one cache key.
    let searchTextTarget: WorkshopSearchTextTarget
    /// 1-based page index. Steam's QueryFiles supports BOTH cursor and `page`; using `page` lets us jump to an arbitrary page and show "Page N of M" (cursor can only walk forward).
    /// Steam's docs cap `page` at 1000 — beyond that it returns empty pages; deeper pagination needs the cursor, which we don't wire up.
    let page: Int
    let numPerPage: Int
    let language: String?
    let timeFrame: WorkshopTimeFrame
    let days: Int?
    let requiredTags: [String]
    /// Steam: "If true, then items must have all the tags specified, otherwise
    /// they must have at least one of the tags." No default is documented, so
    /// `apiQueryItems` always states it when there are required tags.
    let matchAllTags: Bool
    let excludedTags: [String]
    /// Steam's Miscellaneous facet (Approved, HDR, …): every one is required.
    /// Kept apart from `requiredTags` because the genre facet there is any-of,
    /// and the two only combine through `taggroups` — see `usesTagGroups`.
    let miscellaneousTags: [String]
    let returnPreviews: Bool
    let returnTags: Bool
    let returnMetadata: Bool
    let returnShortDescription: Bool
    /// When set, the query lists this creator's published files via `IPublishedFileService/GetUserFiles` instead of the global `QueryFiles` browse.
    /// GetUserFiles has `sortmethod`/`requiredtags`/`excludedtags` fields (we wire up the default sort, `requiredtags` for the Miscellaneous facet and `excludedtags`) but no text search, so `searchText` can't apply in this mode.
    let creatorSteamID: String?
    /// When set, restricts the query to published files that reference this
    /// item. Steam's own wording for `child_publishedfileid` is "Find all items
    /// that reference the given item", which is how a wallpaper's presets are
    /// found: a preset declares the wallpaper it restyles as its dependency.
    let childPublishedFileID: UInt64?

    init(
        sort: WorkshopSortMode,
        searchText: String = "",
        searchTextTarget: WorkshopSearchTextTarget = .all,
        page: Int = 1,
        numPerPage: Int = 50,
        language: String? = nil,
        timeFrame: WorkshopTimeFrame? = nil,
        requiredTags: [String] = [],
        matchAllTags: Bool = true,
        excludedTags: [String] = [],
        miscellaneousTags: [String] = [],
        returnPreviews: Bool = true,
        returnTags: Bool = true,
        returnMetadata: Bool = true,
        returnShortDescription: Bool = true,
        creatorSteamID: String? = nil,
        childPublishedFileID: UInt64? = nil
    ) {
        let normalizedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Steam's query_type and search_text are independent, so a search keeps
        // the caller's sort. Only relevance (query_type=12) needs text to rank
        // against; without it (the pinned-tag path reuses the browse sort but
        // drops the search text) fall back to Top Rated.
        let effectiveSort: WorkshopSortMode = (sort == .search && normalizedSearch.isEmpty) ? .topRated : sort
        // `days` only exists for the trend sort (measured 2026-09-07). There
        // the Web API reads an omitted `days` as 1, and the page has no
        // "trend, all time" — its menu defaults to seven days — so Most
        // Popular always states a window and All Time becomes that default.
        let effectiveTimeFrame: WorkshopTimeFrame
        if effectiveSort == .mostPopular {
            let requested = timeFrame ?? .oneWeek
            effectiveTimeFrame = requested == .allTime ? .oneWeek : requested
        } else {
            effectiveTimeFrame = .allTime
        }

        self.sort = effectiveSort
        self.searchText = normalizedSearch
        self.searchTextTarget = normalizedSearch.isEmpty ? .all : searchTextTarget
        self.page = max(1, page)
        self.numPerPage = min(max(numPerPage, 1), 100)
        self.language = Self.canonicalLanguage(language)
        self.timeFrame = effectiveTimeFrame
        self.days = effectiveTimeFrame.days
        self.requiredTags = Self.canonicalTags(requiredTags)
        self.matchAllTags = matchAllTags
        self.excludedTags = Self.canonicalTags(excludedTags)
        self.miscellaneousTags = Self.canonicalTags(miscellaneousTags)
        self.returnPreviews = returnPreviews
        self.returnTags = returnTags
        self.returnMetadata = returnMetadata
        self.returnShortDescription = returnShortDescription
        self.creatorSteamID = creatorSteamID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmptyWorkshopQuery
        self.childPublishedFileID = childPublishedFileID
    }

    private static func canonicalLanguage(_ language: String?) -> String? {
        guard let language else { return nil }
        let trimmed = language.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    /// Steam matches `requiredtags`/`excludedtags` against the item's EXACT display-name tags (e.g. `Scene`, `Anime`, `3840 x 2160`, `Dual 3840 x 1080`). Lower-casing them — as this used to — made every tag filter silently match nothing.
    /// So we only trim, de-duplicate, and sort (sorting just keeps the cache key stable; tag order is irrelevant to Steam).
    private static func canonicalTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        return tags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .sorted()
    }

    /// "Any of these genres AND each of these features" is only expressible
    /// as `taggroups` (a group is any-of, groups are all-of), and Steam only
    /// honours `taggroups` inside `input_json` on a keyed GET — the query-string
    /// array forms are ignored or 400 and POST is 405 (measured 2026-09-07).
    var usesTagGroups: Bool {
        !miscellaneousTags.isEmpty && !requiredTags.isEmpty && !matchAllTags
    }

    /// The Miscellaneous facet as the paths without `taggroups` take it: the
    /// public page and GetUserFiles only have `requiredtags`, where it joins
    /// the genre tags as one all-of list.
    var requiredTagsIncludingMiscellaneous: [String] {
        requiredTags + miscellaneousTags
    }

    func apiQueryItems(apiKey: String, appID: Int) -> [URLQueryItem] {
        if usesTagGroups {
            return [
                URLQueryItem(name: "key", value: apiKey),
                URLQueryItem(name: "input_json", value: inputJSON(appID: appID)),
            ]
        }
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "key", value: apiKey),
            URLQueryItem(name: "appid", value: String(appID)),
            URLQueryItem(name: "numperpage", value: String(numPerPage)),
            URLQueryItem(name: "query_type", value: String(sort.queryTypeCode)),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "return_previews", value: Self.steamBool(returnPreviews)),
            URLQueryItem(name: "return_tags", value: Self.steamBool(returnTags)),
            URLQueryItem(name: "return_metadata", value: Self.steamBool(returnMetadata)),
            URLQueryItem(name: "return_short_description", value: Self.steamBool(returnShortDescription)),
            URLQueryItem(name: "return_vote_data", value: "true"),
            // Not `return_details`: it drops `vote_data` and `short_description` (verified 2026-09-07).
            URLQueryItem(name: "return_children", value: "true"),
        ]
        if !searchText.isEmpty {
            queryItems.append(URLQueryItem(name: "search_text", value: searchText))
        }
        if searchTextTarget != .all {
            queryItems.append(URLQueryItem(name: "search_text_target", value: String(searchTextTarget.rawValue)))
        }
        if let childPublishedFileID {
            queryItems.append(URLQueryItem(
                name: "child_publishedfileid", value: String(childPublishedFileID)
            ))
        }
        if let language {
            queryItems.append(URLQueryItem(name: "language", value: language))
        }
        if let days {
            queryItems.append(URLQueryItem(name: "days", value: String(days)))
        }
        // Feature tags alone ride on the undocumented default, which is all-of
        // (measured 2026-09-07); with a pinned tag they join its `match_all_tags=true`.
        for (index, tag) in (requiredTags + miscellaneousTags).enumerated() {
            queryItems.append(URLQueryItem(name: "requiredtags[\(index)]", value: tag))
        }
        if !requiredTags.isEmpty {
            queryItems.append(URLQueryItem(name: "match_all_tags", value: Self.steamBool(matchAllTags)))
        }
        for (index, tag) in excludedTags.enumerated() {
            queryItems.append(URLQueryItem(name: "excludedtags[\(index)]", value: tag))
        }
        return queryItems
    }

    /// The whole query as `input_json`: the same values `apiQueryItems` would
    /// put in the query string, plus `taggroups` in place of `requiredtags`.
    private func inputJSON(appID: Int) -> String {
        let input = QueryFilesInput(
            appid: appID,
            numperpage: numPerPage,
            query_type: sort.queryTypeCode,
            page: page,
            return_previews: returnPreviews,
            return_tags: returnTags,
            return_metadata: returnMetadata,
            return_short_description: returnShortDescription,
            search_text: searchText.isEmpty ? nil : searchText,
            search_text_target: searchTextTarget == .all ? nil : searchTextTarget.rawValue,
            child_publishedfileid: childPublishedFileID.map(String.init),
            language: language,
            days: days,
            excludedtags: excludedTags.isEmpty ? nil : excludedTags,
            taggroups: [QueryFilesInput.TagGroup(tags: requiredTags)]
                + miscellaneousTags.map { QueryFilesInput.TagGroup(tags: [$0]) }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(input)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    private struct QueryFilesInput: Encodable {
        let appid: Int
        let numperpage: Int
        let query_type: Int
        let page: Int
        let return_previews: Bool
        let return_tags: Bool
        let return_metadata: Bool
        let return_short_description: Bool
        let return_vote_data = true
        let return_children = true
        let search_text: String?
        let search_text_target: Int?
        let child_publishedfileid: String?
        let language: String?
        let days: Int?
        let excludedtags: [String]?
        let taggroups: [TagGroup]

        struct TagGroup: Encodable {
            let tags: [String]
        }
    }

    private static func steamBool(_ value: Bool) -> String {
        value ? "true" : "false"
    }
}

/// The two browse paths rate in different units: keyed `vote_data.score` is a
/// 0–1 ratio, the keyless page's `star_rating` is already a 1–5 integer.
enum WorkshopRating: Equatable, Sendable, Codable {
    case score(Double, votesUp: Int, votesDown: Int)
    case stars(Int, totalVotes: Int)

    var starsOutOfFive: Double {
        switch self {
        case let .score(score, _, _):
            min(max(score * 5, 0), 5)
        case let .stars(stars, _):
            Double(stars)
        }
    }

    var totalVotes: Int {
        switch self {
        case let .score(_, votesUp, votesDown):
            let (sum, overflow) = votesUp.addingReportingOverflow(votesDown)
            return overflow ? Int.max : sum
        case let .stars(_, totalVotes):
            return totalVotes
        }
    }
}

struct WorkshopQueryItem: Identifiable, Sendable, Equatable {
    let id: UInt64
    /// The title as Steam sent it; `nil` when the item has none. Kept raw so
    /// the cache never stores one app language's `title` fallback.
    let rawTitle: String?
    let shortDescription: String
    /// Creator's SteamID64 (from the query) — resolved to `creatorPersonaName`
    /// via a batched GetPlayerSummaries lookup.
    let creatorID: String?
    var creatorPersonaName: String?
    /// Already filtered through `WorkshopCDNHostAllowList`. Load via
    /// `WorkshopPreviewImageLoader`.
    let previewImageURL: URL?
    let fileSizeBytes: UInt64?
    let timeUpdated: Date?
    let subscriptionCount: Int?
    var viewCount: Int? = nil
    var favoriteCount: Int? = nil
    let rating: WorkshopRating?
    var timeCreated: Date?
    var commentCount: Int?
    /// `children[].publishedfileid` in `sortorder`: what a Preset restyles.
    var requiredItemIDs: [UInt64] = []
    let tags: [String]
    let visibility: SteamWorkshopMetadata.Visibility
    let isBanned: Bool
    let steamCommunityURL: URL

    var title: String {
        Self.displayTitle(rawTitle, id: id)
    }

    /// Both browse paths receive untitled items; the id is the only thing that
    /// tells two of them apart on the grid.
    static func displayTitle(_ title: String?, id: UInt64) -> String {
        if let title, !title.isEmpty {
            return title
        }
        return String(
            localized: "Workshop item \(id)",
            bundle: .appLanguage, comment: "Workshop paste row title when only a published file ID is known."
        )
    }
}

struct WorkshopQueryPage: Sendable, Equatable {
    let items: [WorkshopQueryItem]
    let nextCursor: String?
    let totalAvailable: Int?
    /// Entries Steam returned for this page before any client-side drop
    /// (shells, banned, Application/Preset): what the pager reasons about.
    let sourceItemCount: Int
    /// Steam's page count: `total_pages` on the keyless page, `ceil(total /
    /// numperpage)` on QueryFiles; `nil` when the source states no total.
    let totalPages: Int?
}

enum WorkshopQueryError: Error, Equatable, Sendable {
    case missingAPIKey
    /// A key is stored, but macOS refused to hand it over (ACL prompt declined,
    /// or a locked keychain) — distinct from having no key at all.
    case keychainAccessDenied
    /// A key is stored and macOS allowed the read, but what came back was
    /// unusable. Also distinct from having no key: pasting a new one is the
    /// remedy, going to Steam for a first key is not.
    case keychainUnreadable
    case unauthorized
    case keyDisabled
    case rateLimited(retryAfter: TimeInterval?)
    case networkUnreachable
    /// TLS refused: an intercepting proxy, a clock far out of date, an
    /// untrusted root. Distinct because "check your connection" sends the
    /// reader to look at a connection that is working.
    case secureConnectionFailed
    /// A transport failure with no established meaning. Carries the code
    /// rather than asserting a cause we have not determined.
    case networkFailure(code: Int)
    case timeout
    case http(status: Int)
    case responseParseFailure
    case schemaMismatch
    case cancelled
}

enum WorkshopQueryCacheKey {
    static func canonical(_ request: WorkshopQueryRequest) -> String {
        sha256Hex(of: canonicalRequestData(request))
    }

    private static func canonicalRequestData(_ request: WorkshopQueryRequest) -> Data {
        let canonical = CanonicalRequest(
            appid: WorkshopQueryService.wallpaperEngineAppID,
            queryType: request.sort.queryTypeCode,
            searchText: request.searchText,
            searchTextTarget: request.searchTextTarget.rawValue,
            page: request.page,
            numPerPage: request.numPerPage,
            language: request.language,
            timeFrame: request.timeFrame.rawValue,
            days: request.days,
            requiredTags: request.requiredTags,
            matchAllTags: request.matchAllTags,
            excludedTags: request.excludedTags,
            miscellaneousTags: request.miscellaneousTags,
            returnPreviews: request.returnPreviews,
            returnTags: request.returnTags,
            returnMetadata: request.returnMetadata,
            returnShortDescription: request.returnShortDescription,
            creatorSteamID: request.creatorSteamID,
            childPublishedFileID: request.childPublishedFileID
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(canonical)) ?? Data()
    }

    private static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private struct CanonicalRequest: Encodable {
        let appid: Int
        let queryType: Int
        let searchText: String
        let searchTextTarget: Int
        let page: Int
        let numPerPage: Int
        let language: String?
        let timeFrame: String
        let days: Int?
        let requiredTags: [String]
        let matchAllTags: Bool
        let excludedTags: [String]
        let miscellaneousTags: [String]
        let returnPreviews: Bool
        let returnTags: Bool
        let returnMetadata: Bool
        let returnShortDescription: Bool
        let creatorSteamID: String?
        let childPublishedFileID: UInt64?

        private enum CodingKeys: String, CodingKey {
            case appid
            case queryType = "query_type"
            case searchText = "search_text"
            case searchTextTarget = "search_text_target"
            case page
            case numPerPage = "numperpage"
            case language
            case timeFrame = "time_frame"
            case days
            case requiredTags = "requiredtags"
            case matchAllTags = "match_all_tags"
            case excludedTags = "excludedtags"
            case miscellaneousTags = "miscellaneous_tags"
            case returnPreviews = "return_previews"
            case returnTags = "return_tags"
            case returnMetadata = "return_metadata"
            case returnShortDescription = "return_short_description"
            case creatorSteamID = "creator_steamid"
            case childPublishedFileID = "child_publishedfileid"
        }
    }
}

actor WorkshopQueryService {

    static let wallpaperEngineAppID = 431960

    private static let queryFilesEndpoint = URL(string: "https://api.steampowered.com/IPublishedFileService/QueryFiles/v1/")!
    private static let getUserFilesEndpoint = URL(string: "https://api.steampowered.com/IPublishedFileService/GetUserFiles/v1/")!
    private static let supportedAPIListEndpoint = URL(string: "https://api.steampowered.com/ISteamWebAPIUtil/GetSupportedAPIList/v1/")!
        /// Covers QueryFiles (up to 100 items with previews/descriptions),
        /// GetUserFiles, GetPlayerSummaries, and GetSupportedAPIList — one generous
        /// cap for all four endpoints, well over their typical multi-KB payloads.
        private static let maxResponseBytes = 8 * 1024 * 1024
    private static let tokenCapacity = 5.0
    private static let tokenRefillPerSecond = 1.0
    private static let apiKeyPattern = #"^[A-Fa-f0-9]{32}$"#

    private let keychain: WorkshopKeychainStore
    private let session: URLSession
    private let cache: WorkshopQueryCache
    private let retryPolicy: WorkshopRetryPolicy
    /// Bumps the Browse ribbon's "N API requests today" tally, once per HTTP
    /// request this actor issues. A closure rather than the `UserDefaults` it
    /// writes: that type is not `Sendable` and cannot cross into the actor.
    private let countIssuedRequest: @Sendable () -> Void
    private var inflight: [String: Task<WorkshopQueryPage, Error>] = [:]
    private var tokenBucket = tokenCapacity
    private var tokenRefilledAt = Date()
    /// Reports each keyed Valve verdict so `WorkshopServices` can surface a stored key that Valve later revoked: `false` only on an explicit auth rejection (401/403/disabled-key body), `true` on a successful keyed response.
    /// Network failures report nothing — offline must not mark a known-good key bad.
    private var authVerdictHandler: (@Sendable (Bool, String) -> Void)?

    init(
        keychain: WorkshopKeychainStore,
        cache: WorkshopQueryCache = WorkshopQueryCache(),
        session: URLSession = .workshopQuerySession(timeout: 20),
        retryPolicy: WorkshopRetryPolicy = WorkshopRetryPolicy(),
        countIssuedRequest: @escaping @Sendable () -> Void = { WorkshopRequestCounter.increment() }
    ) {
        self.keychain = keychain
        self.session = session
        self.cache = cache
        self.retryPolicy = retryPolicy
        self.countIssuedRequest = countIssuedRequest
    }

    func setAuthVerdictHandler(_ handler: @escaping @Sendable (_ accepted: Bool, _ keyFingerprint: String) -> Void) {
        authVerdictHandler = handler
    }

    static func keyFingerprint(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).prefix(8)
            .map { String(format: "%02x", $0) }.joined()
    }

    func fetch(_ request: WorkshopQueryRequest) async throws -> WorkshopQueryPage {
        // Load the key up front so both the cache and the in-flight map are
        // namespaced by it — a key swap mid-flight can't coalesce onto, or
        // serve, a prior account's results.
        let apiKey = try await loadAPIKey()
        let cacheKey = Self.namespacedCacheKey(WorkshopQueryCacheKey.canonical(request), apiKey: apiKey)
        if let task = inflight[cacheKey] {
            return try await task.value
        }
        let task = Task { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.fetchFromCacheOrNetwork(request, cacheKey: cacheKey, apiKey: apiKey)
        }
        inflight[cacheKey] = task
        do {
            let page = try await task.value
            inflight[cacheKey] = nil
            return page
        } catch {
            inflight[cacheKey] = nil
            throw error
        }
    }

    func validateAPIKey(_ key: String) async throws -> Bool {
        guard Self.isValidAPIKeyShape(key) else {
            throw WorkshopQueryError.unauthorized
        }
        var components = URLComponents(url: Self.supportedAPIListEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "key", value: key)]
        guard let url = components.url else {
            throw WorkshopQueryError.schemaMismatch
        }
        let (data, http) = try await get(url)

        switch http.statusCode {
        case 200:
            if Self.bodyContainsDisabledKeyHint(data) { throw WorkshopQueryError.keyDisabled }
            return true
        case 401:
            throw WorkshopQueryError.unauthorized
        case 403:
            throw Self.bodyContainsDisabledKeyHint(data) ? WorkshopQueryError.keyDisabled : WorkshopQueryError.unauthorized
        default:
            throw WorkshopQueryError.http(status: http.statusCode)
        }
    }

    private func loadAPIKey() async throws -> String {
        do {
            guard let storedKey = try await keychain.loadWebAPIKey() else {
                throw WorkshopQueryError.missingAPIKey
            }
            return storedKey
        } catch let error as WorkshopQueryError {
            throw error
        } catch WorkshopKeychainStore.WorkshopKeychainError.accessDenied {
            throw WorkshopQueryError.keychainAccessDenied
        } catch WorkshopKeychainStore.WorkshopKeychainError.malformedData {
            throw WorkshopQueryError.keychainUnreadable
        } catch WorkshopKeychainStore.WorkshopKeychainError.ioFailure {
            throw WorkshopQueryError.keychainUnreadable
        } catch WorkshopKeychainStore.WorkshopKeychainError.osStatus {
            throw WorkshopQueryError.keychainUnreadable
        } catch {
            throw WorkshopQueryError.missingAPIKey
        }
    }

    private func fetchFromCacheOrNetwork(_ request: WorkshopQueryRequest, cacheKey: String, apiKey: String) async throws -> WorkshopQueryPage {
        if let cached = await cache.read(forKey: cacheKey) {
            return cached
        }
        let page = try await performQuery(request, apiKey: apiKey)
        await cache.write(page, forKey: cacheKey)
        return page
    }

    /// Hashes the API key into the cache-key prefix so cache entries are
    /// isolated per Steam account.
    private static func namespacedCacheKey(_ base: String, apiKey: String) -> String {
        "\(keyFingerprint(apiKey))-\(base)"
    }

    private func performQuery(_ request: WorkshopQueryRequest, apiKey: String) async throws -> WorkshopQueryPage {
        let url = try buildQueryURL(for: request, apiKey: apiKey)
        Logger.info("Workshop query started: \(Self.redactedURLString(url))", category: .workshop)

        let (data, http) = try await get(url)

        if http.statusCode != 200 {
            let snippet = String(bytes: data.prefix(300), encoding: .utf8) ?? ""
            Logger.error("Workshop query HTTP \(http.statusCode): \(snippet)", category: .workshop)
        }

        switch http.statusCode {
        case 200:
            let page: WorkshopQueryPage
            do {
                page = try decodeQueryPage(
                    data, isBrowsePage: request.childPublishedFileID == nil, page: request.page, numPerPage: request.numPerPage
                )
            } catch let error as WorkshopQueryError where error == .keyDisabled {
                authVerdictHandler?(false, Self.keyFingerprint(apiKey))
                throw error
            }
            authVerdictHandler?(true, Self.keyFingerprint(apiKey))
            // Pairs with "Workshop query started" above: the gap between the
            // two lines is what the grid waits for. Creator personas are a
            // second round trip and are resolved after this hand-off.
            Logger.info("Workshop query page handed to caller: \(page.items.count) items", category: .workshop)
            return page
        case 401:
            authVerdictHandler?(false, Self.keyFingerprint(apiKey))
            throw WorkshopQueryError.unauthorized
        case 403:
            authVerdictHandler?(false, Self.keyFingerprint(apiKey))
            throw Self.bodyContainsDisabledKeyHint(data) ? WorkshopQueryError.keyDisabled : WorkshopQueryError.unauthorized
        default:
            throw WorkshopQueryError.http(status: http.statusCode)
        }
    }

    /// Second phase of `fetch`, called once the caller has the page: a
    /// `GetPlayerSummaries` batch keyed by SteamID64. Best-effort — failures
    /// leave the name unset and the UI omits the author line. The named page is
    /// written back over the cached one, so a later cache hit carries the names
    /// and needs no second lookup (which is why the caller passes the request).
    func resolveCreatorNames(for page: WorkshopQueryPage, request: WorkshopQueryRequest) async -> [String: String] {
        let ids = Set(page.items.filter { $0.creatorPersonaName == nil }.compactMap(\.creatorID))
            .filter { !$0.isEmpty }
        guard !ids.isEmpty, let apiKey = try? await loadAPIKey() else { return [:] }
        let names = await fetchPersonaNames(ids: Array(ids), apiKey: apiKey)
        guard !names.isEmpty else { return [:] }
        let updated = page.items.map { item -> WorkshopQueryItem in
            guard let id = item.creatorID, let name = names[id] else { return item }
            var copy = item
            copy.creatorPersonaName = name
            return copy
        }
        await cache.write(
            WorkshopQueryPage(
                items: updated,
                nextCursor: page.nextCursor,
                totalAvailable: page.totalAvailable,
                sourceItemCount: page.sourceItemCount,
                totalPages: page.totalPages
            ),
            forKey: Self.namespacedCacheKey(WorkshopQueryCacheKey.canonical(request), apiKey: apiKey)
        )
        return names
    }

    private func fetchPersonaNames(ids: [String], apiKey: String) async -> [String: String] {
        // GetPlayerSummaries caps at 100 SteamID64s per call.
        let batch = Array(ids.prefix(100))
        var components = URLComponents(string: "https://api.steampowered.com/ISteamUser/GetPlayerSummaries/v2/")!
        components.queryItems = [
            URLQueryItem(name: "key", value: apiKey),
            URLQueryItem(name: "steamids", value: batch.joined(separator: ","))
        ]
        guard let url = components.url else { return [:] }
        do {
            let (data, http) = try await get(url)
            guard http.statusCode == 200 else { return [:] }
            let envelope = try JSONDecoder().decode(PlayerSummariesEnvelope.self, from: data)
            var map: [String: String] = [:]
            for player in envelope.response.players {
                if let name = player.personaname?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                    map[player.steamid] = WorkshopDiagnosticRedactor.redact(name)
                }
            }
            return map
        } catch {
            return [:]
        }
    }

    /// Every GET this actor issues: through the retry policy (which owns the
    /// per-host cooldown), the token bucket and the request counter. The
    /// policy retries transport failures, 429 and 5xx; a 429 it cannot wait
    /// out is thrown as `.rateLimited`, so no 429 reaches a caller's switch.
    private func get(_ url: URL) async throws -> (data: Data, http: HTTPURLResponse) {
        do {
            return try await retryPolicy.run(host: url.host() ?? "") {
                try await self.acquireToken()

                var urlRequest = URLRequest(url: url)
                urlRequest.httpMethod = "GET"
                urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
                urlRequest.timeoutInterval = 20

                let body: Data
                let response: URLResponse
                do {
                    self.countIssuedRequest()
                    (body, response) = try await BoundedNetworkFetch.fetch(urlRequest, session: self.session, byteCap: Self.maxResponseBytes)
                } catch let error as URLError {
                    throw error
                } catch {
                    throw Self.mapNetworkError(error)
                }
                guard let http = response as? HTTPURLResponse else {
                    throw WorkshopQueryError.responseParseFailure
                }
                return (body, http)
            }
        } catch let error as WorkshopQueryError {
            throw error
        } catch {
            throw Self.mapNetworkError(error)
        }
    }

    private func buildQueryURL(for request: WorkshopQueryRequest, apiKey: String) throws -> URL {
        // Creator-scoped browse uses GetUserFiles: sortmethod and excludedtags
        // apply there, but it has no text search.
        if let creatorSteamID = request.creatorSteamID {
            return try Self.buildUserFilesURL(for: request, steamID: creatorSteamID, apiKey: apiKey)
        }
        return try Self.buildQueryFilesURL(for: request, apiKey: apiKey)
    }

    /// Static (nonisolated) so tests can assert the URL without the actor.
    static func buildQueryFilesURL(for request: WorkshopQueryRequest, apiKey: String) throws -> URL {
        var components = URLComponents(url: Self.queryFilesEndpoint, resolvingAgainstBaseURL: false)!
        components.percentEncodedQueryItems = Self.percentEncodedQueryItems(
            request.apiQueryItems(apiKey: apiKey, appID: Self.wallpaperEngineAppID)
        )
        guard let url = components.url else { throw WorkshopQueryError.schemaMismatch }
        return url
    }

    /// `URLComponents.queryItems` leaves `+` bare, which Steam reads as a
    /// space (in a search text, a tag, or inside `input_json` alike); encode
    /// everything but ASCII unreserved characters. Shared by every Workshop
    /// URL builder so the two paths encode one search the same way.
    static func percentEncodedQueryItems(_ items: [URLQueryItem]) -> [URLQueryItem] {
        items.map {
            URLQueryItem(
                name: $0.name.addingPercentEncoding(withAllowedCharacters: unreservedQueryCharacters) ?? $0.name,
                value: $0.value?.addingPercentEncoding(withAllowedCharacters: unreservedQueryCharacters)
            )
        }
    }

    private static let unreservedQueryCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"
    )

    /// Response shape matches `QueryFiles` (`response.publishedfiledetails` +
    /// `total`), so `decodeQueryPage` handles both.
    /// Static (nonisolated) so tests can assert the URL without the actor.
    static func buildUserFilesURL(for request: WorkshopQueryRequest, steamID: String, apiKey: String) throws -> URL {
        var components = URLComponents(url: Self.getUserFilesEndpoint, resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "key", value: apiKey),
            URLQueryItem(name: "steamid", value: steamID),
            URLQueryItem(name: "appid", value: String(Self.wallpaperEngineAppID)),
            // The protobuf default for CPublishedFile_GetUserFiles_Request —
            // stated explicitly so the URL says what order the page is in.
            URLQueryItem(name: "sortmethod", value: "lastupdated"),
            URLQueryItem(name: "numperpage", value: String(request.numPerPage)),
            URLQueryItem(name: "page", value: String(request.page)),
            URLQueryItem(name: "return_previews", value: Self.steamBool(request.returnPreviews)),
            URLQueryItem(name: "return_tags", value: Self.steamBool(request.returnTags)),
            URLQueryItem(name: "return_metadata", value: Self.steamBool(request.returnMetadata)),
            URLQueryItem(name: "return_short_description", value: Self.steamBool(request.returnShortDescription)),
            URLQueryItem(name: "return_vote_data", value: "true"),
            URLQueryItem(name: "return_children", value: "true"),
        ]
        for (index, tag) in request.requiredTagsIncludingMiscellaneous.enumerated() {
            items.append(URLQueryItem(name: "requiredtags[\(index)]", value: tag))
        }
        for (index, tag) in request.excludedTags.enumerated() {
            items.append(URLQueryItem(name: "excludedtags[\(index)]", value: tag))
        }
        components.percentEncodedQueryItems = Self.percentEncodedQueryItems(items)
        guard let url = components.url else { throw WorkshopQueryError.schemaMismatch }
        return url
    }

    private func acquireToken() async throws {
        while true {
            refillTokenBucket()
            if tokenBucket >= 1 {
                tokenBucket -= 1
                return
            }
            let seconds = (1 - tokenBucket) / Self.tokenRefillPerSecond
            try await Self.sleep(seconds: seconds)
        }
    }

    private func refillTokenBucket() {
        let now = Date()
        let elapsed = max(0, now.timeIntervalSince(tokenRefilledAt))
        guard elapsed > 0 else { return }
        tokenBucket = min(Self.tokenCapacity, tokenBucket + elapsed * Self.tokenRefillPerSecond)
        tokenRefilledAt = now
    }

    private static func sleep(seconds: TimeInterval) async throws {
        let clamped = max(0, min(60, seconds))
        try await Task.sleep(nanoseconds: UInt64(clamped * 1_000_000_000))
    }

    /// `isBrowsePage` is false for the detail sheet's presets query
    /// (`child_publishedfileid`), where zero results is the normal answer for
    /// most wallpapers, not a signal worth a warning-level log (misled a crash
    /// triage into treating it as a browse-query failure — GitHub #134).
    private func decodeQueryPage(_ data: Data, isBrowsePage: Bool, page: Int, numPerPage: Int) throws -> WorkshopQueryPage {
        let envelope: QueryFilesEnvelope
        do {
            envelope = try JSONDecoder().decode(QueryFilesEnvelope.self, from: data)
        } catch {
            let snippet = String(decoding: data.prefix(300), as: UTF8.self)
            Logger.error("Workshop decode failed: \(String(describing: error)) — body: \(snippet)", category: .workshop)
            throw WorkshopQueryError.responseParseFailure
        }
        if Self.messageIndicatesDisabled(envelope.response.resultmsg) {
            throw WorkshopQueryError.keyDisabled
        }
        // A failed query comes back as HTTP 200 with a response-level `result`
        // other than 1 (k_EResultOK) and no page body; read as an empty page it
        // would show "no results", be cached and count the key as accepted.
        if let result = envelope.response.result?.value, result != 1 {
            Logger.error("Workshop query failed: result=\(result) \(envelope.response.resultmsg ?? "")", category: .workshop)
            throw WorkshopQueryError.schemaMismatch
        }
        let total = envelope.response.total?.value
        let totalPages = Self.pageCount(total: total, numPerPage: numPerPage)
        // Steam omits `publishedfiledetails` entirely when a page has no
        // items. That is an empty page only when `total` says this page is
        // past the end (a zero total included); with items to show it is a
        // broken response, which read as "no results" would be cached and
        // count the key as accepted.
        guard let details = envelope.response.publishedfiledetails else {
            guard let totalPages, page > totalPages else {
                Logger.error("Workshop query: no publishedfiledetails with total=\(total.map(String.init) ?? "nil") on page \(page)", category: .workshop)
                throw WorkshopQueryError.schemaMismatch
            }
            let message = "Workshop query: no publishedfiledetails (total=\(total ?? -1)) — treating as empty page"
            if isBrowsePage {
                Logger.warning(message, category: .workshop)
            } else {
                Logger.info(message, category: .workshop)
            }
            return WorkshopQueryPage(items: [], nextCursor: nil, totalAvailable: total, sourceItemCount: 0, totalPages: totalPages)
        }
        let items = details.compactMap(Self.item(from:))
        let nextCursor = envelope.response.next_cursor?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmptyWorkshopQuery
        Logger.info("Workshop query OK: \(items.count) items (total=\(total ?? -1))", category: .workshop)
        return WorkshopQueryPage(
            items: items,
            nextCursor: nextCursor,
            totalAvailable: total,
            sourceItemCount: details.count,
            totalPages: totalPages
        )
    }

    /// `nil` for a total no Workshop has (negative, or past ten million): a
    /// corrupt value must not become a page count — or overflow the arithmetic.
    private static func pageCount(total: Int?, numPerPage: Int) -> Int? {
        guard let total, (0 ... 10_000_000).contains(total) else { return nil }
        return total / numPerPage + (total % numPerPage == 0 ? 0 : 1)
    }

    private static func item(from payload: QueryFilesPayload) -> WorkshopQueryItem? {
        guard let idString = payload.publishedfileid?.value, let id = UInt64(idString) else { return nil }
        // A browse page carries private/hidden entries as three-key shells
        // (`result` 15, no title) in the middle of the list; non-public and
        // banned items are dropped the way `SteamWorkshopMetadata` drops them.
        if let result = payload.result?.value, result != 1 {
            return nil
        }
        if payload.banned?.value == true {
            return nil
        }
        if let visibility = payload.visibility?.value, visibility != 0 {
            return nil
        }

        var previewURL: URL?
        if let candidate = payload.preview_url?.trimmingCharacters(in: .whitespacesAndNewlines), !candidate.isEmpty {
            switch WorkshopCDNHostAllowList.evaluate(candidate) {
            case .allowed(let url):
                previewURL = url
            case .rejected(let reason):
                let redacted = WorkshopDiagnosticRedactor.redact(candidate)
                Logger.warning("Rejected Workshop query preview URL (\(reason.rawValue)): \(redacted)", category: .workshop)
            }
        }

        let rawTitle = payload.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmptyWorkshopQuery
            .map(WorkshopDiagnosticRedactor.redact)
        let shortDescription = WorkshopDiagnosticRedactor.redact(
            payload.short_description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        )
        let tags = (payload.tags ?? [])
            .compactMap { $0.displayName }
            .map(WorkshopDiagnosticRedactor.redact)
            .filter { !$0.isEmpty }

        let communityURL = URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(id)")!

        return WorkshopQueryItem(
            id: id,
            rawTitle: rawTitle,
            shortDescription: shortDescription,
            creatorID: payload.creator?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmptyWorkshopQuery,
            creatorPersonaName: nil,
            previewImageURL: previewURL,
            fileSizeBytes: payload.file_size?.value,
            timeUpdated: payload.time_updated?.dateValue,
            // Prefer lifetime (total unique) subscriptions — that's the key Steam's "Most Subscribed" sort (query_type=9, RankedByTotalUniqueSubscriptions) actually ranks by; showing `subscriptions` (current) instead made a high-lifetime / low-current item look mis-sorted ("low subs above high").
            // Fall back to current when lifetime is absent.
            subscriptionCount: payload.lifetime_subscriptions?.value ?? payload.subscriptions?.value,
            viewCount: payload.views?.value,
            favoriteCount: payload.lifetime_favorited?.value ?? payload.favorited?.value,
            rating: Self.rating(from: payload.vote_data),
            timeCreated: payload.time_created?.dateValue,
            commentCount: payload.num_comments_public?.value,
            requiredItemIDs: (payload.children ?? [])
                .sorted { ($0.sortorder?.value ?? 0) < ($1.sortorder?.value ?? 0) }
                .compactMap { $0.publishedfileid.flatMap { UInt64($0.value) } },
            tags: tags,
            visibility: SteamWorkshopMetadata.Visibility(rawCode: payload.visibility?.value),
            isBanned: payload.banned?.value ?? false,
            steamCommunityURL: communityURL
        )
    }

    private static func rating(from voteData: QueryFilesPayload.VoteData?) -> WorkshopRating? {
        guard let score = voteData?.score?.value, score.isFinite else { return nil }
        return .score(
            min(1, max(0, score)),
            votesUp: voteData?.votes_up?.value ?? 0,
            votesDown: voteData?.votes_down?.value ?? 0
        )
    }

    private static func bodyContainsDisabledKeyHint(_ data: Data) -> Bool {
        guard let envelope = try? JSONDecoder().decode(ValveErrorEnvelope.self, from: data) else { return false }
        return messageIndicatesDisabled(envelope.response?.resultmsg)
    }

    private static func messageIndicatesDisabled(_ message: String?) -> Bool {
        guard let message else { return false }
        return message.range(of: "disabled", options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    private static func steamBool(_ value: Bool) -> String {
        value ? "true" : "false"
    }

    /// Scrubs the `key` query value so URLs are safe to log.
    private static func redactedURLString(_ url: URL) -> String {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.path }
        comps.queryItems = comps.queryItems?.map {
            $0.name == "key" ? URLQueryItem(name: "key", value: "REDACTED") : $0
        }
        return comps.string ?? url.path
    }

    private static func isValidAPIKeyShape(_ key: String) -> Bool {
        key.range(of: apiKeyPattern, options: [.regularExpression, .anchored]) != nil
    }

    private static func mapNetworkError(_ error: Error) -> WorkshopQueryError {
        if error is CancellationError {
            return .cancelled
        }
        if error is BoundedNetworkFetch.ResponseTooLarge {
            return .responseParseFailure
        }
        guard let urlError = error as? URLError else {
            return .networkFailure(code: (error as NSError).code)
        }
        switch urlError.code {
        case .cancelled: return .cancelled
        case .timedOut: return .timeout
        case .notConnectedToInternet, .networkConnectionLost, .dnsLookupFailed, .cannotFindHost, .cannotConnectToHost:
            return .networkUnreachable
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot,
             .clientCertificateRejected, .appTransportSecurityRequiresSecureConnection:
            return .secureConnectionFailed
        default: return .networkFailure(code: urlError.errorCode)
        }
    }
}

extension URLSession {
    static func workshopQuerySession(timeout: TimeInterval) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = max(timeout, 30)
        config.httpAdditionalHeaders = [
            "User-Agent": "Loomscreen/Workshop"
        ]
        return URLSession(configuration: config)
    }
}

// MARK: - Steam response wire format

private struct QueryFilesEnvelope: Decodable {
    let response: ResponseBody

    struct ResponseBody: Decodable {
        let total: LossyIntWQ?
        let next_cursor: String?
        let result: LossyIntWQ?
        let resultmsg: String?
        let publishedfiledetails: [QueryFilesPayload]?
    }
}

private struct QueryFilesPayload: Decodable {
    let publishedfileid: LossyStringWQ?
    let result: LossyIntWQ?
    let creator: String?
    let title: String?
    let short_description: String?
    let preview_url: String?
    let file_size: LossyUInt64WQ?
    let time_created: LossyDoubleWQ?
    let time_updated: LossyDoubleWQ?
    let visibility: LossyIntWQ?
    let banned: LossyBoolWQ?
    let subscriptions: LossyIntWQ?
    let lifetime_subscriptions: LossyIntWQ?
    let favorited: LossyIntWQ?
    let lifetime_favorited: LossyIntWQ?
    let views: LossyIntWQ?
    let num_comments_public: LossyIntWQ?
    let vote_data: VoteData?
    let children: [Child]?
    let tags: [WorkshopTagPayload]?

    struct VoteData: Decodable {
        let score: LossyDoubleWQ?
        let votes_up: LossyIntWQ?
        let votes_down: LossyIntWQ?
    }

    struct Child: Decodable {
        let publishedfileid: LossyStringWQ?
        let sortorder: LossyIntWQ?
    }
}

private struct WorkshopTagPayload: Decodable {
    let tag: String?
    let display_name: String?

    var displayName: String? {
        (display_name ?? tag)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmptyWorkshopQuery
    }

    init(from decoder: Decoder) throws {
        if let keyed = try? decoder.container(keyedBy: CodingKeys.self) {
            self.tag = try keyed.decodeIfPresent(String.self, forKey: .tag)
            self.display_name = try keyed.decodeIfPresent(String.self, forKey: .display_name)
            return
        }
        let single = try decoder.singleValueContainer()
        self.tag = try? single.decode(String.self)
        self.display_name = nil
    }

    private enum CodingKeys: String, CodingKey {
        case tag
        case display_name
    }
}

private struct PlayerSummariesEnvelope: Decodable {
    let response: ResponseBody

    struct ResponseBody: Decodable {
        let players: [Player]
    }

    struct Player: Decodable {
        let steamid: String
        let personaname: String?
    }
}

private struct ValveErrorEnvelope: Decodable {
    let response: ResponseBody?

    struct ResponseBody: Decodable {
        let result: LossyIntWQ?
        let resultmsg: String?
    }
}

// `WQ` suffix avoids colliding with similarly-named lossy decoders elsewhere.

private struct LossyStringWQ: Decodable {
    let value: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            value = string
        } else if let int = try? container.decode(Int.self) {
            value = String(int)
        } else if let uint64 = try? container.decode(UInt64.self) {
            value = String(uint64)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected string-like value")
        }
    }
}

private struct LossyIntWQ: Decodable {
    let value: Int

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let int = try? container.decode(Int.self) {
            value = int
        } else if let string = try? container.decode(String.self), let int = Int(string) {
            value = int
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected int-like value")
        }
    }
}

private struct LossyUInt64WQ: Decodable {
    let value: UInt64

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let uint64 = try? container.decode(UInt64.self) {
            value = uint64
        } else if let int = try? container.decode(Int.self), int >= 0 {
            value = UInt64(int)
        } else if let string = try? container.decode(String.self), let uint64 = UInt64(string) {
            value = uint64
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected uint64-like value")
        }
    }
}

private struct LossyDoubleWQ: Decodable {
    let value: Double

    var dateValue: Date? {
        guard value > 0, value.isFinite else { return nil }
        return Date(timeIntervalSince1970: value)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self), let double = Double(string) {
            value = double
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected double-like value")
        }
    }
}

private struct LossyBoolWQ: Decodable {
    let value: Bool

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int != 0
        } else if let string = try? container.decode(String.self) {
            value = string == "1" || string.caseInsensitiveCompare("true") == .orderedSame
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected bool-like value")
        }
    }
}

private extension String {
    var nilIfEmptyWorkshopQuery: String? { isEmpty ? nil : self }
}
#endif
