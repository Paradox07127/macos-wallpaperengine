import Foundation
@testable import LiveWallpaperCore
import Testing

@MainActor
struct LibraryBookmarkStoreTests {
    private static func defaults(_ test: String = #function) throws -> (UserDefaults, String) {
        let suite = "LibraryBookmarkStoreTests.\(test)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
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

    @Test("After Clean All Settings, the next mark does not write the cleared ones back")
    func resetAfterSettingsClearedForgetsOldMarks() throws {
        let (defaults, suite) = try Self.defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LibraryBookmarkStore(defaults: defaults)
        store.add("a")
        store.add("b")
        defaults.removeObject(forKey: LibraryBookmarkStore.preferencesKey)
        store.resetAfterSettingsCleared()
        store.add("c")

        #expect(store.ids == ["c"])
        #expect(LibraryBookmarkStore(defaults: defaults).ids == ["c"])
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

    @Test("An archive that can't be decoded reports itself unreadable; a readable one does not")
    func unreadableArchiveIsReported() throws {
        let (defaults, suite) = try Self.defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(!LibraryBookmarkStore(defaults: defaults).isArchiveUnreadable)
        defaults.set(Data("invalid archive".utf8), forKey: LibraryBookmarkStore.preferencesKey)

        #expect(LibraryBookmarkStore(defaults: defaults).isArchiveUnreadable)
    }

    @Test("Dismissing the error clears only the alert; the unreadable archive stays and writes stay refused")
    func dismissKeepsTheArchive() throws {
        let (defaults, suite) = try Self.defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = Data("invalid archive".utf8)
        defaults.set(original, forKey: LibraryBookmarkStore.preferencesKey)
        let store = LibraryBookmarkStore(defaults: defaults)

        store.dismissStorageError()

        #expect(!store.hasStorageError)
        #expect(store.isArchiveUnreadable)
        #expect(defaults.data(forKey: LibraryBookmarkStore.preferencesKey) == original)
        store.add("a")
        #expect(store.hasStorageError, "a refused write raised no error after the dismissal")
        #expect(defaults.data(forKey: LibraryBookmarkStore.preferencesKey) == original)
    }

    @Test("Resetting an unreadable archive deletes only its key, and the next mark is saved")
    func resetDiscardsOnlyThisArchive() throws {
        let (defaults, suite) = try Self.defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("invalid archive".utf8), forKey: LibraryBookmarkStore.preferencesKey)
        defaults.set("kept", forKey: "some.other.key")
        let store = LibraryBookmarkStore(defaults: defaults)

        store.resetUnreadableArchive()

        #expect(defaults.object(forKey: LibraryBookmarkStore.preferencesKey) == nil, "Reset left the archive in place")
        #expect(defaults.string(forKey: "some.other.key") == "kept", "Reset deleted another key")
        #expect(!store.hasStorageError)
        #expect(!store.isArchiveUnreadable)
        #expect(store.ids.isEmpty)
        store.add("a")
        #expect(!store.hasStorageError)
        #expect(LibraryBookmarkStore(defaults: defaults).ids == ["a"])
    }
}
