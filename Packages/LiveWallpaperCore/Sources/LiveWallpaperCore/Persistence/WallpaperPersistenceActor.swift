import Foundation

/// Serial off-MainActor writer for screen / global / bookmark file stores.
/// Callers pass a per-store generation; older generations are dropped so
/// reordered tasks cannot resurrect superseded state (including Reset deletes).
public actor WallpaperPersistenceActor {
    private let store: AtomicFileStore<[ScreenConfiguration]>
    private let globalSettingsStore: AtomicFileStore<GlobalSettings>
    private let bookmarksStore: AtomicFileStore<[WallpaperBookmark]>
    private var latestGeneration: UInt64 = 0
    private var latestGlobalGeneration: UInt64 = 0
    private var latestBookmarksGeneration: UInt64 = 0

    public init(
        store: AtomicFileStore<[ScreenConfiguration]>,
        globalSettingsStore: AtomicFileStore<GlobalSettings>,
        bookmarksStore: AtomicFileStore<[WallpaperBookmark]>
    ) {
        self.store = store
        self.globalSettingsStore = globalSettingsStore
        self.bookmarksStore = bookmarksStore
    }

    public func write(_ configs: [ScreenConfiguration], generation: UInt64) throws {
        guard generation >= latestGeneration else { return }
        latestGeneration = generation
        try store.write(configs)
    }

    public func delete(generation: UInt64) {
        guard generation >= latestGeneration else { return }
        latestGeneration = generation
        store.delete()
    }

    public func writeGlobalSettings(_ settings: GlobalSettings, generation: UInt64) throws {
        guard generation >= latestGlobalGeneration else { return }
        latestGlobalGeneration = generation
        try globalSettingsStore.write(settings)
    }

    public func writeBookmarks(_ bookmarks: [WallpaperBookmark], generation: UInt64) throws {
        guard generation >= latestBookmarksGeneration else { return }
        latestBookmarksGeneration = generation
        try bookmarksStore.write(bookmarks)
    }

    public func deleteGlobalSettings(generation: UInt64) {
        guard generation >= latestGlobalGeneration else { return }
        latestGlobalGeneration = generation
        globalSettingsStore.delete()
    }

    public func deleteBookmarks(generation: UInt64) {
        guard generation >= latestBookmarksGeneration else { return }
        latestBookmarksGeneration = generation
        bookmarksStore.delete()
    }
}
