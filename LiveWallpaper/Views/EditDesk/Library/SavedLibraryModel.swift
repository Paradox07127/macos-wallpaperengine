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
        #else
        var nowPlaying: @MainActor (WallpaperContent) -> [CGDirectDisplayID] = { _ in [] }
        #endif
        var metadata: @MainActor (WallpaperBookmark) -> LibraryMetadata? = { _ in nil }
        var probeMetadata: @MainActor (WallpaperBookmark) async -> LibraryMetadata? = { _ in nil }
        /// Every cover a bookmark or scheme still points at — not the filtered view, whose misses
        /// would read as orphans.
        var savedCoverFileNames: @MainActor () -> Set<String> = { [] }
        var removeOrphanCovers: @MainActor (Set<String>) -> Void = { _ in }

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
            return inputs
        }
    }

    var chip: Chip = .all
    var sort: Sort = .recentlyUsed
    var query = ""
    private(set) var items: [LibraryItem] = []
    private(set) var aerialsStatus = AerialsState()
    @ObservationIgnored private let inputs: Inputs
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
        case .all: items.filter { $0.kind != .aerial }
        case .recent:
            // The recent shelf is limited to the 14 most recently used items before sorting.
            Array(items.filter { $0.lastUsedAt != nil }.sorted(by: recentlyUsed).prefix(14))
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
        return sorted.filter { query.isEmpty || $0.title.range(of: query, options: .caseInsensitive) != nil }
    }

    /// Deliberately not part of `refresh()`: that runs on every store change, and this reads the
    /// whole covers directory.
    func prepareLibrary() {
        inputs.removeOrphanCovers(inputs.savedCoverFileNames())
    }

    func refresh() {
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
        merged += aerialsStatus.assets.map { asset in
            let source = LibraryItem.Source.aerial(asset)
            return LibraryItem(
                id: "aerial:\(asset.id)", title: asset.displayName, kind: .aerial, source: source,
                isSteam: false, createdAt: .distantPast, lastUsedAt: nil,
                onDisplays: displays(for: .video(bookmarkData: asset.bookmarkData)), thumbnail: nil,
                metadata: metadataBookmark(for: source).flatMap(inputs.metadata),
                isVariant: false, parentID: nil, isSupported: true
            )
        }
        items = merged
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
        switch (lhs.lastUsedAt, rhs.lastUsedAt) {
        case let (left?, right?) where left != right: left > right
        case (_?, nil): true
        case (nil, _?): false
        default: lhs.createdAt > rhs.createdAt
        }
    }
}
