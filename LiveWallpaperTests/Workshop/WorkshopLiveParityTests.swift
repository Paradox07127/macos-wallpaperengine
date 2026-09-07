#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import Testing

/// Live parity between the app's own Workshop request chain (URLSession,
/// decoder, client-side filtering) and what steamcommunity.com shows in the
/// same minute. Every earlier comparison replayed the app's parameters with
/// curl; this one exercises the real `WorkshopQueryService` and
/// `WorkshopPublicSearchSource`.
///
/// The network cases are opt-in (`TEST_RUNNER_WORKSHOP_LIVE_PARITY=1`); the
/// two offline cases keep the suite green without a network or a key.
@Suite("Workshop live parity", .serialized)
struct WorkshopLiveParityTests {
    private static let searchText = "cat"
    private static let comparedCount = 30
    private static let minimumLeadingMatch = 5
    private static let minimumIntersection = 25

    private static var isLive: Bool {
        ProcessInfo.processInfo.environment["WORKSHOP_LIVE_PARITY"] == "1"
    }

    private static var apiKey: String? {
        guard let key = ProcessInfo.processInfo.environment["STEAM_WEB_API_KEY"],
              key.range(of: #"^[A-Fa-f0-9]{32}$"#, options: .regularExpression) != nil
        else { return nil }
        return key
    }

    // MARK: - Offline

    @Test("Control page parser keeps first-seen order, de-duplicates, ignores non-result anchors")
    func controlParserOrdersAndDeduplicates() {
        let html = """
        <a href="https://steamcommunity.com/workshop/browse/?appid=431960">Browse</a>
        <a href="https://steamcommunity.com/sharedfiles/filedetails/?id=111"><img></a>
        <a href="https://steamcommunity.com/sharedfiles/filedetails/?id=111">Title 111</a>
        <a href="https://steamcommunity.com/sharedfiles/filedetails/?id=222&searchtext=cat">Title 222</a>
        <a href="https://steamcommunity.com/id/someone/myworkshopfiles/?appid=431960">Author</a>
        <a href="https://steamcommunity.com/sharedfiles/filedetails/?id=333">Title 333</a>
        <a href="https://steamcommunity.com/sharedfiles/filedetails/?id=111">Again 111</a>
        <p>see https://steamcommunity.com/sharedfiles/filedetails/?id=444 for the original</p>
        <script>window.SSR.renderContext=JSON.parse("{\\"short_description\\":\\"https://steamcommunity.com/sharedfiles/filedetails/?id=555\\"}")</script>
        """
        #expect(WorkshopLiveParityControl.publishedFileIDs(inHTML: html) == [111, 222, 333])
    }

    @Test("Control URL: days=7 only on trend, searchtext only on search, excluded tags from the app request")
    func controlURLShape() throws {
        let trend = try queryItems(of: WorkshopLiveParityControl.pageURL(for: Self.appRequest(sort: .mostPopular, numPerPage: 30)))
        #expect(trend == [
            "appid=431960",
            "browsesort=trend",
            "p=1",
            "excludedtags[]=Application",
            "excludedtags[]=Asset",
            "excludedtags[]=Mature",
            "excludedtags[]=Preset",
            "excludedtags[]=Questionable",
            "days=7",
        ])

