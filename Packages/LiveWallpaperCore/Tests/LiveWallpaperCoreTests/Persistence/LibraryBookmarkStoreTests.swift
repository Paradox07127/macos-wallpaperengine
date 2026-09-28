import Foundation
@testable import LiveWallpaperCore
import Testing

@MainActor
struct LibraryBookmarkStoreTests {
    private static func defaults() throws -> (UserDefaults, String) {
        let suite = "LibraryBookmarkStoreTests.\(UUID().uuidString)"
        return try (#require(UserDefaults(suiteName: suite)), suite)
    }

    @Test("Marks keep the order they were added in, each once, across a relaunch")
    func marksPersistInOrderWithoutDuplicates() throws {
        let (defaults, suite) = try Self.defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LibraryBookmarkStore(defaults: defaults)
        store.add("workshop:42")
        store.add("bookmark:A")
        store.add("workshop:42")
        store.toggle("aerial:/sky.mov")

        let reopened = LibraryBookmarkStore(defaults: defaults)
        #expect(reopened.ids == ["workshop:42", "bookmark:A", "aerial:/sky.mov"])
        #expect(reopened.contains("bookmark:A"))
        #expect(!reopened.contains("bookmark:B"))
    }

    @Test("Removing or toggling off a mark drops only that mark")
    func removalKeepsTheOtherMarks() throws {
        let (defaults, suite) = try Self.defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LibraryBookmarkStore(defaults: defaults)
        store.add("a")
        store.add("b")
        store.add("c")
        store.remove("b")
        store.toggle("a")

        #expect(LibraryBookmarkStore(defaults: defaults).ids == ["c"])
    }

    @Test("Merging keeps the marks already here first and appends only new ones, each once")
    func mergeIsAnOrderedUnion() throws {
        let (defaults, suite) = try Self.defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LibraryBookmarkStore(defaults: defaults)
        store.add("mine")
        store.add("shared")

        store.merge(["new", "shared", "new", "later"])

        #expect(LibraryBookmarkStore(defaults: defaults).ids == ["mine", "shared", "new", "later"])
    }

    @Test("An archive that can't be read is kept and every write is refused")
    func unreadableArchiveIsNotOverwritten() throws {
        let (defaults, suite) = try Self.defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = Data("invalid archive".utf8)
        defaults.set(original, forKey: LibraryBookmarkStore.preferencesKey)

        let store = LibraryBookmarkStore(defaults: defaults)
        #expect(store.hasStorageError)
        store.add("a")
        store.merge(["b"])
        store.toggle("c")

        #expect(store.ids.isEmpty)
        #expect(defaults.data(forKey: LibraryBookmarkStore.preferencesKey) == original)
    }

    @Test("A stored value that is not data counts as unreadable, not absent")
    func nonDataValueIsUnreadable() throws {
        let (defaults, suite) = try Self.defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("not an archive", forKey: LibraryBookmarkStore.preferencesKey)

        let store = LibraryBookmarkStore(defaults: defaults)
        store.add("a")

        #expect(store.hasStorageError)
        #expect(defaults.string(forKey: LibraryBookmarkStore.preferencesKey) == "not an archive")
    }
}
