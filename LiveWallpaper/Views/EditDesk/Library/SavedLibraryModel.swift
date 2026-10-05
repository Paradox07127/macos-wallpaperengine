import Combine
import CoreGraphics
import Foundation
import LiveWallpaperCore
import Observation

@MainActor @Observable
final class SavedLibraryModel {
    enum Chip: CaseIterable { case all, bookmarks, recent, steam, local, aerials }
    enum Sort: CaseIterable {
        case recentlyUsed, name, type, size
        #if !LITE_BUILD
        case needsUpdate
        #endif
    }

    enum Filter: Hashable {
        case unsupported
        #if !LITE_BUILD
        case storage(InstalledStorageKind)
        #endif
    }

    struct AerialsState {
        var assets: [AerialAsset] = []
        var isAuthorized = false
        var lastScanError: String?
        var isScanning = false
        var isEmpty: Bool {
            assets.isEmpty
        }
    }

    struct Inputs {
        var bookmarks: @MainActor () -> [WallpaperBookmark] = { [] }
        var aerials: @MainActor () -> AerialsState = { AerialsState() }
        /// The row IDs the user marked as bookmarks.
        var libraryBookmarks: @MainActor () -> Set<LibraryItem.ID> = { [] }
        /// Moves a stored mark from the first row ID to the second.
        var remapLibraryBookmark: @MainActor (LibraryItem.ID, LibraryItem.ID) -> Void = { _, _ in }
        #if !LITE_BUILD
        var history: @MainActor () -> [WPEHistoryEntry] = { [] }
        /// Content is nil for installed rows, which match by origin instead.
        var nowPlaying: @MainActor (WallpaperContent?, WPEHistoryEntry?) -> [CGDirectDisplayID] = { _, _ in [] }
        var workshopContent: @MainActor (WPEHistoryEntry) -> WallpaperContent? = { _ in nil }
        /// The revision of the saved cover of the import `entry` shows; nil while it has none.
        var workshopCoverRevision: @MainActor (WPEHistoryEntry) -> Int? = { _ in nil }
        /// The `tags` of a project's `project.json`; empty when the file cannot be read.
        var projectTags: @MainActor (WPEOrigin) async -> [String] = { _ in [] }
        #else
        var nowPlaying: @MainActor (WallpaperContent) -> [CGDirectDisplayID] = { _ in [] }
        #endif
        var metadata: @MainActor (WallpaperBookmark) -> LibraryMetadata? = { _ in nil }
        var probeMetadata: @MainActor (WallpaperBookmark) async -> LibraryMetadata? = { _ in nil }
        /// Every cover a bookmark, a scheme or a listed Workshop import still points at — not the filtered view,
        /// whose misses would read as orphans.
        var savedCoverFileNames: @MainActor () -> Set<String> = { [] }
        var removeOrphanCovers: @MainActor (Set<String>) -> Void = { _ in }
        /// False when the file or folder behind a row is gone or no longer granted.
        var sourceAvailable: @MainActor (LibraryItem.Source) async -> Bool = { _ in true }
        /// Starts a scan when Apple Aerials is granted but lists nothing yet.
        var scanAerials: @MainActor () -> Void = {}
        /// What each configured display runs.
        var activeWallpapers: @MainActor () -> [(display: CGDirectDisplayID, content: WallpaperContent)] = { [] }
        /// The file a video bookmark resolves to; nil when it does not resolve.
        var filePath: @MainActor (Data) -> String? = { _ in nil }

