import Foundation
@testable import LiveWallpaperCore
import Testing

@MainActor
struct ConfigurationBundleTests {
    private static func bookmark(_ id: UInt64, _ rawTitle: String?) -> WorkshopBookmark {
        WorkshopBookmark(
            id: id, rawTitle: rawTitle,
            previewImageURL: URL(string: "https://example.com/\(id).jpg"), tags: ["Scene"],
            // Whole seconds: the backup's ISO 8601 dates drop sub-second precision.
            createdAt: Date(timeIntervalSince1970: 1_750_000_000)
        )
    }

    private static func decode(_ data: Data) throws -> ConfigurationBundle {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ConfigurationBundle.self, from: data)
    }

    @Test("A backup carries Workshop bookmarks through encode and decode")
    func backupCarriesWorkshopBookmarks() throws {
        let saved = [Self.bookmark(1, "Rain"), Self.bookmark(2, nil)]

        let data = try ConfigurationPorter.encode(ConfigurationBundle(workshopBookmarks: saved))

        #expect(try Self.decode(data).workshopBookmarks == saved)
    }

    @Test("Restoring a backup adds its new Workshop bookmarks and keeps the ones already saved")
    func restoreMergesByWorkshopID() throws {
        let suite = "ConfigurationBundleTests.\(#function)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WorkshopBookmarkStore(defaults: defaults)
        store.add(Self.bookmark(1, "Mine"))

        ConfigurationBundle(workshopBookmarks: [Self.bookmark(1, "Backup"), Self.bookmark(2, "New")])
            .mergeWorkshopBookmarks(into: store)

        #expect(WorkshopBookmarkStore(defaults: defaults).bookmarks.map(\.rawTitle) == ["Mine", "New"])
    }

    @Test("A backup written before library bookmarks existed still decodes, without any")
    func backupWithoutLibraryBookmarksDecodes() throws {
        let old = Data(#"{"schemaVersion":1,"appBundleID":"com.loomscreen.pro","exportedAt":"2025-06-15T00:00:00Z"}"#.utf8)

        #expect(try Self.decode(old).libraryBookmarks == nil)
    }

    @Test("A backup carries library bookmarks, and restoring one merges them into the marks already here")
    func libraryBookmarksRoundTripAndMerge() throws {
        let marks = ["workshop:42", "bookmark:A", "aerial:/sky.mov"]
        let restored = try Self.decode(ConfigurationPorter.encode(ConfigurationBundle(libraryBookmarks: marks)))
        #expect(restored.libraryBookmarks == marks)

        let suite = "ConfigurationBundleTests.\(#function)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LibraryBookmarkStore(defaults: defaults)
        store.add("bookmark:A")
        store.add("bookmark:Mine")

        restored.mergeLibraryBookmarks(into: store)

        #expect(LibraryBookmarkStore(defaults: defaults).ids == ["bookmark:A", "bookmark:Mine", "workshop:42", "aerial:/sky.mov"])
    }

    @Test("A bundle without Workshop bookmarks encodes no key for them")
    func bundleWithoutWorkshopBookmarksKeepsItsShape() throws {
        let data = try ConfigurationPorter.encode(ConfigurationBundle(wallpaperBookmarks: []))

        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["workshopBookmarks"] == nil)
        #expect(try Self.decode(data).workshopBookmarks == nil)
    }
}
