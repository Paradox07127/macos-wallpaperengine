#if !LITE_BUILD
import AppKit
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Observation
import SwiftUI
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

    @Test("Liking from Browse writes the Workshop store only, and a second tap unlikes")
    func toggleAndContains() throws {
        let (local, workshop, suite) = try Self.stores("toggle")
        defer { suite.discard() }
        let item = Self.queryItem(424_242)

        WorkshopBookmarkActions.toggle(item, workshopStore: workshop)
        #expect(workshop.contains(424_242))
        #expect(WorkshopBookmarkActions.contains(424_242, workshopStore: workshop))
        #expect(local.bookmarks.isEmpty, "liking must not create a playable bookmark")

        WorkshopBookmarkActions.toggle(item, workshopStore: workshop)
        #expect(!WorkshopBookmarkActions.contains(424_242, workshopStore: workshop))
    }

    @Test("Unliking leaves the wallpaper library's saved entries for that item alone")
    func unlikingKeepsLibraryEntries() throws {
        let (local, workshop, suite) = try Self.stores("unlike")
        defer { suite.discard() }
        _ = Self.addLocal("424242", to: local)
        workshop.add(Self.saved(424_242))

        WorkshopBookmarkActions.toggle(Self.queryItem(424_242), workshopStore: workshop)

        #expect(!workshop.contains(424_242))
        #expect(local.containsWPEBookmark(workshopID: "424242"), "unliking deleted the library's saved entries for the item")
    }

    @Test("An untitled item is saved without one app language's fallback title")
    func untitledItemKeepsNoTitle() throws {
        let (_, workshop, suite) = try Self.stores("untitled")
        defer { suite.discard() }

        WorkshopBookmarkActions.toggle(Self.queryItem(9, rawTitle: nil), workshopStore: workshop)

        #expect(workshop.bookmarks.map(\.rawTitle) == [nil])
    }

    @Test("The pane's like set is the Workshop store alone")
    func bookmarkedIDsAreTheWorkshopStore() throws {
        let (local, workshop, suite) = try Self.stores("idSet")
        defer { suite.discard() }
        workshop.add(Self.saved(1))
        _ = Self.addLocal("2", to: local)

        #expect(WorkshopBookmarkActions.bookmarkedIDs(workshopStore: workshop) == [1])
    }

    @Test("The Likes list shows the stored likes newest first, a loaded result standing in for its snapshot")
    func likedItemsAreNewestFirst() throws {
        let (_, workshop, suite) = try Self.stores("likes")
        defer { suite.discard() }
        for id: UInt64 in [1, 2, 3] {
            workshop.add(Self.saved(id))
        }

        let items = WorkshopBookmarkActions.likedItems(
            browseItems: [Self.queryItem(2, rawTitle: "Loaded")], workshopStore: workshop
        )

        #expect(items.map(\.id) == [3, 2, 1])
        #expect(items.map(\.rawTitle) == ["Rain", "Loaded", "Rain"])
    }

    @Test("An older like appended later, as a backup import does, still sorts by its own like date")
    func likedItemsSortByCreatedAt() throws {
        let (_, workshop, suite) = try Self.stores("likesByDate")
        defer { suite.discard() }
        workshop.add(WorkshopBookmark(id: 1, rawTitle: "Rain", previewImageURL: nil, tags: [], createdAt: Date(timeIntervalSince1970: 200)))
        workshop.add(WorkshopBookmark(id: 2, rawTitle: "Rain", previewImageURL: nil, tags: [], createdAt: Date(timeIntervalSince1970: 100)))

        let items = WorkshopBookmarkActions.likedItems(browseItems: [], workshopStore: workshop)

        #expect(items.map(\.id) == [1, 2])
    }

    @Test("A hosted Likes grid follows loaded metadata and like actions without rebuilding its host")
    func hostedLikesGridRefreshesAfterMetadataAndLikeChanges() async throws {
        let (_, workshop, suite) = try Self.stores("hostedLikes")
        defer { suite.discard() }
        for id: UInt64 in [1, 2] {
            workshop.add(WorkshopBookmark(
                id: id, rawTitle: "Rain", previewImageURL: nil, tags: [],
                createdAt: Date(timeIntervalSince1970: Double(id) * 100)
            ))
        }
        let input = WorkshopLikesRefreshInput()
        input.browseItems = [Self.queryItem(2, rawTitle: "Loaded first"), Self.queryItem(2, rawTitle: "Loaded duplicate")]
        let host = NSHostingView(rootView: WorkshopLikesRefreshGrid(store: workshop, input: input)
            .frame(width: 640, height: 260))
        let window = ParkedTestWindow(
            contentRect: CGRect(x: 0, y: 0, width: 640, height: 260),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.parkOffScreen()
        defer {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        @MainActor func rendered(_ ids: [UInt64], titles: [String?]) async -> Bool {
            let deadline = ContinuousClock.now + .seconds(2)
            while ContinuousClock.now < deadline {
                host.layoutSubtreeIfNeeded()
                if input.renderedItems.map(\.id) == ids, input.renderedItems.map(\.rawTitle) == titles {
                    return true
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return false
        }
        #expect(await rendered([2, 1], titles: ["Loaded first", "Rain"]))

        input.browseItems = [Self.queryItem(1, rawTitle: "New remote title")]
        #expect(await rendered([2, 1], titles: ["Rain", "New remote title"]))
        WorkshopBookmarkActions.toggle(Self.queryItem(2), workshopStore: workshop)
        #expect(await rendered([1], titles: ["New remote title"]))
        WorkshopBookmarkActions.toggle(Self.queryItem(3, rawTitle: "New like"), workshopStore: workshop)
        #expect(await rendered([3, 1], titles: ["New like", "New remote title"]))
    }

    @Test("A card wired the way Browse wires it saves its item on the first click and removes it on the second")
    func browseCardTogglesTheBookmark() throws {
        let (_, workshop, suite) = try Self.stores("card")
        defer { suite.discard() }
        let item = Self.queryItem(424_242)
        let card = BrowseCard(
            item: item, cardPreferences: GalleryCardPreferences(), reduceMotion: true,
            isBookmarked: WorkshopBookmarkActions.bookmarkedIDs(workshopStore: workshop).contains(item.id),
            onBookmark: { WorkshopBookmarkActions.toggle(item, workshopStore: workshop) }
        )
        let onBookmark = try #require(card.onBookmark, "the card hides its like button")
        #expect(!card.isBookmarked)

        onBookmark()
        #expect(WorkshopBookmarkActions.bookmarkedIDs(workshopStore: workshop).contains(item.id))
        onBookmark()
        #expect(!WorkshopBookmarkActions.bookmarkedIDs(workshopStore: workshop).contains(item.id))
    }

    // MARK: - Wiring

    @Test("Deleting an installed item leaves its like alone and clears only the library's own marks")
    func installedDeleteLeavesTheLike() throws {
        let source = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Library/ModalActions.swift")
        let start = try #require(source.range(of: "inputs.deleteInstalled = {"))
        let end = try #require(source.range(of: "removeImportIfMatching:", range: start.upperBound ..< source.endIndex))
        let cleanup = String(source[start.lowerBound ..< end.lowerBound])
        #expect(!cleanup.contains("WorkshopBookmark"), "deleting an installed item clears its like")
        #expect(cleanup.contains("WorkshopSavedRecords.remove(workshopID: $0"), "a deleted item's saved records stay behind")
        let records = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Library/WorkshopSavedRecords.swift")
        #expect(!records.contains("WorkshopBookmark"), "clearing a Workshop item's saved records clears its like")
        #expect(records.contains("bookmarks.removeWPEBookmarks(workshopID: workshopID)"), "a deleted item's saved library entries stay behind")
        #expect(records.contains(#"libraryBookmarks.remove("workshop:\(workshopID)")"#), "a deleted item's library bookmark stays behind")
        #expect(records.contains(#"libraryBookmarks.remove("bookmark:\("#), "a deleted item's saved variants keep their library marks")
    }

}

@MainActor @Observable
private final class WorkshopLikesRefreshInput {
    var browseItems: [WorkshopQueryItem] = []
    @ObservationIgnored var renderedItems: [WorkshopQueryItem] = []
}

private struct WorkshopLikesRefreshGrid: View {
    let store: WorkshopBookmarkStore
    let input: WorkshopLikesRefreshInput

    var body: some View {
        let items = WorkshopBookmarkActions.likedItems(browseItems: input.browseItems, workshopStore: store)
        LibraryGalleryGrid(size: .small, aspect: .square, columnWidth: DesignTokens.LibraryGrid.workshopBrowseColumnWidth) {
            ForEach(items) { item in
                BrowseCard(
                    item: item, cardPreferences: GalleryCardPreferences(), reduceMotion: true,
                    isBookmarked: true, onBookmark: { WorkshopBookmarkActions.toggle(item, workshopStore: store) }
                )
                .equatable()
            }
        }
        .onChange(of: items, initial: true) { _, shown in input.renderedItems = shown }
    }
}
#endif