        @MainActor
        static func live(screenManager: ScreenManager) -> Inputs {
            let sidecar = LibraryMetadataSidecar()
            var inputs = Inputs()
            inputs.bookmarks = { BookmarkStore.shared.bookmarks }
            inputs.libraryBookmarks = { Set(LibraryBookmarkStore.shared.ids) }
            inputs.remapLibraryBookmark = { old, new in
                LibraryBookmarkStore.shared.merge([new])
                LibraryBookmarkStore.shared.remove(old)
            }
            inputs.aerials = {
                let library = AppleAerialsLibrary.shared
                return AerialsState(
                    assets: library.assets, isAuthorized: library.isAuthorized,
                    lastScanError: library.lastScanError, isScanning: library.isScanning
                )
            }
            #if !LITE_BUILD
            inputs.history = { SettingsManager.shared.loadGlobalSettings().recentWPEImports }
            inputs.workshopContent = { WPECachedContentResolver().content(for: $0.origin) }
            inputs.workshopCoverRevision = { entry in
                WallpaperCoverStore.workshopFileName(workshopID: entry.origin.workshopID, importedAt: entry.importedAt)
                    .flatMap { WallpaperCoverStore.shared.revision(of: $0) }
            }
            inputs.projectTags = { await loadWPEProjectTags(for: $0) }
            inputs.nowPlaying = { content, entry in
                screenManager.screens.compactMap { screen in
                    guard let configuration = screenManager.getConfiguration(for: screen) else { return nil }
                    if let entry {
                        return configuration.wpeOrigin?.workshopID == entry.origin.workshopID ? screen.id : nil
                    }
                    return configuration.activeWallpaper == content ? screen.id : nil
                }
            }
            #else
            inputs.nowPlaying = { content in
                screenManager.screens.compactMap { screen in
                    screenManager.getConfiguration(for: screen)?.activeWallpaper == content ? screen.id : nil
                }
            }
            #endif
            inputs.metadata = { sidecar.cached(for: $0) }
            inputs.probeMetadata = { await sidecar.metadata(for: $0) }
            inputs.savedCoverFileNames = { WallpaperCoverStore.keptFileNames() }
            inputs.removeOrphanCovers = { WallpaperCoverStore.shared.removeOrphans(keeping: $0) }
            inputs.sourceAvailable = { source in
                switch source {
                case let .bookmark(bookmark):
                    await LibraryContentLocator.locate(content: bookmark.content, wpeOrigin: bookmark.wpeOrigin).isAvailable
                case let .aerial(asset):
                    await LibraryContentLocator.locate(content: .video(bookmarkData: asset.bookmarkData), wpeOrigin: nil).isAvailable
                #if !LITE_BUILD
                case let .workshop(entry):
                    await LibraryContentLocator.locate(folderBookmark: entry.origin.sourceFolderBookmark).isAvailable
                #endif
                }
            }
            inputs.scanAerials = {
                let library = AppleAerialsLibrary.shared
                if library.isAuthorized, library.assets.isEmpty {
                    Task { await library.refresh() }
                }
            }
            inputs.activeWallpapers = {
                screenManager.screens.compactMap { screen in
                    screenManager.getConfiguration(for: screen).map { (screen.id, $0.activeWallpaper) }
                }
            }
            inputs.filePath = ApplyRouter.resolvedPath
            return inputs
        }
    }

    var chip: Chip = .all

    var sort: Sort = .recentlyUsed {
        didSet {
            guard sort != oldValue else { return }
            restartSizeMetadataProbe()
        }
    }

    var filter: Filter?
    #if !LITE_BUILD
    var updatedWorkshopIDs: Set<String> = []
    #endif
    var query = ""
    private(set) var items: [LibraryItem] = []
    private(set) var bookmarkedIDs: Set<LibraryItem.ID> = []
    private(set) var aerialsStatus = AerialsState()
    /// Each row's last use when the current browse began; nil while none is open.
    private var usageSnapshot: [LibraryItem.ID: Date]?
    #if !LITE_BUILD
    private struct SearchTagSource: Hashable {
        let origin: WPEOrigin
        let importedAt: Date?

        /// `WPEOrigin` is only Equatable; equality still compares the whole origin.
        func hash(into hasher: inout Hasher) {
            hasher.combine(origin.workshopID)
            hasher.combine(importedAt)
        }
    }

