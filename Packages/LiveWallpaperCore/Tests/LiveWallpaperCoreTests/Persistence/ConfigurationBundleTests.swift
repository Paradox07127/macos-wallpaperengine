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

    @Test("Workshop import preserves first accepted records and the existing archive order")
    func workshopImportPreservesMetadataAndDuplicateOrder() throws {
        let suite = "ConfigurationBundleTests.\(#function)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let one = Self.bookmark(1, "Mine")
        let storedDuplicate = Self.bookmark(1, "Legacy duplicate")
        let two = Self.bookmark(2, nil)
        try defaults.set(JSONEncoder().encode([one, storedDuplicate, two]), forKey: WorkshopBookmarkStore.preferencesKey)
        let store = WorkshopBookmarkStore(defaults: defaults)
        let three = WorkshopBookmark(id: 3, rawTitle: "", previewImageURL: URL(string: "https://example.com/3.jpg"),
                                     tags: ["Z", "A"], createdAt: Date(timeIntervalSince1970: 123), detailsSnapshot: Data([0, 255, 7]))
        let four = Self.bookmark(4, "Four")
        ConfigurationBundle(workshopBookmarks: [Self.bookmark(2, "Backup"), three, Self.bookmark(3, "Later"), four, Self.bookmark(1, "Backup")])
            .mergeWorkshopBookmarks(into: store)
        let expected = [one, storedDuplicate, two, three, four]
        #expect(store.bookmarks == expected)
        #expect(WorkshopBookmarkStore(defaults: defaults).bookmarks == expected)
        #expect(!store.hasStorageError)
        let archive = defaults.data(forKey: WorkshopBookmarkStore.preferencesKey)
        ConfigurationBundle(workshopBookmarks: expected).mergeWorkshopBookmarks(into: store)
        #expect(defaults.data(forKey: WorkshopBookmarkStore.preferencesKey) == archive, "an idempotent repeat must preserve the archive")
    }

    @Test("Nil, empty and duplicate-only Workshop imports preserve the archive and an existing error")
    func workshopImportNoOpsPreserveErrors() throws {
        let suite = "ConfigurationBundleTests.\(#function)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WorkshopBookmarkStore(defaults: defaults)
        let existing = Self.bookmark(1, "Mine")
        store.add(existing)
        let bad = WorkshopBookmark(id: 2, rawTitle: nil, previewImageURL: nil, tags: [], createdAt: Date(timeIntervalSince1970: .infinity))
        #expect(throws: EncodingError.self) { try JSONEncoder().encode(bad) }
        store.add(bad)
        try #require(store.hasStorageError)
        let archive = defaults.data(forKey: WorkshopBookmarkStore.preferencesKey)
        ConfigurationBundle().mergeWorkshopBookmarks(into: store)
        ConfigurationBundle(workshopBookmarks: []).mergeWorkshopBookmarks(into: store)
        ConfigurationBundle(workshopBookmarks: [Self.bookmark(1, "Ignored")]).mergeWorkshopBookmarks(into: store)
        #expect(defaults.data(forKey: WorkshopBookmarkStore.preferencesKey) == archive)
        #expect(store.bookmarks == [existing])
        #expect(store.hasStorageError)
    }

    @Test("Unreadable Workshop archives refuse imports until explicit recovery")
    func workshopImportRefusesUnreadableArchivesAndCanRecover() throws {
        for nonData in [false, true] {
            let suite = "ConfigurationBundleTests.\(#function).\(nonData)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defaults.removePersistentDomain(forName: suite)
            defer { defaults.removePersistentDomain(forName: suite) }
            let original = Data("not JSON".utf8)
            if nonData {
                defaults.set("unreadable", forKey: WorkshopBookmarkStore.preferencesKey)
            } else {
                defaults.set(original, forKey: WorkshopBookmarkStore.preferencesKey)
            }
            defaults.set(true, forKey: "neighbour")
            let store = WorkshopBookmarkStore(defaults: defaults)
            store.dismissStorageError()
            ConfigurationBundle(workshopBookmarks: []).mergeWorkshopBookmarks(into: store)
            #expect(!store.hasStorageError)
            ConfigurationBundle(workshopBookmarks: [Self.bookmark(1, "One"), Self.bookmark(2, "Two")]).mergeWorkshopBookmarks(into: store)
            #expect(store.isArchiveUnreadable && store.hasStorageError)
            #expect(store.bookmarks.isEmpty)
            if nonData {
                #expect(defaults.string(forKey: WorkshopBookmarkStore.preferencesKey) == "unreadable")
            } else {
                #expect(defaults.data(forKey: WorkshopBookmarkStore.preferencesKey) == original)
            }
            store.resetUnreadableArchive()
            ConfigurationBundle(workshopBookmarks: [Self.bookmark(1, "One")]).mergeWorkshopBookmarks(into: store)
            #expect(!store.hasStorageError && !store.isArchiveUnreadable)
            #expect(WorkshopBookmarkStore(defaults: defaults).bookmarks.map(\.id) == [1])
            #expect(defaults.bool(forKey: "neighbour"))
        }
    }

    @Test("Workshop import continues past actual encode failures without reserving failed ids")
    func workshopImportEncodingFailuresKeepSequentialOutcomes() throws {
        let goodThree = Self.bookmark(3, "Good three")
        let goodFive = Self.bookmark(5, "Good five")
        let badThree = WorkshopBookmark(id: 3, rawTitle: "Bad three", previewImageURL: nil, tags: [], createdAt: Date(timeIntervalSince1970: .infinity))
        let badFour = WorkshopBookmark(id: 4, rawTitle: "Bad four", previewImageURL: nil, tags: [], createdAt: Date(timeIntervalSince1970: .infinity))
        #expect(throws: EncodingError.self) { try JSONEncoder().encode(badThree) }
        let cases: [([WorkshopBookmark], [WorkshopBookmark], Bool)] = [
            ([badThree, goodThree], [goodThree], false),
            ([goodThree, badFour, goodFive], [goodThree, goodFive], false),
            ([goodThree, badFour, goodThree], [goodThree], true),
            ([goodThree, badThree], [goodThree], false),
            ([badThree, badFour], [], true),
        ]
        for (index, value) in cases.enumerated() {
            let suite = "ConfigurationBundleTests.\(#function).\(index)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defaults.removePersistentDomain(forName: suite)
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = WorkshopBookmarkStore(defaults: defaults)
            ConfigurationBundle(workshopBookmarks: value.0).mergeWorkshopBookmarks(into: store)
            #expect(store.bookmarks == value.1)
            #expect(WorkshopBookmarkStore(defaults: defaults).bookmarks == value.1)
            #expect(store.hasStorageError == value.2)
        }
    }
}
