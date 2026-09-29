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
        func load() -> [WallpaperBookmark] {
            values
        }

        func save(_ bookmarks: [WallpaperBookmark]) {
            values = bookmarks
        }
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

    @Test("Browse save survives archive restart and feeds the Likes modal's description, author and rating")
    func browseToSavedRoundTrip() throws {
        let scratch = try TestScratch.defaultsSuite(prefix: "WorkshopBookmarkMetadataTests")
        defer { scratch.discard() }
        let local = BookmarkStore(persistence: MemoryBookmarks())
        let workshop = WorkshopBookmarkStore(defaults: scratch.defaults)
        let original = item()
        WorkshopBookmarkActions.toggle(original, workshopStore: workshop)
        let restarted = WorkshopBookmarkStore(defaults: scratch.defaults)
        let restored = try WorkshopBookmarkActions.queryItem(#require(restarted.bookmarks.first))
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
        let restored = WorkshopBookmarkActions.queryItem(saved)
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
        let wrong = try WorkshopBookmark(id: 732, rawTitle: "Other", previewImageURL: nil, tags: [],
                                         detailsSnapshot: #require(item().bookmarkDetailsSnapshot))
        #expect(wrong.queryItemSnapshot == nil)
        let fallback = WorkshopBookmarkActions.queryItem(wrong)
        #expect(fallback.id == 732)
        #expect(fallback.shortDescription.isEmpty)
        #expect(fallback.rating == nil)
        let corrupt = WorkshopBookmark(id: 731, rawTitle: "Still saved", previewImageURL: nil, tags: [],
                                       detailsSnapshot: Data("invalid".utf8))
        #expect(WorkshopBookmarkActions.queryItem(corrupt).title == "Still saved")
        #expect(item(id: 732, description: "", rich: false).preservingDetails(from: item()).rating == nil)
        let snapshot = try #require(item().bookmarkDetailsSnapshot)
        var payload = try #require(JSONSerialization.jsonObject(with: snapshot) as? [String: Any])
        payload["steamCommunityURL"] = "file:///tmp/unrelated"
        let foreignLink = try WorkshopBookmark(id: 731, rawTitle: "Safe fallback", previewImageURL: nil, tags: [],
                                               detailsSnapshot: JSONSerialization.data(withJSONObject: payload))
        #expect(foreignLink.queryItemSnapshot == nil)
    }

    @Test("Published-file full BBCode description hydrates a legacy item without invented author or rating")
    func publishedFileDescriptionFallback() throws {
        let payload = Data(#"{"response":{"publishedfiledetails":[{"publishedfileid":"731","result":1,"consumer_app_id":431960,"visibility":0,"title":"Fixture","creator":"76561198000000001","short_description":"","description":"[h1]Desert[/h1]\n[b]A quiet night[/b] [2026]","tags":[]}]}}"#.utf8)
        let result = try #require(SteamWorkshopMetadataService.decodeBatch(data: payload, requestedIDs: [731])[731])
        let metadata = try result.get()
        let fetched = WorkshopPublicSearchSource.queryItem(from: metadata)
        #expect(fetched.shortDescription.isEmpty)
        #expect(fetched.detailDescription == "Desert\nA quiet night [2026]")
        #expect(fetched.displayDescription == "Desert\nA quiet night [2026]")
        #expect(fetched.creatorPersonaName == nil)
        #expect(fetched.rating == nil)
        let rich = fetched.preservingDetails(from: item())
        #expect(rich.creatorPersonaName == "Fixture Author")
        #expect(rich.rating?.totalVotes == 179)
        #expect(rich.shortDescription == item().shortDescription)
        let scratch = try TestScratch.defaultsSuite(prefix: "WorkshopBookmarkMetadataTests")
        defer { scratch.discard() }
        let store = WorkshopBookmarkStore(defaults: scratch.defaults)
        store.add(WorkshopBookmark(id: 731, rawTitle: "Legacy", previewImageURL: nil, tags: []))
        WorkshopBookmarkActions.refreshDetails(rich, in: store)
        WorkshopBookmarkActions.refreshDetails(item(description: " ", rich: false), in: store)
        let restarted = WorkshopBookmarkStore(defaults: scratch.defaults)
        let saved = try #require(restarted.bookmarks.first)
        let restored = WorkshopBookmarkActions.queryItem(saved)
        #expect(restored.displayDescription == "Desert\nA quiet night [2026]")
        #expect(restored.shortDescription == item().shortDescription)
        #expect(restored.creatorPersonaName == "Fixture Author")
        #expect(restored.rating?.totalVotes == 179)
        #expect(item(id: 732).preservingDetails(from: restored).detailDescription == nil)
    }

    @Test("Full descriptions remain author content; summaries and literal brackets keep their meaning")
    func detailTextSemanticsAndBudget() throws {
        let full = "[h1]Title[/h1]\r\n\r\n\r\n[b]Text[/b] [2026] [unknown]literal[/unknown] [url=https://example.com]Link[/url]\nwriter@example.com 76561198000000001"
        let data = try JSONSerialization.data(withJSONObject: ["response": ["publishedfiledetails": [[
            "publishedfileid": "731", "result": 1, "consumer_app_id": 431_960,
            "visibility": 0, "short_description": "A short summary", "description": full,
        ]]]])
        let metadata = try #require(SteamWorkshopMetadataService.decodeBatch(data: data, requestedIDs: [731])[731]).get()
        let mapped = WorkshopPublicSearchSource.queryItem(from: metadata)
        #expect(mapped.shortDescription == "A short summary")
        #expect(mapped.displayDescription == "Title\n\nText [2026] [unknown]literal[/unknown] Link\nwriter@example.com 76561198000000001")
        #expect(SteamWorkshopMetadataService.plainDetailDescription("[b] [/b]") == nil)
        #expect(SteamWorkshopMetadataService.plainDetailDescription(nil) == nil)

        let limit = SteamWorkshopMetadataService.detailDisplayScalarLimit
        let long = String(repeating: "🌙", count: limit + 100)
        let bounded = try #require(SteamWorkshopMetadataService.plainDetailDescription(long))
        #expect(bounded.unicodeScalars.count == limit)
        #expect(bounded.hasSuffix("…"))
        #expect(!bounded.contains("�"))
        let exact = String(repeating: "x", count: limit)
        #expect(SteamWorkshopMetadataService.plainDetailDescription(exact) == exact)
        // Markup shrinks below the display budget: truncation must still be
        // visible when processing stopped at the input budget.
        let inputLimit = SteamWorkshopMetadataService.detailInputScalarLimit
        let markupHeavy = "start" + String(repeating: "[b][/b]", count: inputLimit / 7 + 1) + "END_SENTINEL"
        let inputBounded = try #require(SteamWorkshopMetadataService.plainDetailDescription(markupHeavy))
        #expect(inputBounded.hasPrefix("start") && inputBounded.hasSuffix("…"))
        #expect(!inputBounded.contains("END_SENTINEL"))
        #expect(inputBounded.unicodeScalars.count <= limit)
    }

    @Test("Old snapshots without detail body decode and keep the existing description and facts")
    func oldSnapshotWithoutDetailDescription() throws {
        let original = item()
        let encoded = try #require(original.bookmarkDetailsSnapshot)
        var fields = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        fields.removeValue(forKey: "detailDescription")
        let oldData = try JSONSerialization.data(withJSONObject: fields)
        let bookmark = WorkshopBookmark(id: 731, rawTitle: "Legacy", previewImageURL: nil, tags: [], detailsSnapshot: oldData)
        let restored = WorkshopBookmarkActions.queryItem(bookmark)
        #expect(restored.detailDescription == nil)
        #expect(restored.displayDescription == original.shortDescription)
        #expect(restored.creatorPersonaName == original.creatorPersonaName)
        #expect(restored.rating == original.rating)
        var longDetail = original
        longDetail.detailDescription = String(repeating: "x", count: 20000)
        let boundedBookmark = try WorkshopBookmark(id: 731, rawTitle: "Bounded", previewImageURL: nil, tags: [], detailsSnapshot: #require(longDetail.bookmarkDetailsSnapshot))
        let bounded = try #require(boundedBookmark.queryItemSnapshot?.detailDescription)
        #expect(bounded.unicodeScalars.count == SteamWorkshopMetadataService.detailDisplayScalarLimit)
        #expect(bounded.hasSuffix("…"))
    }
}
#endif