        let search = try queryItems(of: WorkshopLiveParityControl.pageURL(for: Self.appRequest(sort: .search, numPerPage: 30)))
        #expect(search == [
            "appid=431960",
            "browsesort=textsearch",
            "p=1",
            "excludedtags[]=Application",
            "excludedtags[]=Asset",
            "excludedtags[]=Mature",
            "excludedtags[]=Preset",
            "excludedtags[]=Questionable",
            "searchtext=cat",
        ])
    }

    @Test("Leading match tolerates one side gaining up to two new entries at the top")
    func leadingMatchShiftTolerance() {
        let base: [UInt64] = [1, 2, 3, 4, 5, 6]
        #expect(WorkshopLiveParityTests.leadingMatch(base, base) == 6)
        #expect(WorkshopLiveParityTests.leadingMatch(base, [9] + base) == 6)
        #expect(WorkshopLiveParityTests.leadingMatch([8, 9] + base, base) == 6)
        #expect(WorkshopLiveParityTests.leadingMatch([7, 8, 9] + base, base) == 0)
        #expect(WorkshopLiveParityTests.leadingMatch([1, 2, 9, 4, 5, 6], base) == 2)
    }

    private func queryItems(of url: URL) throws -> [String] {
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        return try #require(components.queryItems).map { "\($0.name)=\($0.value ?? "")" }
    }

    // MARK: - Live

    @Test("Keyless path (public page + details) matches the page",
          .enabled(if: WorkshopLiveParityTests.isLive, "Set TEST_RUNNER_WORKSHOP_LIVE_PARITY=1 to compare against steamcommunity.com"),
          arguments: WorkshopSortMode.allCases)
    @MainActor
    func keylessParity(sort: WorkshopSortMode) async throws {
        let request = Self.appRequest(sort: sort, numPerPage: WorkshopPublicBrowseURL.itemsPerPage)
        let source = WorkshopPublicSearchSource(cache: WorkshopQueryCache(directoryURL: Self.freshCacheDirectory()))
        let appIDs: [UInt64]
        do {
            let items = try await source.fetch(request).items
            appIDs = items.map(\.id)
            // Only the SSR payload carries persona names; the anchor-harvest
            // fallback never does, so this is the live proof the new source was used.
            let named = items.filter { $0.creatorPersonaName != nil }.count
            #expect(named >= items.count - 2, "keyless \(sort.rawValue): \(named)/\(items.count) items carry a creator name — SSR path not taken?")
        } catch {
            Issue.record("keyless fetch failed: \(error) — \(WorkshopPublicBrowseURL.url(for: request, appID: WorkshopQueryService.wallpaperEngineAppID))")
            return
        }
        let webIDs = try await WorkshopLiveParityControl.pageIDs(for: request)
        try Self.compare(sort: sort, path: "keyless", appIDs: appIDs, webIDs: webIDs)
    }

    @Test("Keyed path (QueryFiles) matches the page",
          .enabled(if: WorkshopLiveParityTests.isLive, "Set TEST_RUNNER_WORKSHOP_LIVE_PARITY=1 to compare against steamcommunity.com"),
          .enabled(if: WorkshopLiveParityTests.apiKey != nil, "Set TEST_RUNNER_STEAM_WEB_API_KEY to a 32-hex Steam Web API key"),
          arguments: WorkshopSortMode.allCases)
    func keyedParity(sort: WorkshopSortMode) async throws {
        let key = try #require(Self.apiKey)
        let request = Self.appRequest(sort: sort, numPerPage: 50)
        let keychain = WorkshopKeychainStore(
            directory: Self.freshCacheDirectory(),
            slot: WorkshopKeychainSlotSpy(stored: key).slot()
        )
        // `countIssuedRequest` defaults to the app's UserDefaults tally.
        let service = WorkshopQueryService(
            keychain: keychain,
            cache: WorkshopQueryCache(directoryURL: Self.freshCacheDirectory()),
            countIssuedRequest: {}
        )
        let appIDs: [UInt64]
        do {
            appIDs = try await service.fetch(request).items.map(\.id)
        } catch {
            var redacted = try #require(URLComponents(string: "https://api.steampowered.com/IPublishedFileService/QueryFiles/v1/"))
            redacted.queryItems = request.apiQueryItems(apiKey: "REDACTED", appID: WorkshopQueryService.wallpaperEngineAppID)
            Issue.record("keyed fetch failed: \(error) — \(redacted.url?.absoluteString ?? "")")
            return
        }
        let webIDs = try await WorkshopLiveParityControl.pageIDs(for: request)
        try Self.compare(sort: sort, path: "keyed", appIDs: appIDs, webIDs: webIDs)
    }

    /// The `input_json` + `taggroups` shape exists only for "genre any-of AND
    /// Miscellaneous"; the page cannot express that query, so the live check is
    /// the predicate itself: every returned item carries Approved and one of
    /// the two genres (probe 7, 2026-09-07: total 6,330 = 5,764 + 566).
    @Test("Keyed tag groups (genre any-of + Miscellaneous) go through input_json and filter server-side",
          .enabled(if: WorkshopLiveParityTests.isLive, "Set TEST_RUNNER_WORKSHOP_LIVE_PARITY=1 to compare against steamcommunity.com"),
          .enabled(if: WorkshopLiveParityTests.apiKey != nil, "Set TEST_RUNNER_STEAM_WEB_API_KEY to a 32-hex Steam Web API key"))
    func keyedTagGroupsLive() async throws {
        let key = try #require(Self.apiKey)
        let request = WorkshopQueryRequest(
            sort: .topRated,
            numPerPage: 50,
            requiredTags: ["Anime", "Abstract"],
            matchAllTags: false,
            excludedTags: BrowseViewModel.excludedTags(showsPresets: false),
            miscellaneousTags: ["Approved"]
        )
        let names = request.apiQueryItems(apiKey: "REDACTED", appID: WorkshopQueryService.wallpaperEngineAppID).map(\.name)
        #expect(names == ["key", "input_json"])
        let keychain = WorkshopKeychainStore(
            directory: Self.freshCacheDirectory(),
            slot: WorkshopKeychainSlotSpy(stored: key).slot()
        )
        let service = WorkshopQueryService(
            keychain: keychain,
            cache: WorkshopQueryCache(directoryURL: Self.freshCacheDirectory()),
            countIssuedRequest: {}
        )
        let page = try await service.fetch(request)
        let matching = page.items.filter { item in
            let tags = Set(item.tags)
            return tags.contains("Approved") && (tags.contains("Anime") || tags.contains("Abstract"))
        }
        let row = "| tagGroups(Anime∪Abstract ∧ Approved) | keyed | app \(page.items.count) / total \(page.totalAvailable ?? -1) | 谓词命中 \(matching.count)/\(page.items.count) | — |"
        print(row)
        try WorkshopLiveParityReport.append(row)
        #expect(page.items.count >= 30)
        #expect(matching.count == page.items.count)
        #expect((page.totalAvailable ?? 0) > 1000)
    }

    /// Miscellaneous rides on `requiredtags[]` on the page, which the SSR
    /// query key echoes back; the identity check has to accept it or every
    /// keyless Misc search fails (review finding W4-C-1, 2026-09-07).
    @Test("Keyless Miscellaneous narrowing is adopted from the SSR payload and matches the page",
          .enabled(if: WorkshopLiveParityTests.isLive, "Set TEST_RUNNER_WORKSHOP_LIVE_PARITY=1 to compare against steamcommunity.com"))
    @MainActor
    func keylessMiscellaneousLive() async throws {
        let request = WorkshopQueryRequest(
            sort: .topRated,
            numPerPage: WorkshopPublicBrowseURL.itemsPerPage,
            excludedTags: Self.deselectedAgeTags + BrowseViewModel.excludedTags(showsPresets: false),
            miscellaneousTags: ["Approved"]
        )
        let source = WorkshopPublicSearchSource(cache: WorkshopQueryCache(directoryURL: Self.freshCacheDirectory()))
        let items = try await source.fetch(request).items
        let approved = items.filter { $0.tags.contains("Approved") }.count
        let named = items.filter { $0.creatorPersonaName != nil }.count
        let row = "| misc(Approved) | keyless | app \(items.count) | Approved \(approved)/\(items.count) | 作者名 \(named) |"
        print(row)
        try WorkshopLiveParityReport.append(row)
        #expect(items.count >= 25)
        #expect(approved == items.count)
        // Persona names only come from the SSR path: proof the payload was adopted, not harvested.
        #expect(named >= items.count - 2)
    }

    // MARK: - App request shape

    /// Mirrors `BrowseViewModel.makeRequest(page: 1)` in its default state
    /// (every facet fully selected, no pinned tag, no creator) with only the
    /// Questionable and Mature age ratings deselected: the anonymous page hides
    /// those two, so the app must exclude them too before the lists can agree.
    /// Trend is pinned to one week because the page counts 7 days when `days`
    /// is absent.
    private static func appRequest(sort: WorkshopSortMode, numPerPage: Int) -> WorkshopQueryRequest {
        WorkshopQueryRequest(
            sort: sort,
            searchText: sort == .search ? searchText : "",
            page: 1,
            numPerPage: numPerPage,
            timeFrame: sort == .mostPopular ? .oneWeek : .allTime,
            requiredTags: [],
            matchAllTags: false,
            excludedTags: deselectedAgeTags + BrowseViewModel.excludedTags(showsPresets: false)
        )
    }

    /// The maturity tags the app leaves out by default — the signed-out page
    /// hides exactly these, so they are what makes the two lists comparable.
    private static var deselectedAgeTags: [String] {
        WorkshopAgeRatingFilter.allCases
            .filter { !WorkshopAgeRatingFilter.defaultSelection.contains($0) }
            .map(\.tag)
    }

    private static func freshCacheDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("workshop-live-parity-\(UUID().uuidString)", isDirectory: true)
    }

    // MARK: - Comparison

    /// Longest run of identical ids from the top, after allowing one side to
    /// lead by up to two entries: an item published or updated between the two
    /// fetches shifts every later position by one (seen live 2026-09-07 on
    /// Most Recent: 29/30 in common, leading 0), which says nothing about the
    /// sort itself.
    static func leadingMatch(_ app: [UInt64], _ web: [UInt64], maxShift: Int = 2) -> Int {
        var best = 0
        for shift in 0 ... maxShift {
            let appLeads = zip(app.dropFirst(shift), web).prefix { $0.0 == $0.1 }.count
            let webLeads = zip(app, web.dropFirst(shift)).prefix { $0.0 == $0.1 }.count
            best = max(best, appLeads, webLeads)
        }
        return best
    }

    private static func compare(sort: WorkshopSortMode, path: String, appIDs: [UInt64], webIDs: [UInt64]) throws {
        let app = Array(appIDs.prefix(comparedCount))
        let web = Array(webIDs.prefix(comparedCount))
        let intersection = Set(app).intersection(web).count
        let leading = Self.leadingMatch(app, web)
        let row = "| \(sort.rawValue) | \(path) | app \(appIDs.count) / web \(webIDs.count) | 交集 \(intersection)/\(comparedCount) | 首位连续 \(leading) |"
        print(row)
        try WorkshopLiveParityReport.append(row)

        // Last Updated ranks by `time_updated` seconds; items updated in the
        // same second tie, and Steam orders ties differently from one request
        // to the next (seen live 2026-09-07: same 30 ids, leading 0). The set
        // still has to agree; the order only when the sort is deterministic.
        if sort != .lastUpdated {
            #expect(leading >= minimumLeadingMatch, "\(row)\napp: \(app)\nweb: \(web)")
        }
        #expect(intersection >= minimumIntersection, "\(row)\napp: \(app)\nweb: \(web)")
    }
}

