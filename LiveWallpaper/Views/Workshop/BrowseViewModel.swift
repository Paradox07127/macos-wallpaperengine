#if !LITE_BUILD
import Foundation
import LiveWallpaperCore
import Observation

enum WorkshopContentTypeFilter: String, CaseIterable, Identifiable {
    case scene
    case video
    case web

    var id: String { rawValue }

    var displayName: String {
        WorkshopTagLocalization.displayName(tag ?? rawValue)
    }

    var requiredTags: [String] {
        switch self {
        case .scene: return ["Scene"]
        case .video: return ["Video"]
        case .web: return ["Web"]
        }
    }

    static var selectableCases: [WorkshopContentTypeFilter] { allCases }

    var tag: String? { requiredTags.first }
}

/// WPE's three maturity ratings, independent multi-select toggles.
enum WorkshopAgeRatingFilter: String, CaseIterable, Identifiable {
    case everyone
    case questionable
    case mature

    var id: String { rawValue }

    /// Localized filter chip label (Steam API tag stays English via `tag`).
    var displayName: String {
        WorkshopTagLocalization.displayName(tag)
    }

    /// Exact Steam Workshop maturity tag string (not localized).
    var tag: String {
        switch self {
        case .everyone: return "Everyone"
        case .questionable: return "Questionable"
        case .mature: return "Mature"
        }
    }

    static let defaultSelection: Set<WorkshopAgeRatingFilter> = Set(allCases)
}

extension WorkshopQueryItem {
    /// True when the item carries Wallpaper Engine's `Mature` maturity tag.
    var isMatureRated: Bool {
        tags.contains { $0.caseInsensitiveCompare("Mature") == .orderedSame }
    }
}

/// Official WPE Workshop genre tags — exact display strings, since Steam matches
/// tags by exact case. On the keyed path a narrowed selection becomes
/// `requiredtags` with `match_all_tags=false`: an item can carry several genres,
/// so excluding the unselected ones would drop every multi-genre wallpaper. The
/// keyless page has no `match_all_tags`, so it keeps the exclusion form —
/// see `makeRequest`.
enum WorkshopGenre {
    static let allTags: [String] = [
        "Abstract", "Animal", "Anime", "Cartoon", "CGI", "Cyberpunk", "Fantasy",
        "Game", "Girls", "Guys", "Landscape", "Medieval", "Memes", "MMD", "Music",
        "Nature", "Pixel art", "Relaxing", "Retro", "Sci-Fi", "Sports",
        "Technology", "Television", "Vehicle", "Unspecified"
    ]
}

enum WorkshopResolutionFilter: String, CaseIterable, Identifiable {
    case any
    case standardDefinition
    case fullHD1080
    case quadHD1440
    case ultraHD4K
    case ultrawide
    case portrait
    case dual

    var id: String { rawValue }

    /// Verbatim Wallpaper Engine Workshop labels — no renaming. `.any` is the only localized label.
    var displayName: String {
        switch self {
        case .any:
            return String(localized: "All", bundle: .appLanguage, comment: "Workshop resolution filter: no restriction.")
        case .standardDefinition:
            return String(localized: "Standard Definition", bundle: .appLanguage, comment: "Workshop resolution filter display label.")
        case .fullHD1080:
            return "1920 x 1080"
        case .quadHD1440:
            return "2560 x 1440"
        case .ultraHD4K:
            return "3840 x 2160"
        case .ultrawide:
            return "3440 x 1440"
        case .portrait:
            return "1080 x 1920"
        case .dual:
            return String(localized: "Dual 3840 x 1080", bundle: .appLanguage, comment: "Workshop dual-display resolution filter label.")
        }
    }

    static var selectableCases: [WorkshopResolutionFilter] { allCases.filter { $0 != .any } }

    /// Exact Steam Workshop resolution tag, or `nil` for `.any`.
    var tag: String? {
        switch self {
        case .any: return nil
        case .standardDefinition: return "Standard Definition"
        case .fullHD1080: return "1920 x 1080"
        case .quadHD1440: return "2560 x 1440"
        case .ultraHD4K: return "3840 x 2160"
        case .ultrawide: return "3440 x 1440"
        case .portrait: return "1080 x 1920"
        case .dual: return "Dual 3840 x 1080"
        }
    }
}

