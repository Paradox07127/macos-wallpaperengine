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

    private static func saved(_ id: UInt64, rawTitle: String? = "Rain", tags: [String] = []) -> WorkshopBookmark {
        WorkshopBookmark(id: id, rawTitle: rawTitle, previewImageURL: nil, tags: tags)
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
        let item = Self.saved(424_242).queryItem

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

        WorkshopBookmarkActions.toggle(Self.saved(9, rawTitle: nil).queryItem, store: local, workshopStore: workshop)

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

    @Test("Saved-for-later entries already saved as a playable bookmark are listed once")
    func savedForLaterHidesLocalDuplicates() throws {
        let (local, _, suite) = try Self.stores("dedupe")
        defer { suite.discard() }
        _ = Self.addLocal("2", to: local)

        let listed = WorkshopBookmarkActions.notSavedLocally([Self.saved(1), Self.saved(2)], store: local)

        #expect(listed.map(\.id) == [1])
    }

    @Test("The pane's bookmark set covers both stores")
    func bookmarkedIDsCoverBothStores() throws {
        let (local, workshop, suite) = try Self.stores("idSet")
        defer { suite.discard() }
        workshop.add(Self.saved(1))
        _ = Self.addLocal("2", to: local)

        #expect(WorkshopBookmarkActions.bookmarkedIDs(store: local, workshopStore: workshop) == [1, 2])
    }

    @Test("Workshop tags map to the library's wallpaper types")
    func tagsMapToWallpaperTypes() {
        #expect(Self.saved(1, tags: ["Scene"]).wallpaperType == .scene)
        #expect(Self.saved(1, tags: ["video"]).wallpaperType == .video)
        #expect(Self.saved(1, tags: ["Web"]).wallpaperType == .html)
        #expect(Self.saved(1, tags: ["Anime"]).wallpaperType == nil)
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

    // MARK: - Wiring

    @Test("Both installed-delete paths clear the Workshop store too")
    func installedDeleteUsesBothStores() throws {
        for path in [
            "LiveWallpaper/Views/Workshop/InstalledView.swift",
            "LiveWallpaper/Views/EditDesk/Library/ModalActions.swift",
        ] {
            let source = try RepositoryRoot.source(path)
            #expect(source.contains("removeBookmarks: { WorkshopBookmarkActions.removeAll("), Comment(rawValue: path))
            #expect(!source.contains("removeWPEBookmarks(workshopID: $0) }"), Comment(rawValue: path))
        }
    }

    @Test("Browse builds the bookmark set once per pass and gives Edit Desk cards no bookmark affordance")
    func browsePaneBookmarkWiring() throws {
        let pane = try RepositoryRoot.source("LiveWallpaper/Views/Workshop/BrowsePane.swift")
        #expect(pane.contains("WorkshopBookmarkActions.bookmarkedIDs()"))
        #expect(!pane.contains("WorkshopBookmarkActions.contains("), "every card scans the bookmark list")
        #expect(pane.contains("onBookmark: presentation == .editDesk ? nil :"))

        let card = try RepositoryRoot.source("LiveWallpaper/Views/Workshop/BrowseCard.swift")
        #expect(card.contains("var onBookmark: (() -> Void)?"))
        let menu = try #require(card.range(of: "private var contextMenuItems: some View {"))
        #expect(card[menu.upperBound...].prefix(80).contains("if let onBookmark {"))
    }

    @Test("The bookmark glyph is a thumbnail badge in media colours, not a card overlay")
    func bookmarkGlyphSitsOnTheThumbnail() throws {
        let card = try RepositoryRoot.source("LiveWallpaper/Views/Workshop/BrowseCard.swift")
        #expect(!card.contains("Color.primary"))
        #expect(!card.contains(".padding(.bottom, DesignTokens.Spacing.xl + DesignTokens.Spacing.md)"))
        let thumbnail = try #require(card.range(of: "private var thumbnailArea: some View {"))
        let pills = try #require(card.range(of: "private func typePill("))
        #expect(card[thumbnail.upperBound ..< pills.lowerBound].contains("bookmarkControl(onBookmark)"))
    }

    @Test("Saved bookmarks use square tiles, stacked with the local grid")
    func workshopBookmarkGridLayout() throws {
        let gallery = try RepositoryRoot.source("LiveWallpaper/Views/Workshop/WorkshopBookmarkGallery.swift")
        #expect(gallery.contains("LibraryGalleryGrid(size: tileSize, aspect: .square)"))
        let library = try RepositoryRoot.source("LiveWallpaper/Views/Bookmarks/LibraryView.swift")
        #expect(library.contains("ScrollView {\n                VStack {\n                    LibraryGalleryGrid("))
    }

    @Test("A rebuilt bookmark keeps Download off until its live lookup")
    func savedItemDownloadWaitsForLiveDetails() throws {
        let gallery = try RepositoryRoot.source("LiveWallpaper/Views/Workshop/WorkshopBookmarkGallery.swift")
        #expect(!gallery.contains("canDownload: doctor.isDownloadReady"))
        #expect(gallery.contains("allowsDownload: currentItem != nil"))
        let inspector = try RepositoryRoot.source("LiveWallpaper/Views/Workshop/DetailSheet.swift")
        #expect(inspector.contains("|| item.isBanned || !allowsDownload)"))
    }

    @Test("The storage alert is mounted once per legacy page and observes the flag in body")
    func errorAlertMounting() throws {
        let mounts = try RepositoryRoot.swiftFiles(under: "LiveWallpaper").filter {
            try String(contentsOf: $0, encoding: .utf8).contains(".modifier(WorkshopBookmarkErrorModifier())")
        }.map { RepositoryRoot.relativePath(of: $0) }
        #expect(mounts.sorted() == [
            "LiveWallpaper/Views/Bookmarks/LibraryView.swift",
            "LiveWallpaper/Views/Workshop/BrowsePane.swift",
        ])
        let pane = try RepositoryRoot.source("LiveWallpaper/Views/Workshop/BrowsePane.swift")
        let body = try #require(pane.range(of: "var body: some View {"))
        let layout = try #require(pane.range(of: "private var layout: some View {"))
        #expect(!pane[body.upperBound ..< layout.lowerBound].contains("WorkshopBookmarkErrorModifier"), "the Edit Desk branch gets the alert too")

        let modifier = try RepositoryRoot.source("LiveWallpaper/Views/Workshop/WorkshopBookmarkActions.swift")
        #expect(modifier.contains(".onChange(of: store.hasStorageError, initial: true)"))
    }
}
#endif
