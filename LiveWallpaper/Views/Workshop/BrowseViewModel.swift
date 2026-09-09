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

    /// Everyone only. The signed-out Workshop page hides Questionable and
    /// Mature (about 18% of the catalog), so browsing them by default is both a
    /// surprise and the reason a side-by-side with the website disagrees;
    /// the two chips turn them back on.
    static let defaultSelection: Set<WorkshopAgeRatingFilter> = [.everyone]
}

extension WorkshopQueryItem {
    /// True when the item carries Wallpaper Engine's `Mature` maturity tag.
    var isMatureRated: Bool {
        Self.isMatureRated(tags: tags)
    }

    static func isMatureRated(tags: [String]) -> Bool {
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

/// Steam's Miscellaneous facet, in the page's order, minus `Asset Pack` (that
/// one is Category: Asset, always excluded). Opt-in and all-of: every selected
/// tag is required, an empty selection filters nothing — see `makeRequest`.
enum WorkshopMiscellaneousFilter {
    static let allTags: [String] = [
        "Approved", "Audio responsive", "3D", "Customizable", "Puppet Warp", "HDR",
        "Media Integration", "User Shortcut", "Video Texture",
    ]
}

/// Buckets over Steam's 25 Resolution tags: a chip per bucket, and a narrowed
/// selection excludes every tag of every unselected bucket. Raw values are
/// persisted (`FilterKey.resolutions`), so the pre-bucket names stay.
enum WorkshopResolutionFilter: String, CaseIterable, Identifiable {
    case any
    case standardDefinition
    case hd = "fullHD1080"
    case quadHD1440
    case ultraHD4K
    case ultrawide
    case dual
    case triple
    case portrait
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .any:
            String(localized: "All", bundle: .appLanguage, comment: "Workshop resolution filter: no restriction.")
        case .standardDefinition:
            String(localized: "SD", bundle: .appLanguage, comment: "Workshop resolution filter: standard definition.")
        case .hd:
            String(localized: "HD", bundle: .appLanguage, comment: "Workshop resolution filter: 720p to 1080p.")
        case .quadHD1440:
            String(localized: "2K", bundle: .appLanguage, comment: "Workshop resolution filter: 2560 x 1440.")
        case .ultraHD4K:
            String(localized: "4K", bundle: .appLanguage, comment: "Workshop resolution filter.")
        case .ultrawide:
            String(localized: "Ultrawide", bundle: .appLanguage, comment: "Workshop resolution filter: ultrawide displays.")
        case .dual:
            String(localized: "Dual Monitor", bundle: .appLanguage, comment: "Workshop resolution filter: two-display layouts.")
        case .triple:
            String(localized: "Triple Monitor", bundle: .appLanguage, comment: "Workshop resolution filter: three-display layouts.")
        case .portrait:
            String(localized: "Portrait", bundle: .appLanguage, comment: "Workshop resolution filter.")
        case .other:
            String(localized: "Other resolutions", bundle: .appLanguage, comment: "Workshop resolution filter: other and dynamic resolutions.")
        }
    }

    static var selectableCases: [WorkshopResolutionFilter] { allCases.filter { $0 != .any } }

