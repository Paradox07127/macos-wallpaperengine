#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

@MainActor
@Suite("Workshop bookmark metadata lifecycle")
struct WorkshopBookmarkMetadataTests {
    private final class MemoryBookmarks: BookmarkPersisting {
        var values: [WallpaperBookmark] = []
        func load() -> [WallpaperBookmark] { values }
        func save(_ bookmarks: [WallpaperBookmark]) { values = bookmarks }
    }

    private func item(id: UInt64 = 731, description: String = "A quiet synthetic desert", rich: Bool = true) -> WorkshopQueryItem {
        WorkshopQueryItem(
            id: id, rawTitle: "Night Desert Fixture", shortDescription: description,
            creatorID: "76561198000000001", creatorPersonaName: rich ? "Fixture Author" : nil,
            previewImageURL: nil, fileSizeBytes: 1024, timeUpdated: Date(timeIntervalSince1970: 100),
            subscriptionCount: rich ? 42 : nil,
            rating: rich ? .score(0.78, votesUp: 140, votesDown: 39) : nil,
            tags: ["Scene"], visibility: .public, isBanned: false,
            steamCommunityURL: WorkshopCommunityURL.item(itemID: id)
        )
    }

    @Test("Browse save survives archive restart and feeds the Saved modal's description, author and rating")
    func browseToSavedRoundTrip() throws {
        let scratch = try TestScratch.defaultsSuite(prefix: "WorkshopBookmarkMetadataTests")
        defer { scratch.discard() }
        let local = BookmarkStore(persistence: MemoryBookmarks())
        let workshop = WorkshopBookmarkStore(defaults: scratch.defaults)
        let original = item()
        WorkshopBookmarkActions.toggle(original, store: local, workshopStore: workshop)
        let restarted = WorkshopBookmarkStore(defaults: scratch.defaults)
        let restored = SavedBookmarks.queryItem(try #require(restarted.bookmarks.first))
        #expect(restored.shortDescription == original.shortDescription)
        #expect(restored.creatorPersonaName == "Fixture Author")
        #expect(restored.creatorID == original.creatorID)
        let rating = try #require(restored.rating)
        #expect(abs(rating.starsOutOfFive - 3.9) < 1e-10)
        #expect(restored.rating?.totalVotes == 179)
        #expect(local.bookmarks.isEmpty)
        let facts = WorkshopModalContent.facts(item: restored, importedAt: nil, now: Date(), locale: Locale(identifier: "en_US"))
        #expect(facts.first { $0.kind == .author }?.value == "Fixture Author")
        #expect(facts.first { $0.kind == .rating }?.value.hasPrefix("3.9 · ") == true)
    }

    @Test("Legacy bookmarks hydrate in place; sparse refresh never erases richer saved facts")
    func legacyHydrationPreservesIdentityAndRichFields() throws {
        let scratch = try TestScratch.defaultsSuite(prefix: "WorkshopBookmarkMetadataTests")
        defer { scratch.discard() }
        let legacy = Data(#"[{"id":731,"rawTitle":"Old title","tags":["Scene"],"createdAt":12}]"#.utf8)
        scratch.defaults.set(legacy, forKey: WorkshopBookmarkStore.preferencesKey)
        let store = WorkshopBookmarkStore(defaults: scratch.defaults)
        #expect(!store.isArchiveUnreadable)
        let createdAt = try #require(store.bookmarks.first).createdAt
        WorkshopBookmarkActions.refreshDetails(item(), in: store)
        WorkshopBookmarkActions.refreshDetails(item(description: "  ", rich: false), in: store)
        let restarted = WorkshopBookmarkStore(defaults: scratch.defaults)
        let saved = try #require(restarted.bookmarks.first)
        #expect(saved.createdAt == createdAt)
        #expect(saved.id == 731)
        #expect(restarted.bookmarks.count == 1)
        let restored = SavedBookmarks.queryItem(saved)
        #expect(restored.shortDescription == "A quiet synthetic desert")
        #expect(restored.creatorPersonaName == "Fixture Author")
        #expect(restored.rating?.totalVotes == 179)
        // A late network result must not resurrect a bookmark removed meanwhile.
        store.remove(731)
        WorkshopBookmarkActions.refreshDetails(item(), in: store)
        #expect(store.bookmarks.isEmpty)
    }

    @Test("Snapshot identity mismatch or corrupt metadata cannot leak another item's details")
    func snapshotIdentityAndCorruptionFailClosed() throws {
        let wrong = WorkshopBookmark(id: 732, rawTitle: "Other", previewImageURL: nil, tags: [],
                                     detailsSnapshot: try #require(item().bookmarkDetailsSnapshot))
        #expect(wrong.queryItemSnapshot == nil)
        let fallback = SavedBookmarks.queryItem(wrong)
        #expect(fallback.id == 732)
        #expect(fallback.shortDescription.isEmpty)
        #expect(fallback.rating == nil)
        let corrupt = WorkshopBookmark(id: 731, rawTitle: "Still saved", previewImageURL: nil, tags: [],
                                       detailsSnapshot: Data("invalid".utf8))
        #expect(SavedBookmarks.queryItem(corrupt).title == "Still saved")
        #expect(item(id: 732, description: "", rich: false).preservingDetails(from: item()).rating == nil)
        let snapshot = try #require(item().bookmarkDetailsSnapshot)
        var payload = try #require(JSONSerialization.jsonObject(with: snapshot) as? [String: Any])
        payload["steamCommunityURL"] = "file:///tmp/unrelated"
        let foreignLink = WorkshopBookmark(id: 731, rawTitle: "Safe fallback", previewImageURL: nil, tags: [],
                                           detailsSnapshot: try JSONSerialization.data(withJSONObject: payload))
        #expect(foreignLink.queryItemSnapshot == nil)
    }

    @Test("Published-file full BBCode description hydrates a legacy item without invented author or rating")
    func publishedFileDescriptionFallback() throws {
        let payload = Data(#"{"response":{"publishedfiledetails":[{"publishedfileid":"731","result":1,"consumer_app_id":431960,"visibility":0,"title":"Fixture","creator":"76561198000000001","short_description":"","description":"[h1]Desert[/h1]\n[b]A quiet night[/b] [2026]","tags":[]}]}}"#.utf8)
        let result = try #require(SteamWorkshopMetadataService.decodeBatch(data: payload, requestedIDs: [731])[731])
        let metadata = try result.get()
        let fetched = WorkshopPublicSearchSource.queryItem(from: metadata)
        #expect(fetched.shortDescription == "Desert\nA quiet night [2026]")
        #expect(fetched.creatorPersonaName == nil)
        #expect(fetched.rating == nil)
        let rich = fetched.preservingDetails(from: item())
        #expect(rich.creatorPersonaName == "Fixture Author")
        #expect(rich.rating?.totalVotes == 179)
    }
}
#endif