    /// Project tags by source, from `loadSearchTags()`; empty while a read is in flight or when it failed.
    private var tagsBySource: [SearchTagSource: [String]] = [:]
    @ObservationIgnored private var searchTagSources: [LibraryItem.ID: SearchTagSource] = [:]
    #endif
    @ObservationIgnored private let inputs: Inputs
    /// Each row's source when it was last probed and whether it was found; nothing is resolved in `refresh()`.
    @ObservationIgnored private var probedSources: [LibraryItem.ID: (source: LibraryItem.Source, available: Bool)] = [:]
    /// Rows with a probe running and the round of the newest one; only that round records a result.
    @ObservationIgnored private var probesInFlight: [LibraryItem.ID: (source: LibraryItem.Source, round: Int)] = [:]
    @ObservationIgnored private var probeRound = 0
    /// Normalized `inputs.filePath` by bookmark bytes, a nil path included: resolving touches the file system.
    /// `refresh()` empties it, so a moved file or a bookmark that failed to resolve is read again.
    @ObservationIgnored private var filePaths: [Data: String?] = [:]
    @ObservationIgnored private var subscriptions: Set<AnyCancellable> = []
    @ObservationIgnored private var sizeMetadataTask: Task<Void, Never>?

    init(inputs: Inputs) {
        self.inputs = inputs
        refresh()
        var names: [Notification.Name] = [.wallpaperConfigurationDidChange]
        #if !LITE_BUILD
        names.append(.wpeHistoryDidChange)
        #endif
        for name in names {
            NotificationCenter.default.publisher(for: name)
                .sink { [weak self] _ in
                    Task { @MainActor [weak self] in self?.refresh() }
                }
                .store(in: &subscriptions)
        }
    }

    convenience init(screenManager: ScreenManager) {
        let inputs = Inputs.live(screenManager: screenManager)
        #if !LITE_BUILD
        Self.migrateFoldedBookmarks(
            inputs.bookmarks(), installed: Set(inputs.history().map(\.id)), into: .shared, defaults: .appScoped()
        )
        #endif
        self.init(inputs: inputs)
        observeStores()
    }

    /// Set once the Workshop rows standing in for saved entries have been marked; the marking never runs again.
    nonisolated static let bookmarksMigratedKey = "loomscreen.library.bookmarks.migrated.v1"

    #if !LITE_BUILD
    /// A saved entry of an installed project is listed as that project's row, unless overrides tune its scene.
    static func foldsIntoWorkshopRow(_ content: WallpaperContent) -> Bool {
        content.sceneDescriptor?.propertyOverrides.isEmpty ?? true
    }

    /// Whether `configuration` runs `entry` itself: not another copy under its Workshop ID, nor a variant tuning its scene.
    static func isRunning(_ entry: WPEHistoryEntry, in configuration: ScreenConfiguration) -> Bool {
        guard let origin = configuration.wpeOrigin, origin.workshopID == entry.origin.workshopID,
              origin.steamFolderItemID == entry.origin.steamFolderItemID else { return false }
        return foldsIntoWorkshopRow(configuration.activeWallpaper)
    }

    /// The rows of `installed` Workshop IDs that saved entries fold into, each once, in the entries' order.
    static func foldedBookmarkMarks(_ bookmarks: [WallpaperBookmark], installed: Set<String>) -> [LibraryItem.ID] {
        var marks: [LibraryItem.ID] = []
        for bookmark in bookmarks {
            guard let workshopID = bookmark.wpeOrigin?.workshopID, installed.contains(workshopID),
                  foldsIntoWorkshopRow(bookmark.content), !marks.contains("workshop:\(workshopID)") else { continue }
            marks.append("workshop:\(workshopID)")
        }
        return marks
    }

    static func migrateFoldedBookmarks(
        _ bookmarks: [WallpaperBookmark], installed: Set<String>, into marks: LibraryBookmarkStore, defaults: UserDefaults
    ) {
        guard !defaults.bool(forKey: bookmarksMigratedKey) else { return }
        marks.merge(foldedBookmarkMarks(bookmarks, installed: installed))
        guard !marks.hasStorageError else { return }
        defaults.set(true, forKey: bookmarksMigratedKey)
    }

    /// Each mark on a saved entry that is not listed because it folds into its project's listed row, paired with that row.
    static func foldedMarkMoves(
        _ marks: Set<LibraryItem.ID>, bookmarks: [WallpaperBookmark], rows: Set<LibraryItem.ID>
    ) -> [(from: LibraryItem.ID, to: LibraryItem.ID)] {
        bookmarks.compactMap { bookmark in
            let id = "bookmark:\(bookmark.id)"
            guard marks.contains(id), !rows.contains(id), let workshopID = bookmark.wpeOrigin?.workshopID,
                  foldsIntoWorkshopRow(bookmark.content), rows.contains("workshop:\(workshopID)") else { return nil }
            return (id, "workshop:\(workshopID)")
        }
    }
    #endif

