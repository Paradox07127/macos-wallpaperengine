import Combine
import CoreGraphics
import Foundation
import LiveWallpaperCore
import Observation

@MainActor @Observable
final class SavedLibraryModel {
    enum Chip: CaseIterable { case all, recent, steam, local, aerials, nowPlaying, fourK }
    enum Sort { case recentlyUsed, name, type }

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
        #if !LITE_BUILD
        var history: @MainActor () -> [WPEHistoryEntry] = { [] }
        /// Content is nil for installed rows, which match by origin instead.
        var nowPlaying: @MainActor (WallpaperContent?, WPEHistoryEntry?) -> [CGDirectDisplayID] = { _, _ in [] }
        var workshopContent: @MainActor (WPEHistoryEntry) -> WallpaperContent? = { _ in nil }
        /// The `tags` of a project's `project.json`; empty when the file cannot be read.
        var projectTags: @MainActor (WPEOrigin) async -> [String] = { _ in [] }
        #else
        var nowPlaying: @MainActor (WallpaperContent) -> [CGDirectDisplayID] = { _ in [] }
        #endif
        var metadata: @MainActor (WallpaperBookmark) -> LibraryMetadata? = { _ in nil }
        var probeMetadata: @MainActor (WallpaperBookmark) async -> LibraryMetadata? = { _ in nil }
        /// Every cover a bookmark or scheme still points at — not the filtered view, whose misses
        /// would read as orphans.
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
            inputs.savedCoverFileNames = {
                Set(
                    BookmarkStore.shared.bookmarks.compactMap(\.coverFileName)
                        + SchemeStore.shared.schemes.compactMap(\.coverFileName)
                )
            }
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
    var sort: Sort = .recentlyUsed
    var query = ""
    private(set) var items: [LibraryItem] = []
    private(set) var aerialsStatus = AerialsState()
    /// Each row's last use when the current browse began; nil while none is open.
    private var usageSnapshot: [LibraryItem.ID: Date]?
    #if !LITE_BUILD
    /// Project tags by workshop ID, from `loadSearchTags()`; empty while a read is in flight or when it failed.
    private var tagsByWorkshopID: [String: [String]] = [:]
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
        self.init(inputs: .live(screenManager: screenManager))
        observeStores()
    }

    /// `BookmarkStore` and `AppleAerialsLibrary` only persist; nothing posts a notification for
    /// an add / remove / rename, so the live model tracks them through Observation.
    func observeStores() {
        withObservationTracking {
            _ = BookmarkStore.shared.bookmarks
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
        case .recent:
            // The recent shelf is limited to the 14 most recently used items before sorting.
            Array(items.filter { usage(of: $0) != nil }.sorted(by: recentlyUsed).prefix(14))
        case .steam: items.filter(\.isSteam)
        case .local: items.filter { !$0.isSteam && $0.kind != .aerial }
        case .aerials: items.filter { $0.kind == .aerial }
        case .nowPlaying: items.filter { !$0.onDisplays.isEmpty }
        case .fourK: items.filter { $0.metadata?.is4K == true }
        }
        let sorted = filtered.sorted { lhs, rhs in
            switch sort {
            case .recentlyUsed: return recentlyUsed(lhs, rhs)
            case .name: return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            case .type:
                let kinds: [LibraryItem.Kind] = [.video, .web, .scene, .aerial]
                if lhs.kind != rhs.kind {
                    return kinds.firstIndex(of: lhs.kind)! < kinds.firstIndex(of: rhs.kind)!
                }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
        }
        return sorted.filter { query.isEmpty || matchesQuery($0) }
    }

    private func matchesQuery(_ item: LibraryItem) -> Bool {
        if item.title.range(of: query, options: .caseInsensitive) != nil {
            return true
        }
        #if !LITE_BUILD
        let tags = Self.workshopOrigin(of: item).flatMap { tagsByWorkshopID[$0.workshopID] } ?? []
        return tags.contains { $0.range(of: query, options: .caseInsensitive) != nil }
        #else
        return false
        #endif
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
    }

    func endBrowsing() {
        usageSnapshot = nil
    }

    /// Reads the tags of the Workshop projects not read yet; nothing while the query is empty.
    func loadSearchTags() async {
        #if !LITE_BUILD
        guard !query.isEmpty else { return }
        var pending: [WPEOrigin] = []
        // Marked read before the reads finish: every keystroke calls this while they are in flight.
        for origin in items.compactMap(Self.workshopOrigin) where tagsByWorkshopID[origin.workshopID] == nil {
            tagsByWorkshopID[origin.workshopID] = []
            pending.append(origin)
        }
        for origin in pending {
            tagsByWorkshopID[origin.workshopID] = await inputs.projectTags(origin)
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

    /// When the row was last used as of the browse's start; a row added since reads as unused.
    private func usage(of item: LibraryItem) -> Date? {
        guard let usageSnapshot else { return item.lastUsedAt }
        return usageSnapshot[item.id]
    }

    func refresh() {
        filePaths = [:]
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
                isSteam: isSteam(entry.id), createdAt: entry.importedAt, lastUsedAt: entry.lastUsedAt,
                onDisplays: inputs.nowPlaying(nil, entry), thumbnail: .workshop(entry),
                metadata: metadataBookmark(for: source).flatMap(inputs.metadata), isVariant: false, parentID: nil,
                isSupported: entry.origin.originalType != .application && entry.origin.originalType != .unknown
            )
        }
        #endif
        for bookmark in inputs.bookmarks() {
            var parentID: String?
            #if !LITE_BUILD
            if let workshopID = bookmark.wpeOrigin?.workshopID,
               let index = merged.firstIndex(where: { $0.id == "workshop:\(workshopID)" }) {
                if let descriptor = bookmark.content.sceneDescriptor, !descriptor.propertyOverrides.isEmpty {
                    parentID = merged[index].id
                } else {
                    if let used = bookmark.lastUsedAt,
                       merged[index].lastUsedAt.map({ used > $0 }) ?? true {
                        merged[index].lastUsedAt = used
                    }
                    continue
                }
            }
            #endif
            let kind: LibraryItem.Kind = switch bookmark.content {
            case .video: .video
            case .html: .web
            case .scene: .scene
            }
            merged.append(LibraryItem(
                id: "bookmark:\(bookmark.id)", title: bookmark.label, kind: kind, source: .bookmark(bookmark),
                isSteam: isSteam(bookmark.wpeOrigin?.workshopID), createdAt: bookmark.createdAt,
                lastUsedAt: bookmark.lastUsedAt, onDisplays: displays(for: bookmark.content),
                thumbnail: .bookmark(bookmark), metadata: inputs.metadata(bookmark),
                isVariant: parentID != nil, parentID: parentID, isSupported: true
            ))
        }
        aerialsStatus = inputs.aerials()
        let active = inputs.activeWallpapers()
        merged += aerialsStatus.assets.map { asset in
            let source = LibraryItem.Source.aerial(asset)
            return LibraryItem(
                id: "aerial:\(asset.url.path)", title: asset.displayName, kind: .aerial, source: source,
                isSteam: false, createdAt: .distantPast, lastUsedAt: nil,
                onDisplays: active.filter { aerial(asset, matches: $0.content) }.map(\.display), thumbnail: .aerial(.init(asset)),
                metadata: metadataBookmark(for: source).flatMap(inputs.metadata),
                isVariant: false, parentID: nil, isSupported: true
            )
        }
        for index in merged.indices {
            if let probe = probedSources[merged[index].id], Self.sameSource(probe.source, merged[index].source) {
                merged[index].isSourceMissing = !probe.available
            }
        }
        items = merged
        if items.contains(where: needsProbe) {
            Task { [weak self] in await self?.probeSources() }
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

    func probeMetadata(for ids: [LibraryItem.ID]) async {
        let requested = Set(ids)
        for item in items where requested.contains(item.id) && (item.kind == .video || item.kind == .aerial) {
            guard let bookmark = metadataBookmark(for: item.source) else { continue }
            let metadata = await inputs.probeMetadata(bookmark)
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

    private func isSteam(_ id: String?) -> Bool {
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