/// Independent of the app's page fetcher and id extractor on purpose: the
/// control must not share code with the path under test.
enum WorkshopLiveParityControl {
    struct FetchFailure: Error, CustomStringConvertible {
        let url: URL
        let detail: String
        var description: String {
            "control fetch failed: \(detail) — \(url.absoluteString)"
        }
    }

    static func pageURL(for request: WorkshopQueryRequest) -> URL {
        var items = [
            URLQueryItem(name: "appid", value: String(WorkshopQueryService.wallpaperEngineAppID)),
            URLQueryItem(name: "browsesort", value: browseSort(for: request.sort)),
            URLQueryItem(name: "p", value: "1"),
        ]
        items += request.excludedTags.map { URLQueryItem(name: "excludedtags[]", value: $0) }
        if request.sort == .mostPopular {
            items.append(URLQueryItem(name: "days", value: "7"))
        }
        if request.sort == .search {
            items.append(URLQueryItem(name: "searchtext", value: request.searchText))
        }
        var components = URLComponents(string: "https://steamcommunity.com/workshop/browse/")!
        components.queryItems = items
        return components.url!
    }

    /// Verified live 2026-09-07 against the page's own sort menu.
    private static func browseSort(for sort: WorkshopSortMode) -> String {
        switch sort {
        case .mostPopular: "trend"
        case .topRated: "toprated"
        case .newest: "mostrecent"
        case .lastUpdated: "lastupdated"
        case .mostSubscribed: "totaluniquesubscribers"
        case .search: "textsearch"
        }
    }