    /// The row running what `configuration` shows: its saved entry, else the installed Workshop row a saved
    /// entry of it would fold into, else the aerial it plays; nil when the library has no such row.
    func itemID(showing configuration: ScreenConfiguration) -> LibraryItem.ID? {
        let content = configuration.activeWallpaper
        let saved = items.first { item in
            guard case let .bookmark(bookmark) = item.source else { return false }
            return bookmark.content == content
        }
        if let saved {
            return saved.id
        }
        #if !LITE_BUILD
        if let workshopID = configuration.wpeOrigin?.workshopID, Self.foldsIntoWorkshopRow(content),
           items.contains(where: { $0.id == "workshop:\(workshopID)" }) {
            return "workshop:\(workshopID)"
        }
        #endif
        return items.first { item in
            guard case let .aerial(asset) = item.source else { return false }
            return aerial(asset, matches: content)
        }?.id
    }

    /// `BookmarkStore`, `LibraryBookmarkStore` and `AppleAerialsLibrary` only persist; nothing posts a notification
    /// for an add / remove / rename, so the live model tracks them through Observation.
    func observeStores() {
        withObservationTracking {
            _ = BookmarkStore.shared.bookmarks
            _ = LibraryBookmarkStore.shared.ids
            _ = AppleAerialsLibrary.shared.assets
            _ = AppleAerialsLibrary.shared.isAuthorized
        } onChange: { [weak self] in
            // The registrar belongs to app-wide singletons: a strong capture here outlives the
            // window and keeps the whole library, thumbnails included, in memory.
            Task { @MainActor in
                self?.refresh()
                self?.observeStores()
            }
        }
    }

    var visibleItems: [LibraryItem] {
        let filtered: [LibraryItem] = switch chip {
        case .all: items
        case .bookmarks: items.filter { bookmarkedIDs.contains($0.id) }
        case .recent:
            // The recent shelf is limited to the 14 most recently used items before sorting.
            Array(items.filter { usage(of: $0) != nil }.sorted(by: recentlyUsed).prefix(14))
        case .steam: items.filter(\.isSteam)
        case .local: items.filter { !$0.isSteam && $0.kind != .aerial }
        case .aerials: items.filter { $0.kind == .aerial }
        }
        let sorted = filtered.filter(matchesFilter).sorted { lhs, rhs in
            switch sort {
            case .recentlyUsed: return recentlyUsed(lhs, rhs)
            case .name: return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            case .size: return Self.largerFileFirst(lhs, rhs)
            case .type:
                let kinds: [LibraryItem.Kind] = [.video, .web, .scene, .aerial]
                if lhs.kind != rhs.kind {
                    return kinds.firstIndex(of: lhs.kind)! < kinds.firstIndex(of: rhs.kind)!
                }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            #if !LITE_BUILD
            case .needsUpdate:
                if needsUpdate(lhs) != needsUpdate(rhs) {
                    return needsUpdate(lhs)
                }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            #endif
            }
        }
        return sorted.filter { query.isEmpty || matchesQuery($0) }
    }

    private func matchesFilter(_ item: LibraryItem) -> Bool {
        switch filter {
        case nil: return true
        case .unsupported: return !item.isSupported
        #if !LITE_BUILD
        case let .storage(kind):
            guard case let .workshop(entry) = item.source else { return false }
            return kind.matches(entry)
        #endif
        }
    }

    #if !LITE_BUILD
    private func needsUpdate(_ item: LibraryItem) -> Bool {
        guard case let .workshop(entry) = item.source else { return false }
        return updatedWorkshopIDs.contains(entry.id)
    }
    #endif

