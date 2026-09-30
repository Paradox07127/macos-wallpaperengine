import Foundation
import Observation

/// The Wallpaper Library entries the user marked, by `LibraryItem.id`, in the order they were marked.
/// A mark never adds or removes a library entry.
@MainActor
@Observable
public final class LibraryBookmarkStore {
    public static let preferencesKey = "loomscreen.library.bookmarks.v1"
    /// `bookmark:<UUID>`, `workshop:<Workshop ID>` or `aerial:<file path>`, each once.
    public private(set) var ids: [String] = []
    public private(set) var hasStorageError = false
    /// The stored archive exists but can't be decoded; every write is refused so it is not overwritten.
    @ObservationIgnored private var isArchiveUnreadable = false
    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        guard let stored = defaults.object(forKey: Self.preferencesKey) else { return }
        do {
            guard let data = stored as? Data else { throw CocoaError(.coderReadCorrupt) }
            ids = try JSONDecoder().decode([String].self, from: data)
        } catch {
            isArchiveUnreadable = true
            hasStorageError = true
            Logger.error("Could not read library bookmarks", category: .ui)
        }
    }

    public func contains(_ id: String) -> Bool {
        ids.contains(id)
    }

    public func toggle(_ id: String) {
        if contains(id) {
            remove(id)
        } else {
            add(id)
        }
    }

    public func add(_ id: String) {
        guard !contains(id) else { return }
        save(ids + [id])
    }

    public func remove(_ id: String) {
        guard contains(id) else { return }
        save(ids.filter { $0 != id })
    }

    /// Import: the marks already here keep their places; each imported one not among them is appended once.
    public func merge(_ imported: [String]) {
        var merged = ids
        var seen = Set(ids)
        for id in imported where seen.insert(id).inserted {
            merged.append(id)
        }
        guard merged != ids else { return }
        save(merged)
    }

    public func resetAfterSettingsCleared() {
        ids = []
        isArchiveUnreadable = false
        hasStorageError = false
    }

    private func save(_ updated: [String]) {
        guard !isArchiveUnreadable else {
            hasStorageError = true
            return
        }
        do {
            try defaults.set(JSONEncoder().encode(updated), forKey: Self.preferencesKey)
            ids = updated
            hasStorageError = false
        } catch {
            hasStorageError = true
            Logger.error("Could not save library bookmarks", category: .ui)
        }
    }
}