    static func pageIDs(for request: WorkshopQueryRequest) async throws -> [UInt64] {
        let url = pageURL(for: request)
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        config.httpAdditionalHeaders = ["User-Agent": "Loomscreen/Workshop (+https://loomscreen.app/)"]
        var urlRequest = URLRequest(url: url)
        urlRequest.setValue("text/html", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession(configuration: config).data(for: urlRequest)
        } catch {
            throw FetchFailure(url: url, detail: String(describing: error))
        }
        guard let http = response as? HTTPURLResponse else {
            throw FetchFailure(url: url, detail: "non-HTTP response")
        }
        guard http.statusCode == 200 else {
            throw FetchFailure(url: url, detail: "HTTP \(http.statusCode)")
        }
        guard let html = String(bytes: data, encoding: .utf8) else {
            throw FetchFailure(url: url, detail: "page was not UTF-8 (\(data.count) bytes)")
        }
        let ids = publishedFileIDs(inHTML: html)
        guard !ids.isEmpty else {
            throw FetchFailure(url: url, detail: "page carried no result ids (\(data.count) bytes)")
        }
        return ids
    }

    static func publishedFileIDs(inHTML html: String) -> [UInt64] {
        var seen = Set<UInt64>()
        // Result anchors only: the embedded SSR JSON and item descriptions can
        // carry other items' URLs as plain text, never as an href.
        let ordered = html.matches(of: /href="https:\/\/steamcommunity\.com\/sharedfiles\/filedetails\/\?id=(\d+)/)
            .compactMap { UInt64($0.1) }
            .filter { seen.insert($0).inserted }
        return Array(ordered.prefix(30))
    }
}

/// The test host is the sandboxed app, so the report path has to sit inside
/// its container (`~/Library/Containers/<bundle id>/Data/...`); `/tmp` is
/// refused with EPERM and the case fails rather than dropping the row.
enum WorkshopLiveParityReport {
    private static let header = "| sort | path | counts | intersection | leading |\n|---|---|---|---|---|\n"

    static func append(_ row: String) throws {
        guard let path = ProcessInfo.processInfo.environment["WORKSHOP_LIVE_PARITY_REPORT"], !path.isEmpty else { return }
        let url = URL(fileURLWithPath: path)
        if !FileManager.default.fileExists(atPath: path) {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(header.utf8).write(to: url)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((row + "\n").utf8))
    }
}
#endif
