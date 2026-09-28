#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

@Suite("Workshop bookmarks")
@MainActor
struct WorkshopBookmarkTests {
    @MainActor
    private final class MemoryBookmarks: BookmarkPersisting {
        var saved: [WallpaperBookmark] = []

        func load() -> [WallpaperBookmark] {
            saved
        }

        func save(_ bookmarks: [WallpaperBookmark]) {
            saved = bookmarks
        }
    }

    private static func origin(_ workshopID: String) -> WPEOrigin {
        WPEOrigin(
            workshopID: workshopID, title: "Rain", originalType: .video,
            sourceFolderBookmark: Data("missing-source".utf8),
            cacheRelativePath: "wpe-cache/\(workshopID)", previewFileName: nil,
            entryFile: "video.mp4", resourceLocation: .cache
        )
    }

    /// A playable local bookmark whose provenance is `workshopID`.
    private static func addLocal(_ workshopID: String, to store: BookmarkStore) -> WallpaperBookmark {
        store.add(label: "Rain", content: .video(bookmarkData: Data(workshopID.utf8)), wpeOrigin: origin(workshopID))
    }

    private static func saved(_ id: UInt64, rawTitle: String? = "Rain") -> WorkshopBookmark {
        WorkshopBookmark(id: id, rawTitle: rawTitle, previewImageURL: nil, tags: [])
    }

    private static func queryItem(_ id: UInt64, rawTitle: String? = "Rain") -> WorkshopQueryItem {
        WorkshopQueryItem(
            id: id, rawTitle: rawTitle, shortDescription: "", creatorID: nil,
            previewImageURL: nil, fileSizeBytes: nil, timeUpdated: nil,
            subscriptionCount: nil, rating: nil, tags: [], visibility: .unknown,
            isBanned: false, steamCommunityURL: WorkshopCommunityURL.item(itemID: id)
        )
    }

    private static func stores(_ name: String) throws -> (BookmarkStore, WorkshopBookmarkStore, TestScratch.DefaultsSuite) {
        let suite = try TestScratch.defaultsSuite("workshop.bookmarks.\(name)")
        return (BookmarkStore(persistence: MemoryBookmarks()), WorkshopBookmarkStore(defaults: suite.defaults), suite)
    }

    // MARK: - Actions

    @Test("Saving from Browse writes the Workshop store only, and contains reads both stores")
    func toggleAndContains() throws {
        let (local, workshop, suite) = try Self.stores("toggle")
        defer { suite.discard() }
        let item = Self.queryItem(424_242)

        WorkshopBookmarkActions.toggle(item, store: local, workshopStore: workshop)
        #expect(workshop.contains(424_242))
        #expect(local.bookmarks.isEmpty, "saving for later must not create a playable bookmark")

        _ = Self.addLocal("7", to: local)
        #expect(WorkshopBookmarkActions.contains(7, store: local, workshopStore: workshop))

        WorkshopBookmarkActions.toggle(item, store: local, workshopStore: workshop)
        #expect(!WorkshopBookmarkActions.contains(424_242, store: local, workshopStore: workshop))
    }

    @Test("An untitled item is saved without one app language's fallback title")
    func untitledItemKeepsNoTitle() throws {
        let (local, workshop, suite) = try Self.stores("untitled")
        defer { suite.discard() }

        WorkshopBookmarkActions.toggle(Self.queryItem(9, rawTitle: nil), store: local, workshopStore: workshop)

        #expect(workshop.bookmarks.map(\.rawTitle) == [nil])
    }

    @Test("Deleting a local bookmark removes it and its saved-for-later entry")
    func deletingALocalBookmarkClearsBoth() throws {
        let (local, workshop, suite) = try Self.stores("delete")
        defer { suite.discard() }
        let bookmark = Self.addLocal("424242", to: local)
        workshop.add(Self.saved(424_242))

        WorkshopBookmarkActions.remove(bookmark, store: local, workshopStore: workshop)

        #expect(local.bookmarks.isEmpty)
        #expect(!workshop.contains(424_242))
    }

    @Test("Deleting an installed item clears its id from both stores")
    func removeAllClearsBothStores() throws {
        let (local, workshop, suite) = try Self.stores("removeAll")
        defer { suite.discard() }
        _ = Self.addLocal("424242", to: local)
        workshop.add(Self.saved(424_242))

        WorkshopBookmarkActions.removeAll(workshopID: "424242", store: local, workshopStore: workshop)

        #expect(!local.containsWPEBookmark(workshopID: "424242"))
        #expect(!workshop.contains(424_242))
    }