    private func matchesQuery(_ item: LibraryItem) -> Bool {
        if item.title.range(of: query, options: .caseInsensitive) != nil
            || item.title.translatedWallpaperName.range(of: query, options: .caseInsensitive) != nil
            || queryIsWhole(item.kind.localizedName) {
            return true
        }
        #if !LITE_BUILD
        guard let origin = Self.workshopOrigin(of: item) else { return false }
        if origin.workshopID.range(of: query, options: .caseInsensitive) != nil || queryIsWhole(origin.localizedDisplayTypeName) {
            return true
        }
        let tags = searchTagSources[item.id].flatMap { tagsBySource[$0] } ?? []
        return tags.contains { $0.range(of: query, options: .caseInsensitive) != nil }
        #else
        return false
        #endif
    }

    /// Whole name only, ignoring case and diacritics: as a substring, one typed CJK character would list every row of a type.
    private func queryIsWhole(_ name: String) -> Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }

    /// Deliberately not part of `refresh()`: that runs on every store change, this reads the whole
    /// covers directory, and a scan that comes back empty would start the next one. `kept`: covers
    /// of entries that are gone but that undo can still bring back.
    func prepareLibrary(alsoKeeping kept: Set<String>) {
        inputs.removeOrphanCovers(inputs.savedCoverFileNames().union(kept))
        inputs.scanAerials()
    }

    /// Freezes "Recently Used" until `endBrowsing()`: a row used meanwhile keeps its place.
    func beginBrowsing() {
        guard usageSnapshot == nil else { return }
        // Not `uniqueKeysWithValues`, which traps: row IDs are not unique by construction.
        usageSnapshot = Dictionary(
            items.compactMap { item in item.lastUsedAt.map { (item.id, $0) } }, uniquingKeysWith: { first, _ in first }
        )
        restartSizeMetadataProbe()
    }

    func endBrowsing() {
        usageSnapshot = nil
        cancelSizeMetadataProbe()
    }

    /// Reads the tags of the Workshop projects not read yet; nothing while the query is empty.
    func loadSearchTags() async {
        #if !LITE_BUILD
        guard !query.isEmpty else { return }
        var pending: [SearchTagSource] = []
        // Marked read before the reads finish: every keystroke calls this while they are in flight.
        for item in items {
            guard let source = searchTagSources[item.id], tagsBySource[source] == nil else { continue }
            tagsBySource[source] = []
            pending.append(source)
        }
        for source in pending {
            tagsBySource[source] = await inputs.projectTags(source.origin)
        }
        #endif
    }

    #if !LITE_BUILD
    /// A saved variant carries its project's origin, so it searches by that project's tags.
    private static func workshopOrigin(of item: LibraryItem) -> WPEOrigin? {
        switch item.source {
        case let .workshop(entry): entry.origin
        case let .bookmark(bookmark): bookmark.wpeOrigin
        case .aerial: nil
        }
    }
    #endif

    #if !LITE_BUILD
    /// Import revision changes even when an updated project's folder grant does not.
    /// Variants follow that revision only when they reference the same folder bookmark.
    private static func searchTagSources(in items: [LibraryItem]) -> [LibraryItem.ID: SearchTagSource] {
        let imports = Dictionary(items.compactMap { item -> (String, WPEHistoryEntry)? in
            guard case let .workshop(entry) = item.source else { return nil }
            return (entry.id, entry)
        }, uniquingKeysWith: { first, _ in first })
        return Dictionary(items.compactMap { item -> (LibraryItem.ID, SearchTagSource)? in
            guard let origin = workshopOrigin(of: item) else { return nil }
            let entry = imports[origin.workshopID]
            let revision = entry?.origin.sourceFolderBookmark == origin.sourceFolderBookmark ? entry?.importedAt : nil
            return (item.id, SearchTagSource(origin: origin, importedAt: revision))
        }, uniquingKeysWith: { first, _ in first })
    }
    #endif

    /// When the row was last used as of the browse's start; a row added since reads as unused.
    private func usage(of item: LibraryItem) -> Date? {
        guard let usageSnapshot else { return item.lastUsedAt }
        return usageSnapshot[item.id]
    }

    /// Shared read-only projection. Migrations, source probes and cover cleanup belong to the UI lifecycle.
    static func catalogSnapshot(inputs: Inputs) -> CatalogSnapshot {
        var merged: [LibraryItem] = []
        #if !LITE_BUILD
        merged = inputs.history().map { entry in
            let kind: LibraryItem.Kind = switch entry.origin.originalType {
            case .video: .video
            case .web: .web
            case .scene, .application, .unknown: .scene
            }
            let source = LibraryItem.Source.workshop(entry)
            return LibraryItem(
                id: "workshop:\(entry.id)", title: entry.origin.title, kind: kind, source: source,
                isSteam: Self.isSteam(entry.id), createdAt: entry.importedAt, lastUsedAt: entry.lastUsedAt,
                onDisplays: inputs.nowPlaying(nil, entry),
                thumbnail: .workshop(entry, coverRevision: inputs.workshopCoverRevision(entry)),
                metadata: nil, isVariant: false, parentID: nil,
                isSupported: entry.origin.originalType != .application && entry.origin.originalType != .unknown
            )
        }
        #endif
        let bookmarks = inputs.bookmarks()
        for bookmark in bookmarks {
            var parentID: String?
            #if !LITE_BUILD
            if let workshopID = bookmark.wpeOrigin?.workshopID,
               let index = merged.firstIndex(where: { $0.id == "workshop:\(workshopID)" }) {
                if Self.foldsIntoWorkshopRow(bookmark.content) {
                    if let used = bookmark.lastUsedAt,
                       merged[index].lastUsedAt.map({ used > $0 }) ?? true {
                        merged[index].lastUsedAt = used
                    }
                    continue
                }
                parentID = merged[index].id
            }
            #endif
            let kind: LibraryItem.Kind = switch bookmark.content {
            case .video: .video
            case .html: .web
            case .scene: .scene
            }
            merged.append(LibraryItem(
                id: "bookmark:\(bookmark.id)", title: bookmark.label, kind: kind, source: .bookmark(bookmark),
                isSteam: Self.isSteam(bookmark.wpeOrigin?.workshopID), createdAt: bookmark.createdAt,
                lastUsedAt: bookmark.lastUsedAt, onDisplays: {
                    #if !LITE_BUILD
                    inputs.nowPlaying(bookmark.content, nil)
                    #else
                    inputs.nowPlaying(bookmark.content)
                    #endif
                }(),
                thumbnail: .bookmark(bookmark), metadata: nil,
                isVariant: parentID != nil, parentID: parentID, isSupported: true
            ))
        }
        let aerialsStatus = inputs.aerials()
        var bookmarkedIDs = inputs.libraryBookmarks()
        var markMoves: [(from: LibraryItem.ID, to: LibraryItem.ID)] = []
        #if !LITE_BUILD
        markMoves = Self.foldedMarkMoves(bookmarkedIDs, bookmarks: bookmarks, rows: Set(merged.map(\.id)))
        for move in markMoves {
            bookmarkedIDs.remove(move.from)
            bookmarkedIDs.insert(move.to)
        }
        #endif
        let active = inputs.activeWallpapers()
        // One resolution per active video, not per Aerial row. Cache paths only, never scoped URLs.
        var resolvedPaths: [Data: String?] = [:]
        for entry in active {
            guard let data = entry.content.activeVideoBookmarkData, resolvedPaths[data] == nil else { continue }
            let path = inputs.filePath(data).map { Self.normalizedPath(URL(fileURLWithPath: $0)) }
            resolvedPaths[data] = .some(path)
        }
        merged += aerialsStatus.assets.map { asset in
            let source = LibraryItem.Source.aerial(asset)
            return LibraryItem(
                id: "aerial:\(asset.url.path)", title: asset.displayName, kind: .aerial, source: source,
                isSteam: false, createdAt: .distantPast, lastUsedAt: nil,
                onDisplays: active.filter { entry in
                    guard let data = entry.content.activeVideoBookmarkData else { return false }
                    return data == asset.bookmarkData
                        || (resolvedPaths[data] ?? nil) == Self.normalizedPath(asset.url)
                }.map(\.display), thumbnail: .aerial(.init(asset)),
                metadata: nil,
                isVariant: false, parentID: nil, isSupported: true
            )
        }
        return CatalogSnapshot(items: merged, bookmarkedIDs: bookmarkedIDs, aerials: aerialsStatus, markMoves: markMoves, filePaths: resolvedPaths)
    }

    struct CatalogSnapshot {
        var items: [LibraryItem]
        var bookmarkedIDs: Set<LibraryItem.ID>
        var aerials: AerialsState
        var markMoves: [(from: LibraryItem.ID, to: LibraryItem.ID)]
        var filePaths: [Data: String?]
    }

    func refresh() {
        filePaths = [:]
        let previous = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let snapshot = Self.catalogSnapshot(inputs: inputs)
        filePaths = snapshot.filePaths
        var merged = snapshot.items
        aerialsStatus = snapshot.aerials
        bookmarkedIDs = snapshot.bookmarkedIDs
        for move in snapshot.markMoves {
            inputs.remapLibraryBookmark(move.from, move.to)
        }
        for index in merged.indices {
            if let probe = probedSources[merged[index].id], Self.sameSource(probe.source, merged[index].source) {
                merged[index].isSourceMissing = !probe.available
            }
            // An unchanged source keeps its last answer: only `probeMetadata(for:)` reads a kept row's file again.
            if let kept = previous[merged[index].id], Self.sameSource(kept.source, merged[index].source) {
                merged[index].metadata = kept.metadata
            } else {
                merged[index].metadata = metadataBookmark(for: merged[index].source).flatMap(inputs.metadata)
            }
        }
        #if !LITE_BUILD
        searchTagSources = Self.searchTagSources(in: merged)
        #endif
        items = merged
        restartSizeMetadataProbe()
        if items.contains(where: needsProbe) {
            Task { [weak self] in await self?.probeSources() }
        }
        if !query.isEmpty {
            Task { await loadSearchTags() }
        }
    }

    /// Probes the rows never probed or whose source changed since.
    func probeSources() async {
        await probe(items.filter(needsProbe))
    }

    /// Probes again the rows `intent` was built from: applying is where a stale mark shows.
    func recheck(_ intent: ApplyIntent) async {
        await probe(items.filter { item($0, madeBy: intent) })
    }

    /// Probes again the rows marked missing: `probeSources()` never returns to a row it has answered.
    func recheckMissingSources() async {
        await probe(items.filter(\.isSourceMissing))
    }

    /// A row being probed is still unanswered, not available: until its own round answers, it keeps
    /// its last result, and a probe that a newer one overtook records nothing.
    private func probe(_ pending: [LibraryItem]) async {
        probeRound += 1
        let round = probeRound
        for item in pending {
            probesInFlight[item.id] = (item.source, round)
        }
        for item in pending {
            let available = await inputs.sourceAvailable(item.source)
            guard probesInFlight[item.id]?.round == round else { continue }
            probesInFlight[item.id] = nil
            probedSources[item.id] = (item.source, available)
            if let index = items.firstIndex(where: { $0.id == item.id && Self.sameSource(item.source, $0.source) }),
               items[index].isSourceMissing == available {
                items[index].isSourceMissing = !available
            }
        }
    }

    private func needsProbe(_ item: LibraryItem) -> Bool {
        !Self.sameSource(probedSources[item.id]?.source, item.source) && !Self.sameSource(probesInFlight[item.id]?.source, item.source)
    }

    /// Every scan bookmarks an aerial's file anew, so a probe of that file still answers for the row.
    private static func sameSource(_ probed: LibraryItem.Source?, _ source: LibraryItem.Source) -> Bool {
        if case let .aerial(old)? = probed, case let .aerial(new) = source {
            return old.url.path == new.url.path
        }
        return probed == source
    }

    private func item(_ item: LibraryItem, madeBy intent: ApplyIntent) -> Bool {
        switch (item.source, intent) {
        case let (.bookmark(bookmark), .bookmark(applied)): bookmark.id == applied.id
        case let (.aerial(asset), .bookmark(applied)): aerial(asset, matches: applied.content)
        #if !LITE_BUILD
        case let (.workshop(entry), .installedWorkshop(applied)): entry.id == applied.id
        #endif
        default: false
        }
    }

    /// A file size is not a Workshop project's total footprint; directories and shared assets stay unknown.
    private static func knownFileSize(_ item: LibraryItem) -> Int64? {
        guard case let .video(video)? = item.metadata, let size = video.fileSize, size >= 0 else { return nil }
        return size
    }

    private static func largerFileFirst(_ lhs: LibraryItem, _ rhs: LibraryItem) -> Bool {
        switch (knownFileSize(lhs), knownFileSize(rhs)) {
        case let (left?, right?) where left != right: left > right
        case (_?, nil): true
        case (nil, _?): false
        default: lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    private func cancelSizeMetadataProbe() {
        sizeMetadataTask?.cancel()
        sizeMetadataTask = nil
    }

    private func restartSizeMetadataProbe() {
        cancelSizeMetadataProbe()
        guard sort == .size, usageSnapshot != nil else { return }
        let pendingIDs = items.filter { Self.knownFileSize($0) == nil }.map(\.id)
        sizeMetadataTask = Task { [weak self] in await self?.probeMetadata(for: pendingIDs) }
    }

    func probeMetadata(for ids: [LibraryItem.ID]) async {
        let requested = Set(ids)
        for item in items where requested.contains(item.id) && (item.kind == .video || item.kind == .aerial) {
            guard !Task.isCancelled else { return }
            guard let bookmark = metadataBookmark(for: item.source) else { continue }
            let metadata = await inputs.probeMetadata(bookmark)
            guard !Task.isCancelled else { return }
            guard let index = items.firstIndex(where: { $0.id == item.id && $0.source == item.source }) else { continue }
            items[index].metadata = metadata
        }
    }

    private func metadataBookmark(for source: LibraryItem.Source) -> WallpaperBookmark? {
        switch source {
        case let .bookmark(bookmark): return bookmark
        case let .aerial(asset):
            return WallpaperBookmark(label: asset.displayName, content: .video(bookmarkData: asset.bookmarkData))
        #if !LITE_BUILD
        case let .workshop(entry):
            guard entry.origin.originalType == .video else { return nil }
            if let bookmark = inputs.bookmarks().first(where: {
                $0.wpeOrigin?.workshopID == entry.id && $0.content.wallpaperType == .video
            }) {
                return bookmark
            }
            guard let content = inputs.workshopContent(entry) else { return nil }
            return WallpaperBookmark(label: entry.origin.title, content: content, wpeOrigin: entry.origin)
        #endif
        }
    }

    #if !LITE_BUILD
    /// The video a Workshop row plays when its project is one; nil for every other row.
    func workshopVideo(for item: LibraryItem) -> WallpaperContent? {
        guard case .workshop = item.source, let content = metadataBookmark(for: item.source)?.content,
              case .video = content else { return nil }
        return content
    }
    #endif

    /// Every scan bookmarks each file anew, so an aerial matches content whose bookmark resolves to the aerial's file.
    func aerial(_ asset: AerialAsset, matches content: WallpaperContent?) -> Bool {
        guard let data = content?.activeVideoBookmarkData else { return false }
        return data == asset.bookmarkData || filePath(of: data) == Self.normalizedPath(asset.url)
    }

    private func filePath(of bookmarkData: Data) -> String? {
        if let cached = filePaths[bookmarkData] {
            return cached
        }
        let path = inputs.filePath(bookmarkData).map { Self.normalizedPath(URL(fileURLWithPath: $0)) }
        filePaths[bookmarkData] = path
        return path
    }

    /// A bookmark resolves to the real path (`/private/tmp/…`, symlinks followed) while a scanned URL may be spelled otherwise.
    private static func normalizedPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func displays(for content: WallpaperContent) -> [CGDirectDisplayID] {
        #if !LITE_BUILD
        inputs.nowPlaying(content, nil)
        #else
        inputs.nowPlaying(content)
        #endif
    }

    private static func isSteam(_ id: String?) -> Bool {
        guard let id, !id.isEmpty else { return false }
        return id.allSatisfy(\.isNumber)
    }

    private func recentlyUsed(_ lhs: LibraryItem, _ rhs: LibraryItem) -> Bool {
        switch (usage(of: lhs), usage(of: rhs)) {
        case let (left?, right?) where left != right: left > right
        case (_?, nil): true
        case (nil, _?): false
        default: lhs.createdAt > rhs.createdAt
        }
    }
}