    /// Exact Steam Workshop resolution tags in this bucket (verbatim, Steam
    /// matches on exact case); empty for `.any`.
    var tags: [String] {
        switch self {
        case .any: []
        case .standardDefinition: ["Standard Definition"]
        case .hd: ["1280 x 720", "1366 x 768", "1920 x 1080"]
        case .quadHD1440: ["2560 x 1440"]
        case .ultraHD4K: ["3840 x 2160"]
        case .ultrawide: ["Ultrawide Standard Definition", "Ultrawide 2560 x 1080", "Ultrawide 3440 x 1440"]
        case .dual: ["Dual Standard Definition", "Dual 3840 x 1080", "Dual 5120 x 1440", "Dual 7680 x 2160"]
        case .triple: ["Triple Standard Definition", "Triple 4096 x 768", "Triple 5760 x 1080", "Triple 7680 x 1440", "Triple 11520 x 2160"]
        case .portrait: ["Portrait Standard Definition", "Portrait 720 x 1280", "Portrait 1080 x 1920", "Portrait 1440 x 2560", "Portrait 2160 x 3840"]
        case .other: ["Other resolution", "Dynamic resolution"]
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
    /// runtime, and Asset packs are editor material, not wallpapers — never
    /// surface either (server-side exclusion, not post-filter).
    nonisolated static let alwaysExcludedTags = ["Application", "Asset"]

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
                preferredSort = defaultSort
            }
            scheduleAutoApply()
        }
    }
    /// Which text fields the search matches. Persisted like the chip rows,
    /// but not a filter: `resetFilters` and the Filters badge leave it alone.
    var searchTextTarget: WorkshopSearchTextTarget = .all {
        didSet {
            guard searchTextTarget != oldValue else { return }
            defaults.set(searchTextTarget.rawValue, forKey: FilterKey.searchTextTarget)
            scheduleAutoApply()
        }
    }

    var preferredSort: WorkshopSortMode
    /// Settings → Workshop's default sort: it seeds `preferredSort` and is
    /// where clearing a Relevance search lands. Re-read on `onAppear()`.
    @ObservationIgnored private var defaultSort: WorkshopSortMode
    /// The pane keeps one view model for the process; a sort or window the
    /// user picked in this session outranks a default changed in Settings.
    @ObservationIgnored private var userChangedSortThisSession = false
    private(set) var selectedTypes: Set<WorkshopContentTypeFilter> = Set(WorkshopContentTypeFilter.selectableCases)
    private(set) var selectedAgeRatings: Set<WorkshopAgeRatingFilter> = WorkshopAgeRatingFilter.defaultSelection
    private(set) var selectedResolutions: Set<WorkshopResolutionFilter> = Set(WorkshopResolutionFilter.selectableCases)
    private(set) var selectedGenres: Set<String> = Set(WorkshopGenre.allTags)
    /// Empty means no feature is required — the opposite default from the rows above.
    private(set) var selectedMiscellaneous: Set<String> = []
    private(set) var preferredTimeFrame: WorkshopTimeFrame
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
    /// Steam's own page count for the current query (`WorkshopQueryPage.totalPages`).
    private(set) var reportedTotalPages: Int?
    private(set) var isLoading: Bool = false
    /// True while paging — current results stay on screen until the new page
    /// replaces them, so memory stays bounded.
    private(set) var isPaging: Bool = false
    private(set) var lastError: WorkshopQueryError?
    /// Set when Steam returns HTTP 429; controls stay disabled until it lapses.
    private(set) var rateLimitUntil: Date?

    /// True when no Steam Web API key is stored, or Valve rejected the stored
    /// one: browse then runs off Valve's public Workshop page (ids only) plus
    /// the key-free metadata endpoint.
    var usesKeylessSearch: Bool {
        services.isKeyless
    }

    /// The Browse banner for a key Valve rejected. Stays up across reloads
    /// until dismissed; goes away by itself once the rejection is cleared (a
    /// new key saved and validated). Keyed on the rejected key's fingerprint so
    /// dismissing it does not also hide a later rejection of a different key.
    var showsKeyRejectedNotice: Bool {
        services.apiKeyRejected && services.rejectedKeyFingerprint != dismissedRejectionFingerprint
    }

    private var dismissedRejectionFingerprint: String?

    func dismissKeyRejectedNotice() {
        dismissedRejectionFingerprint = services.rejectedKeyFingerprint
    }

    /// QueryFiles lets us ask for 50; the public page is fixed at 30.
    private var perPage: Int {
        usesKeylessSearch ? WorkshopPublicBrowseURL.itemsPerPage : 50
    }

    /// The public page publishes no result total, so "is there a next page" can
    /// only come from the page having yielded ids at all.
    private(set) var hasMoreKeylessPages: Bool = false

    /// 1-based. Steam's QueryFiles `page` param lets us jump to any page directly.
    private(set) var pageIndex: Int = 1
    /// Target of the last page turn that failed, for the pager's Retry; nil
    /// once a page loads or a reload starts.
    private(set) var failedPageTarget: Int?

    var isRateLimited: Bool {
        (rateLimitUntil ?? .distantPast) > Date()
    }

    /// A page turn failed while the previous page stayed on screen — the
    /// empty-grid error state is gated on `items.isEmpty` and cannot show it.
    var showsPagingError: Bool {
        lastError != nil && (!items.isEmpty || currentPageIsFilteredOut)
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
        if let reported = reportedTotalPages, reported > 0 {
            return min(Self.maxQueryPage, reported)
        }
        guard let total = totalAvailable, total > 0 else { return nil }
        return Self.pageCount(totalAvailable: total, perPage: perPage)
    }

    /// Steam answered this page with items, or reports other pages, yet nothing
    /// survived the client-side drop — the pager has to stay reachable, unlike
    /// a query with no results at all. A later page that came back empty (no
    /// total to say so up front) is the same case: the reader paged here and
    /// has to be able to page back.
    var currentPageIsFilteredOut: Bool {
        hasLoadedPage && items.isEmpty && (lastFetchedRawItemCount > 0 || (totalPages ?? 0) > 1 || pageIndex > 1)
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

    /// `WorkshopQueryPage.sourceItemCount` of the last fetched page — before
    /// Steam's shells and `displayable`'s Application / Preset drop: counting
    /// `items` instead greys out Next on a full page that happened to contain
    /// one filtered item.
    var lastFetchedRawItemCount: Int = 0

    var canGoPrevPage: Bool {
        !isRateLimited && !isLoading && !isPaging && pageIndex > 1
    }

    @ObservationIgnored private var inflightFetch: Task<Bool, Never>?
    @ObservationIgnored private var currentRequestToken: UInt64 = 0
    @ObservationIgnored private var autoSearchTask: Task<Void, Never>?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let loadGlobalSettings: @MainActor () -> GlobalSettings
    @ObservationIgnored private let injectedPublicSource: WorkshopPublicSearchSource?
    /// Built on first keyless fetch — it owns a `URLSession`, so a keyed session never makes one.
    @ObservationIgnored private lazy var publicSource: WorkshopPublicSearchSource = injectedPublicSource ?? WorkshopPublicSearchSource()

    /// Quiet window after the last keystroke before auto-search fires: long
    /// enough that mid-word states don't burn API quota, short enough to feel live.
    private static let searchDebounce: Duration = .milliseconds(500)

    /// True when pending filter/search state differs from what's displayed —
    /// gates the debounced auto-search.
    var hasPendingChanges: Bool {
        makeRequest(page: 1) != currentRequest
    }

    init(
        services: WorkshopServices,
        defaults: UserDefaults = .appScoped(),
        loadGlobalSettings: @escaping @MainActor () -> GlobalSettings = { SettingsManager.shared.loadGlobalSettings() },
        publicSource: WorkshopPublicSearchSource? = nil
    ) {
        self.services = services
        self.defaults = defaults
        self.loadGlobalSettings = loadGlobalSettings
        injectedPublicSource = publicSource
        let globalSettings = loadGlobalSettings()
        defaultSort = Self.defaultSort(from: globalSettings.workshopDefaultSort)
        preferredSort = defaultSort
        preferredTimeFrame = Self.defaultTimeFrame(from: globalSettings.workshopDefaultTimeFrame)
        self.currentRequest = WorkshopQueryRequest(sort: .topRated, timeFrame: .allTime)
        loadPersistedFilters()
        self.currentRequest = makeRequest(page: 1)
    }

    /// `GlobalSettings` stores the raw values as strings (the enums live here,
    /// not in Core). Relevance needs a search text, so it cannot be a default.
    nonisolated static func defaultSort(from raw: String) -> WorkshopSortMode {
        guard let sort = WorkshopSortMode(rawValue: raw), sort != .search else { return .mostPopular }
        return sort
    }

    /// All Time is not a window (`days == nil`); Most Popular has no such thing.
    nonisolated static func defaultTimeFrame(from raw: String) -> WorkshopTimeFrame {
        guard let timeFrame = WorkshopTimeFrame(rawValue: raw), timeFrame.days != nil else { return .oneWeek }
        return timeFrame
    }

    func onAppear() {
        if applySettingsDefaults() || (items.isEmpty && lastError == nil) {
            Task { await reload() }
        }
    }

    /// Returns `true` when Settings → Workshop's defaults changed since they
    /// were last applied and the user has not picked a sort this session.
    private func applySettingsDefaults() -> Bool {
        guard !userChangedSortThisSession else { return false }
        let settings = loadGlobalSettings()
        let sort = Self.defaultSort(from: settings.workshopDefaultSort)
        let timeFrame = Self.defaultTimeFrame(from: settings.workshopDefaultTimeFrame)
        guard sort != defaultSort || timeFrame != preferredTimeFrame else { return false }
        defaultSort = sort
        preferredSort = sort
        preferredTimeFrame = timeFrame
        return true
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
        reportedTotalPages = nil
        hasMoreKeylessPages = false
        isLoading = true
        isPaging = false
        lastError = nil
        failedPageTarget = nil
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
        // Not `!ok` alone: a superseded fetch also returns false, without a failure.
        failedPageTarget = (!ok && lastError != nil) ? clamped : nil
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

    /// `WorkshopServices.isKeyless` flipped either way. The keyless creator
    /// page ignores `excludedtags` and states no total, so a creator scope is
    /// left rather than carried over to it.
    func browsePathChanged() async {
        if usesKeylessSearch, creatorFilter != nil {
            creatorFilter = nil
        }
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

    /// Test seam: the outcome of a page fetch, without a transport.
    func applyPageForTesting(sourceItemCount: Int, totalPages: Int?, pageIndex: Int = 1) {
        items = []
        lastFetchedRawItemCount = sourceItemCount
        reportedTotalPages = totalPages
        hasLoadedPage = true
        self.pageIndex = pageIndex
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
        userChangedSortThisSession = true
        preferredSort = sort
        scheduleAutoApply()
    }

    /// Mirrors the page: its trend sort has no all-time window, so choosing
    /// All Time there switches to Top Rated (All Time) and keeps the window.
    func updateTimeFrame(_ timeFrame: WorkshopTimeFrame) {
        userChangedSortThisSession = true
        if timeFrame == .allTime, preferredSort == .mostPopular {
            preferredSort = .topRated
        } else {
            preferredTimeFrame = timeFrame
        }
        scheduleAutoApply()
    }

    func toggleType(_ type: WorkshopContentTypeFilter) {
        selectedTypes = Self.toggled(type, in: selectedTypes, all: WorkshopContentTypeFilter.selectableCases)
        persistFilters()
        scheduleAutoApply()
    }

    func toggleAgeRating(_ rating: WorkshopAgeRatingFilter) {
        // Not `Set(all)`: maturity's snap-back is the Everyone default, so striking
        // out the last chip cannot be the gesture that switches Mature on.
        selectedAgeRatings = Self.toggled(
            rating, in: selectedAgeRatings, all: WorkshopAgeRatingFilter.allCases,
            fallback: WorkshopAgeRatingFilter.defaultSelection
        )
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

    /// A plain add/remove: `toggled()`'s snap-back would turn "no feature
    /// required" into "every feature required".
    func toggleMiscellaneous(_ tag: String) {
        if selectedMiscellaneous.contains(tag) {
            selectedMiscellaneous.remove(tag)
        } else {
            selectedMiscellaneous.insert(tag)
        }
        persistFilters()
        scheduleAutoApply()
    }

    func isolateType(_ type: WorkshopContentTypeFilter) {
        selectedTypes = isolated(type, in: selectedTypes, all: WorkshopContentTypeFilter.selectableCases)
        persistFilters()
        scheduleAutoApply()
    }

    func isolateAgeRating(_ rating: WorkshopAgeRatingFilter) {
        selectedAgeRatings = isolated(
            rating, in: selectedAgeRatings, all: WorkshopAgeRatingFilter.allCases,
            fallback: WorkshopAgeRatingFilter.defaultSelection
        )
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

    private func isolated<T: Hashable>(
        _ option: T, in current: Set<T>, all: [T], fallback: Set<T>? = nil
    ) -> Set<T> {
        if current.count == 1, current.contains(option) {
            return fallback ?? Set(all)
        }
        return [option]
    }

    /// Deselecting the last chip snaps back to all-selected: an empty set means
    /// "no filter" at the request layer, but every chip struck through reads as
    /// "exclude everything" in the UI — same snap-back idiom as `isolated()`.
    nonisolated static func toggled<T: Hashable>(
        _ option: T, in current: Set<T>, all: [T], fallback: Set<T>? = nil
    ) -> Set<T> {
        var next = current
        if next.contains(option) {
            next.remove(option)
        } else {
            next.insert(option)
        }
        return next.isEmpty ? (fallback ?? Set(all)) : next
    }

    /// Reset every filter (not search/sort) to all-selected (= no filter).
    func resetFilters() {
        selectedTypes = Set(WorkshopContentTypeFilter.selectableCases)
        selectedAgeRatings = WorkshopAgeRatingFilter.defaultSelection
        selectedResolutions = Set(WorkshopResolutionFilter.selectableCases)
        selectedGenres = Set(WorkshopGenre.allTags)
        selectedMiscellaneous = []
        persistFilters()
        scheduleAutoApply()
    }

    // MARK: - Persistence

    private enum FilterKey {
        static let types = "loomscreen.workshop.filter.types.v1"
        /// v1 stored the old "all three selected" default, which now reads as a
        /// deliberate opt-in to mature content; v2 starts over at Everyone.
        static let ages = "loomscreen.workshop.filter.ages.v2"
        static let retiredAgesV1 = "loomscreen.workshop.filter.ages.v1"
        /// v1 held seven buckets; read against nine, its "everything" is a
        /// narrowing that drops Triple and Other, so v2 starts over.
        static let resolutions = "loomscreen.workshop.filter.resolutions.v2"
        static let retiredResolutionsV1 = "loomscreen.workshop.filter.resolutions.v1"
        static let genres = "loomscreen.workshop.filter.genres.v1"
        static let miscellaneous = "loomscreen.workshop.filter.miscellaneous.v1"
        static let searchTextTarget = "loomscreen.workshop.filter.searchTextTarget.v1"
    }

    private func persistFilters() {
        defaults.set(selectedTypes.map(\.rawValue), forKey: FilterKey.types)
        defaults.set(selectedAgeRatings.map(\.rawValue), forKey: FilterKey.ages)
        defaults.set(selectedResolutions.map(\.rawValue), forKey: FilterKey.resolutions)
        defaults.set(Array(selectedGenres), forKey: FilterKey.genres)
        defaults.set(Array(selectedMiscellaneous), forKey: FilterKey.miscellaneous)
    }

    /// Restores one persisted category. An empty result — written by a build
    /// before `toggled()` snapped back, or raw values that no longer decode —
    /// would render every chip struck through while the request filters
    /// nothing, so it snaps back to all-selected the same way `toggled()` does.
    nonisolated static func restoredSelection<T: Hashable>(
        raw: [String],
        all: [T],
        fallback: Set<T>? = nil,
        decode: (String) -> T?
    ) -> Set<T> {
        let decoded = Set(raw.compactMap(decode)).intersection(Set(all))
        return decoded.isEmpty ? (fallback ?? Set(all)) : decoded
    }

    private func loadPersistedFilters() {
        if let raw = defaults.array(forKey: FilterKey.types) as? [String] {
            selectedTypes = Self.restoredSelection(
                raw: raw,
                all: WorkshopContentTypeFilter.selectableCases,
                decode: WorkshopContentTypeFilter.init(rawValue:)
            )
        }
        defaults.removeObject(forKey: FilterKey.retiredAgesV1)
        if let raw = defaults.array(forKey: FilterKey.ages) as? [String] {
            selectedAgeRatings = Self.restoredSelection(
                raw: raw,
                all: WorkshopAgeRatingFilter.allCases,
                fallback: WorkshopAgeRatingFilter.defaultSelection,
                decode: WorkshopAgeRatingFilter.init(rawValue:)
            )
        }
        defaults.removeObject(forKey: FilterKey.retiredResolutionsV1)
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
        // No snap-back here: an empty (or fully retired) selection is the default.
        if let raw = defaults.array(forKey: FilterKey.miscellaneous) as? [String] {
            selectedMiscellaneous = Set(raw).intersection(WorkshopMiscellaneousFilter.allTags)
        }
        if let target = WorkshopSearchTextTarget(rawValue: defaults.integer(forKey: FilterKey.searchTextTarget)) {
            searchTextTarget = target
        }
    }

    /// Returns `true` on a successful page load.
    @discardableResult
    private func runFetch(_ request: WorkshopQueryRequest, replacingItems: Bool, paging: Bool) async -> Bool {
        currentRequestToken &+= 1
        let token = currentRequestToken
        // Read once, with the request it shaped (`makeRequest` ran in this same
        // turn): a key rejected while the fetch is in flight must not have the
        // keyed page's metadata interpreted as the public page's.
        let keyless = usesKeylessSearch
        // Safety net under `browsePathChanged`: served by the public creator
        // page this request would be wrong (filters ignored, no total).
        if keyless, request.creatorSteamID != nil {
            lastError = .missingAPIKey
            if replacingItems, !paging {
                items = []
                lastFetchedRawItemCount = 0
            }
            if paging {
                isPaging = false
            } else {
                isLoading = false
            }
            return false
        }
        let task = Task { [weak self] () -> Bool in
            guard let self else { return false }
            var succeeded = false
            do {
                // With a key, QueryFiles stays the path: richer fields and a
                // real result total. Without one, fall back to the public page.
                let page = keyless
                    ? try await self.publicSource.fetch(request)
                    : try await self.services.queryService.fetch(request)
                guard token == self.currentRequestToken else { return false }
                if replacingItems {
                    items = Self.displayable(page.items, showsPresets: showsWorkshopPresets)
                    lastFetchedRawItemCount = page.sourceItemCount
                    hasLoadedPage = true
                }
                hasMoreKeylessPages = keyless && page.nextCursor != nil
                self.totalAvailable = page.totalAvailable
                reportedTotalPages = page.totalPages
                self.lastError = nil
                self.rateLimitUntil = nil
                succeeded = true
                if !keyless {
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
        loadGlobalSettings().showsWorkshopPresetsInBrowse
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
                miscellaneousTags: selectedMiscellaneousTags(),
                creatorSteamID: creatorFilter.steamID
            )
        }

        if let pinnedTag {
            // No search text here, so Relevance has nothing to rank against;
            // the request layer would fold it to Top Rated, bypassing Settings.
            return WorkshopQueryRequest(
                sort: preferredSort == .search ? defaultSort : preferredSort,
                searchText: "",
                page: page,
                numPerPage: perPage,
                timeFrame: preferredTimeFrame,
                requiredTags: [pinnedTag],
                excludedTags: excludedFilterTags(),
                miscellaneousTags: selectedMiscellaneousTags()
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
            searchTextTarget: searchTextTarget,
            page: page,
            numPerPage: perPage,
            timeFrame: preferredTimeFrame,
            requiredTags: keyless ? [] : selectedGenreTags(),
            // Genre is the only multi-valued facet — a wallpaper can be Anime
            // AND Landscape — so a genre selection matches ANY of them.
            matchAllTags: false,
            excludedTags: excludedFilterTags() + (keyless ? deselectedGenreTags() : []),
            miscellaneousTags: selectedMiscellaneousTags()
        )
    }

    private func selectedMiscellaneousTags() -> [String] {
        WorkshopMiscellaneousFilter.allTags.filter { selectedMiscellaneous.contains($0) }
    }

    /// Type / maturity / resolution partition their items (each carries exactly
    /// one), so a narrowed selection is exactly the deselected tags excluded.
    /// Genre does not partition and is handled by `selectedGenreTags()`.
    private func excludedFilterTags() -> [String] {
        var excluded: [String] = []
        excluded += deselected(in: selectedTypes, all: WorkshopContentTypeFilter.selectableCases).compactMap(\.tag)
        excluded += deselected(in: selectedAgeRatings, all: WorkshopAgeRatingFilter.allCases).map(\.tag)
        excluded += deselected(in: selectedResolutions, all: WorkshopResolutionFilter.selectableCases).flatMap(\.tags)
        excluded += Self.excludedTags(showsPresets: showsWorkshopPresets)
        return excluded
    }

    /// Empty when the category is fully selected or fully empty (both = "no filter").
    private func deselected<T: Hashable>(in selected: Set<T>, all: [T]) -> [T] {
        guard !selected.isEmpty, selected.count < all.count else { return [] }
        return all.filter { !selected.contains($0) }
    }

    private func selectedGenreTags() -> [String] {
        guard !selectedGenres.isEmpty, selectedGenres.count < WorkshopGenre.allTags.count else { return [] }
        return WorkshopGenre.allTags.filter { selectedGenres.contains($0) }
    }

    /// Keyless form of the genre narrowing: the unselected genres, excluded.
    private func deselectedGenreTags() -> [String] {
        deselected(in: selectedGenres, all: WorkshopGenre.allTags)
    }
}
#endif