    @Test("The pane's bookmark set covers both stores")
    func bookmarkedIDsCoverBothStores() throws {
        let (local, workshop, suite) = try Self.stores("idSet")
        defer { suite.discard() }
        workshop.add(Self.saved(1))
        _ = Self.addLocal("2", to: local)

        #expect(WorkshopBookmarkActions.bookmarkedIDs(store: local, workshopStore: workshop) == [1, 2])
    }

    @Test("A saved-for-later entry on the Installed page becomes a playable bookmark in one tap")
    func installedTogglePromotesSavedEntry() throws {
        let (local, workshop, suite) = try Self.stores("promote")
        defer { suite.discard() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("wpe-cache/424242", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data([0, 1]).write(to: cache.appendingPathComponent("video.mp4"))
        workshop.add(Self.saved(424_242))
        let model = InstalledLibraryModel(dependencies: .init(
            loadEntries: { [] }, loadRemoteUpdateEpochs: { [:] }, saveRemoteUpdateEpochs: { _ in },
            loadLastUpdateCheckEpoch: { 0 }, saveLastUpdateCheckEpoch: { _ in },
            makeMetadataService: { SteamWorkshopMetadataService() }, now: Date.init, prefetchPreviewURLs: { _ in }
        ))
        let resolver = WPECachedContentResolver(applicationSupportRootURL: root, makeBookmark: { Data($0.path.utf8) })

        model.toggleBookmark(
            WPEHistoryEntry(origin: Self.origin("424242"), importedAt: Date()),
            store: local, workshopStore: workshop, resolver: resolver
        )

        #expect(local.containsWPEBookmark(workshopID: "424242"))
        #expect(model.errorMessage == nil)
    }

    @Test("A card wired the way Browse wires it saves its item on the first click and removes it on the second")
    func browseCardTogglesTheBookmark() throws {
        let (local, workshop, suite) = try Self.stores("card")
        defer { suite.discard() }
        let item = Self.queryItem(424_242)
        let card = BrowseCard(
            item: item, cardPreferences: GalleryCardPreferences(), reduceMotion: true,
            isBookmarked: WorkshopBookmarkActions.bookmarkedIDs(store: local, workshopStore: workshop).contains(item.id),
            onBookmark: { WorkshopBookmarkActions.toggle(item, store: local, workshopStore: workshop) }
        )
        let onBookmark = try #require(card.onBookmark, "the card hides its bookmark button")
        #expect(!card.isBookmarked)

        onBookmark()
        #expect(WorkshopBookmarkActions.bookmarkedIDs(store: local, workshopStore: workshop).contains(item.id))
        onBookmark()
        #expect(!WorkshopBookmarkActions.bookmarkedIDs(store: local, workshopStore: workshop).contains(item.id))
    }

    // MARK: - Wiring

    @Test("Both installed-delete paths clear the Workshop store too")
    func installedDeleteUsesBothStores() throws {
        for path in [
            "LiveWallpaper/Views/EditDesk/Library/ModalActions.swift",
        ] {
            let source = try RepositoryRoot.source(path)
            #expect(source.contains("WorkshopBookmarkActions.removeAll(workshopID: $0, store: store)"), Comment(rawValue: path))
            #expect(!source.contains("removeWPEBookmarks(workshopID: $0) }"), Comment(rawValue: path))
        }
    }

    @Test("Browse hands every card its bookmark state, read once per pass, and a toggle")
    func browsePaneBookmarkWiring() throws {
        let pane = try RepositoryRoot.source("LiveWallpaper/Views/Workshop/BrowsePane.swift")
        #expect(pane.contains("let bookmarkedIDs = WorkshopBookmarkActions.bookmarkedIDs()"), "the pane reads no bookmark set")
        #expect(pane.contains("isBookmarked: bookmarkedIDs.contains(item.id)"), "a Browse card gets no bookmark state")
        #expect(pane.contains("onBookmark: { WorkshopBookmarkActions.toggle(item) }"), "a Browse card gets no bookmark action")
        // Control: one set per pass, not a store lookup per card.
        #expect(!pane.contains("WorkshopBookmarkActions.contains("))

        let card = try RepositoryRoot.source("LiveWallpaper/Views/Workshop/BrowseCard.swift")
        #expect(card.contains("var onBookmark: (() -> Void)?"))
        let menu = try #require(card.range(of: "private var contextMenuItems: some View {"))
        #expect(card[menu.upperBound...].prefix(80).contains("if let onBookmark {"))
    }
}
#endif