/// Drives `BrowsePane`: request shape, paginated browse, debounced
/// search, inline error surfacing. Read-only — owns no download workflow.
@MainActor
@Observable
final class BrowseViewModel {

    struct CreatorFilter: Equatable {
        let steamID: String
        let name: String?
    }

    @ObservationIgnored private let services: WorkshopServices

    /// Excluded from EVERY query: Application wallpapers can't run in this
    /// runtime, so never surface them (server-side exclusion, not post-filter).
    nonisolated static let alwaysExcludedTags = ["Application"]

    /// `Preset` items restyle another wallpaper rather than being one — excluded
    /// unless the user opted in via Settings → Workshop.
    nonisolated static func excludedTags(showsPresets: Bool) -> [String] {
        showsPresets ? alwaysExcludedTags : alwaysExcludedTags + ["Preset"]
    }

    /// Typing schedules a debounced auto-search (fires after `searchDebounce` of quiet); Return / Search submit immediately.
    var searchInput: String = "" {
        didSet {
            guard searchInput != oldValue else { return }
            // Relevance ranks against the search text, so it only exists while
            // searching; clearing the text drops back to the browse default.
            if preferredSort == .search,
               searchInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                preferredSort = .topRated
            }
            scheduleAutoApply()
        }
    }
    var preferredSort: WorkshopSortMode = .topRated
    private(set) var selectedTypes: Set<WorkshopContentTypeFilter> = Set(WorkshopContentTypeFilter.selectableCases)
    private(set) var selectedAgeRatings: Set<WorkshopAgeRatingFilter> = WorkshopAgeRatingFilter.defaultSelection
    private(set) var selectedResolutions: Set<WorkshopResolutionFilter> = Set(WorkshopResolutionFilter.selectableCases)
    private(set) var selectedGenres: Set<String> = Set(WorkshopGenre.allTags)
    private(set) var preferredTimeFrame: WorkshopTimeFrame = .allTime
    /// When set, the grid shows only this creator's published files (via
    /// GetUserFiles). Mutually exclusive with `pinnedTag`.
    private(set) var creatorFilter: CreatorFilter?
    /// When set, the grid is scoped to items carrying this exact Workshop tag
    /// (detail-inspector tag-click path). Mutually exclusive with `creatorFilter`.
    private(set) var pinnedTag: String?
    /// Pushed in by the pane; observed so the grid re-derives `displayedItems`
    /// when the library changes underneath it.
    var installedWorkshopIDs: Set<String> = []
    /// The preference lives in Settings → Steam Workshop (`@AppStorage`); the
    /// pane pushes the current value in here.
    var hidesDownloadedInBrowse: Bool = false
    private(set) var currentRequest: WorkshopQueryRequest
    private(set) var items: [WorkshopQueryItem] = []
    /// True once any page has been applied. The skeleton is for "nothing has
    /// ever loaded"; a reload over an existing grid dims it instead.
    private(set) var hasLoadedPage: Bool = false
    private(set) var totalAvailable: Int?
    private(set) var isLoading: Bool = false
    /// True while paging — current results stay on screen until the new page
    /// replaces them, so memory stays bounded.
    private(set) var isPaging: Bool = false
    private(set) var lastError: WorkshopQueryError?
    /// Set when Steam returns HTTP 429; controls stay disabled until it lapses.
    private(set) var rateLimitUntil: Date?

    /// True when no Steam Web API key is stored: browse then runs off Valve's
    /// public Workshop page (ids only) plus the key-free metadata endpoint.
    var usesKeylessSearch: Bool { !services.hasWebAPIKey }

    /// QueryFiles lets us ask for 50; the public page is fixed at 30.
    private var perPage: Int {
        usesKeylessSearch ? WorkshopPublicBrowseURL.itemsPerPage : 50
    }

    /// The public page publishes no result total, so "is there a next page" can
    /// only come from the page having yielded ids at all.
    private(set) var hasMoreKeylessPages: Bool = false

    /// 1-based. Steam's QueryFiles `page` param lets us jump to any page directly.
    private(set) var pageIndex: Int = 1

    var isRateLimited: Bool {
        (rateLimitUntil ?? .distantPast) > Date()
    }

    /// Grid renders these; `items` stays the raw page so pagination/counts stay intact.
    var displayedItems: [WorkshopQueryItem] {
        guard hidesDownloadedInBrowse else { return items }
        return items.filter { !installedWorkshopIDs.contains(String($0.id)) }
    }

    /// Steam's QueryFiles `page` parameter is hard-capped at 1000; higher pages
    /// return empty results, so never advertise pages we can't fetch.
    nonisolated static let maxQueryPage = 1000

    nonisolated static func pageCount(totalAvailable: Int, perPage: Int) -> Int {
        min(maxQueryPage, max(1, (totalAvailable + perPage - 1) / perPage))
    }

    var totalPages: Int? {
        guard let total = totalAvailable, total > 0 else { return nil }
        return Self.pageCount(totalAvailable: total, perPage: perPage)
    }

    var canGoNextPage: Bool {
        guard !isRateLimited, !isLoading, !isPaging else { return false }
        if let totalPages {
            return pageIndex < totalPages
        }
        if usesKeylessSearch {
            return hasMoreKeylessPages && pageIndex < Self.maxQueryPage
        }
        return lastFetchedRawItemCount >= perPage
    }

    /// Size of the last fetched page BEFORE `displayable` dropped Application /
    /// Preset items: counting `items` instead greys out Next on a full page that
    /// happened to contain one filtered item.
    var lastFetchedRawItemCount: Int = 0

    var canGoPrevPage: Bool {
        !isRateLimited && !isLoading && !isPaging && pageIndex > 1
    }

    @ObservationIgnored private var inflightFetch: Task<Bool, Never>?
    @ObservationIgnored private var currentRequestToken: UInt64 = 0
    @ObservationIgnored private var autoSearchTask: Task<Void, Never>?
    @ObservationIgnored private let defaults: UserDefaults
    /// Built on first keyless fetch — it owns a `URLSession`, so a keyed session never makes one.
    @ObservationIgnored private lazy var publicSource = WorkshopPublicSearchSource()

    /// Quiet window after the last keystroke before auto-search fires: long
    /// enough that mid-word states don't burn API quota, short enough to feel live.
    private static let searchDebounce: Duration = .milliseconds(500)

    /// True when pending filter/search state differs from what's displayed —
    /// gates the debounced auto-search.
    var hasPendingChanges: Bool {
        makeRequest(page: 1) != currentRequest
    }

    init(services: WorkshopServices, defaults: UserDefaults = .appScoped()) {
        self.services = services
        self.defaults = defaults
        self.currentRequest = WorkshopQueryRequest(sort: .topRated, timeFrame: .allTime)
        loadPersistedFilters()
        self.currentRequest = makeRequest(page: 1)
    }

    func onAppear() {
        if items.isEmpty, lastError == nil {
            Task { await reload() }
        }
    }

    /// Reloads after the search debounce only when the applied request would change.
    private func scheduleAutoApply() {
        autoSearchTask?.cancel()
        autoSearchTask = Task { [weak self] in
            try? await Task.sleep(for: Self.searchDebounce)
            guard !Task.isCancelled, let self else { return }
            guard self.hasPendingChanges, !self.isRateLimited else { return }
            await self.reload()
        }
    }

    /// The previous page stays on screen until the new one replaces it (the way
    /// `goToPage` already works) — clearing here flashed the skeleton on every
    /// filter change. `isLoading` is what the grid dims itself with.
    func reload() async {
        guard !isRateLimited else { return }
        autoSearchTask?.cancel()
        inflightFetch?.cancel()
        pageIndex = 1
        let request = makeRequest(page: 1)
        currentRequest = request
        totalAvailable = nil
        hasMoreKeylessPages = false
        isLoading = true
        isPaging = false
        lastError = nil
        _ = await runFetch(request, replacingItems: true, paging: false)
    }

    func goToNextPage() async { await goToPage(pageIndex + 1) }
    func goToPrevPage() async { await goToPage(pageIndex - 1) }

    /// Clamped to `totalPages` when known. Page index commits only on a
    /// successful fetch, so a failed jump leaves the pager consistent.
    func goToPage(_ target: Int) async {
        guard !isRateLimited, !isLoading, !isPaging else { return }
        let upperBound = totalPages ?? Self.maxQueryPage
        let clamped = min(max(target, 1), upperBound)
        guard clamped != pageIndex else { return }
        isPaging = true
        let request = makeRequest(page: clamped)
        let ok = await runFetch(request, replacingItems: true, paging: true)
        if ok {
            pageIndex = clamped
            currentRequest = request
        }
    }

    /// Immediate submit (Return / search button) — skips the typing debounce.
    func submitSearch() async {
        guard !isRateLimited else { return }
        await reload()
    }

    /// Deep-link search: clears any creator/tag scope inline (no per-clear reload) so
    /// `makeRequest` doesn't drop the query, then applies it in one reload; `searchInput`'s
    /// debounced auto-apply is cancelled by `reload()` on the same actor turn, so no double fetch.
    /// Rate-limit check comes first, like every entry point: `reload()` alone would leave the scope cleared and the search box rewritten over a grid still showing old results.
    func searchFromDeepLink(_ query: String) async {
        guard !isRateLimited else { return }
        pinnedTag = nil
        creatorFilter = nil
        searchInput = query
        await reload()
    }

    func clearSearch() async {
        guard !isRateLimited, !searchInput.isEmpty else { return }
        searchInput = ""
        await reload()
    }

    /// Scope to one creator's published files. Leaves the normal filter
    /// selection untouched so exiting restores it.
    func browseCreator(steamID: String, name: String?) async {
        guard !isRateLimited else { return }
        let trimmed = steamID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pinnedTag = nil
        creatorFilter = CreatorFilter(steamID: trimmed, name: name)
        await reload()
    }

    func clearCreatorFilter() async {
        guard creatorFilter != nil else { return }
        creatorFilter = nil
        await reload()
    }

    /// Scope to items carrying one Workshop tag. Leaves the normal filter selection untouched.
    func browseTag(_ tag: String) async {
        guard !isRateLimited else { return }
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Pinning a tag we always exclude would require and exclude it at once,
        // which can only ever come back empty.
        guard !Self.excludedTags(showsPresets: showsWorkshopPresets).contains(trimmed) else { return }
        creatorFilter = nil
        pinnedTag = trimmed
        await reload()
    }

    /// Applies the scope `browseTag`/`browseCreator` set, without the fetch they
    /// follow it with — the request shape is otherwise only reachable through the network.
    func applyScopeForTesting(pinnedTag: String? = nil, creator: CreatorFilter? = nil) {
        self.pinnedTag = pinnedTag
        creatorFilter = creator
    }

    func clearPinnedTag() async {
        guard pinnedTag != nil else { return }
        pinnedTag = nil
        await reload()
    }


    func updateSort(_ sort: WorkshopSortMode) {
        preferredSort = sort
        scheduleAutoApply()
    }

    func updateTimeFrame(_ timeFrame: WorkshopTimeFrame) {
        preferredTimeFrame = timeFrame
        scheduleAutoApply()
    }

    func toggleType(_ type: WorkshopContentTypeFilter) {
        selectedTypes = Self.toggled(type, in: selectedTypes, all: WorkshopContentTypeFilter.selectableCases)
        persistFilters()
        scheduleAutoApply()
    }

    func toggleAgeRating(_ rating: WorkshopAgeRatingFilter) {
        selectedAgeRatings = Self.toggled(rating, in: selectedAgeRatings, all: WorkshopAgeRatingFilter.allCases)
        persistFilters()
        scheduleAutoApply()
    }

    func toggleResolution(_ resolution: WorkshopResolutionFilter) {
        selectedResolutions = Self.toggled(resolution, in: selectedResolutions, all: WorkshopResolutionFilter.selectableCases)
        persistFilters()
        scheduleAutoApply()
    }

    func toggleGenre(_ tag: String) {
        selectedGenres = Self.toggled(tag, in: selectedGenres, all: WorkshopGenre.allTags)
        persistFilters()
        scheduleAutoApply()
    }

    func isolateType(_ type: WorkshopContentTypeFilter) {
        selectedTypes = isolated(type, in: selectedTypes, all: WorkshopContentTypeFilter.selectableCases)
        persistFilters()
        scheduleAutoApply()
    }

    func isolateAgeRating(_ rating: WorkshopAgeRatingFilter) {
        selectedAgeRatings = isolated(rating, in: selectedAgeRatings, all: WorkshopAgeRatingFilter.allCases)
        persistFilters()
        scheduleAutoApply()
    }

    func isolateResolution(_ resolution: WorkshopResolutionFilter) {
        selectedResolutions = isolated(resolution, in: selectedResolutions, all: WorkshopResolutionFilter.selectableCases)
        persistFilters()
        scheduleAutoApply()
    }

    func isolateGenre(_ tag: String) {
        selectedGenres = isolated(tag, in: selectedGenres, all: WorkshopGenre.allTags)
        persistFilters()
        scheduleAutoApply()
    }

    private func isolated<T: Hashable>(_ option: T, in current: Set<T>, all: [T]) -> Set<T> {
        if current.count == 1, current.contains(option) { return Set(all) }
        return [option]
    }

    /// Deselecting the last chip snaps back to all-selected: an empty set means
    /// "no filter" at the request layer, but every chip struck through reads as
    /// "exclude everything" in the UI — same snap-back idiom as `isolated()`.
    nonisolated static func toggled<T: Hashable>(_ option: T, in current: Set<T>, all: [T]) -> Set<T> {
        var next = current
        if next.contains(option) { next.remove(option) } else { next.insert(option) }
        return next.isEmpty ? Set(all) : next
    }

    /// Reset every filter (not search/sort) to all-selected (= no filter).
    func resetFilters() {
        selectedTypes = Set(WorkshopContentTypeFilter.selectableCases)
        selectedAgeRatings = WorkshopAgeRatingFilter.defaultSelection
        selectedResolutions = Set(WorkshopResolutionFilter.selectableCases)
        selectedGenres = Set(WorkshopGenre.allTags)
        persistFilters()
        scheduleAutoApply()
    }

    // MARK: - Persistence

    private enum FilterKey {
        static let types = "loomscreen.workshop.filter.types.v1"
        static let ages = "loomscreen.workshop.filter.ages.v1"
        static let resolutions = "loomscreen.workshop.filter.resolutions.v1"
        static let genres = "loomscreen.workshop.filter.genres.v1"
    }

    private func persistFilters() {
        defaults.set(selectedTypes.map(\.rawValue), forKey: FilterKey.types)
        defaults.set(selectedAgeRatings.map(\.rawValue), forKey: FilterKey.ages)
        defaults.set(selectedResolutions.map(\.rawValue), forKey: FilterKey.resolutions)
        defaults.set(Array(selectedGenres), forKey: FilterKey.genres)
    }

    /// Restores one persisted category. An empty result — written by a build
    /// before `toggled()` snapped back, or raw values that no longer decode —
    /// would render every chip struck through while the request filters
    /// nothing, so it snaps back to all-selected the same way `toggled()` does.
    nonisolated static func restoredSelection<T: Hashable>(
        raw: [String],
        all: [T],
        decode: (String) -> T?
    ) -> Set<T> {
        let decoded = Set(raw.compactMap(decode)).intersection(Set(all))
        return decoded.isEmpty ? Set(all) : decoded
    }

    private func loadPersistedFilters() {
        if let raw = defaults.array(forKey: FilterKey.types) as? [String] {
            selectedTypes = Self.restoredSelection(
                raw: raw,
                all: WorkshopContentTypeFilter.selectableCases,
                decode: WorkshopContentTypeFilter.init(rawValue:)
            )
        }
        if let raw = defaults.array(forKey: FilterKey.ages) as? [String] {
            selectedAgeRatings = Self.restoredSelection(
                raw: raw,
                all: WorkshopAgeRatingFilter.allCases,
                decode: WorkshopAgeRatingFilter.init(rawValue:)
            )
        }
        if let raw = defaults.array(forKey: FilterKey.resolutions) as? [String] {
            selectedResolutions = Self.restoredSelection(
                raw: raw,
                all: WorkshopResolutionFilter.selectableCases,
                decode: WorkshopResolutionFilter.init(rawValue:)
            )
        }
        if let raw = defaults.array(forKey: FilterKey.genres) as? [String] {
            selectedGenres = Self.restoredSelection(
                raw: raw,
                all: WorkshopGenre.allTags,
                decode: { $0 }
            )
        }
    }

    /// Returns `true` on a successful page load.
    @discardableResult
    private func runFetch(_ request: WorkshopQueryRequest, replacingItems: Bool, paging: Bool) async -> Bool {
        currentRequestToken &+= 1
        let token = currentRequestToken
        let task = Task { [weak self] () -> Bool in
            guard let self else { return false }
            var succeeded = false
            do {
                // With a key, QueryFiles stays the path: richer fields and a
                // real result total. Without one, fall back to the public page.
                let page = self.usesKeylessSearch
                    ? try await self.publicSource.fetch(request)
                    : try await self.services.queryService.fetch(request)
                guard token == self.currentRequestToken else { return false }
                if replacingItems {
                    items = Self.displayable(page.items, showsPresets: showsWorkshopPresets)
                    lastFetchedRawItemCount = page.items.count
                    hasLoadedPage = true
                }
                self.hasMoreKeylessPages = self.usesKeylessSearch && page.nextCursor != nil
                self.totalAvailable = page.totalAvailable
                self.lastError = nil
                self.rateLimitUntil = nil
                succeeded = true
                if !usesKeylessSearch {
                    Task { [weak self] in
                        await self?.mergeCreatorNames(into: page, request: request, token: token)
                    }
                }
            } catch let error as WorkshopQueryError {
                guard token == self.currentRequestToken else { return false }
                self.lastError = error
                if case .rateLimited(let retryAfter) = error {
                    self.rateLimitUntil = Date().addingTimeInterval(retryAfter ?? 60)
                }
                // `reload` no longer blanks the grid up front, so a failed one
                // has to drop the page it was replacing — otherwise the error
                // state (gated on an empty grid) never shows and the old
                // filter's results stay on screen. Paging keeps its results.
                if replacingItems, !paging {
                    items = []
                    lastFetchedRawItemCount = 0
                }
            } catch is CancellationError {
            } catch {
                guard token == self.currentRequestToken else { return false }
                self.lastError = .responseParseFailure
                if replacingItems, !paging {
                    items = []
                    lastFetchedRawItemCount = 0
                }
            }
            guard token == self.currentRequestToken else { return false }
            if paging {
                self.isPaging = false
            } else {
                self.isLoading = false
            }
            return succeeded
        }
        inflightFetch = task
        return await task.value
    }

    /// Second phase of a keyed fetch: personas arrive after the grid has already
    /// painted. Gated on the same token as the page, so names from a superseded
    /// request can never be painted onto the page that replaced it.
    private func mergeCreatorNames(
        into page: WorkshopQueryPage,
        request: WorkshopQueryRequest,
        token: UInt64
    ) async {
        let names = await services.queryService.resolveCreatorNames(for: page, request: request)
        guard token == currentRequestToken, !names.isEmpty else { return }
        items = items.map { item in
            guard let id = item.creatorID, let name = names[id] else { return item }
            var copy = item
            copy.creatorPersonaName = name
            return copy
        }
    }

    /// Normal browse already excludes `Application`/`Preset` server-side (no-op
    /// here); the creator-scoped GetUserFiles path can't, so this enforces it client-side.
    private static func displayable(_ items: [WorkshopQueryItem], showsPresets: Bool) -> [WorkshopQueryItem] {
        let excluded = excludedTags(showsPresets: showsPresets)
        return items.filter { item in
            !item.tags.contains { tag in
                excluded.contains { tag.caseInsensitiveCompare($0) == .orderedSame }
            }
        }
    }

    /// Read fresh on every request: Settings → Workshop writes straight to
    /// `GlobalSettings`, with no push into this view model.
    private var showsWorkshopPresets: Bool {
        SettingsManager.shared.loadGlobalSettings().showsWorkshopPresetsInBrowse
    }

    func makeRequest(page: Int) -> WorkshopQueryRequest {
        if let creatorFilter {
            // GetUserFiles ignores this field (protobuf default sorts by
            // lastupdated); it only feeds the cache key, so name the truth.
            return WorkshopQueryRequest(
                sort: .lastUpdated,
                page: page,
                numPerPage: perPage,
                excludedTags: excludedFilterTags(),
                creatorSteamID: creatorFilter.steamID
            )
        }

        if let pinnedTag {
            return WorkshopQueryRequest(
                sort: preferredSort,
                searchText: "",
                page: page,
                numPerPage: perPage,
                timeFrame: preferredTimeFrame,
                requiredTags: [pinnedTag],
                excludedTags: excludedFilterTags()
            )
        }

        let trimmed = searchInput.trimmingCharacters(in: .whitespacesAndNewlines)

        // The public browse page has no `match_all_tags`, so several
        // `requiredtags[]` there cannot be stated as "any of"; the keyless path
        // keeps the exclusion form it had before the keyed path switched.
        let keyless = usesKeylessSearch
        return WorkshopQueryRequest(
            sort: preferredSort,
            searchText: trimmed,
            page: page,
            numPerPage: perPage,
            timeFrame: preferredTimeFrame,
            requiredTags: keyless ? [] : selectedGenreTags(),
            // Genre is the only multi-valued facet — a wallpaper can be Anime
            // AND Landscape — so a genre selection matches ANY of them.
            matchAllTags: false,
            excludedTags: excludedFilterTags() + (keyless ? deselectedGenreTags() : [])
        )
    }

    /// Type / maturity / resolution partition their items (each carries exactly
    /// one), so a narrowed selection is exactly the deselected tags excluded.
    /// Genre does not partition and is handled by `selectedGenreTags()`.
    private func excludedFilterTags() -> [String] {
        var excluded: [String] = []
        excluded += deselectedTags(in: selectedTypes, all: WorkshopContentTypeFilter.selectableCases) { $0.tag }
        excluded += deselectedTags(in: selectedAgeRatings, all: WorkshopAgeRatingFilter.allCases) { $0.tag }
        excluded += deselectedTags(in: selectedResolutions, all: WorkshopResolutionFilter.selectableCases) { $0.tag }
        excluded += Self.excludedTags(showsPresets: showsWorkshopPresets)
        return excluded
    }

    /// Empty when the category is fully selected or fully empty (both = "no filter").
    private func deselectedTags<T: Hashable>(
        in selected: Set<T>,
        all: [T],
        tag: (T) -> String?
    ) -> [String] {
        guard !selected.isEmpty, selected.count < all.count else { return [] }
        return all.filter { !selected.contains($0) }.compactMap(tag)
    }

    private func selectedGenreTags() -> [String] {
        guard !selectedGenres.isEmpty, selectedGenres.count < WorkshopGenre.allTags.count else { return [] }
        return WorkshopGenre.allTags.filter { selectedGenres.contains($0) }
    }

    /// Keyless form of the genre narrowing: the unselected genres, excluded.
    private func deselectedGenreTags() -> [String] {
        deselectedTags(in: selectedGenres, all: WorkshopGenre.allTags) { $0 }
    }
}
#endif
