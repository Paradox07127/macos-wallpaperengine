import Foundation
import Observation

/// A saved Workshop reference; saving it never downloads or applies a wallpaper.
public struct WorkshopBookmark: Codable, Equatable, Identifiable, Sendable {
    public let id: UInt64
    /// As Steam sent it; nil when the item has none. The app applies its fallback title when it renders.
    public let rawTitle: String?
    public let previewImageURL: URL?
    public let tags: [String]
    public let createdAt: Date
    /// App-owned, Codable Workshop item snapshot, shared with the query cache.
    /// Optional so older bookmarks decode; Core does not depend on Steam DTOs.
    public let detailsSnapshot: Data?

    public init(id: UInt64, rawTitle: String?, previewImageURL: URL?, tags: [String], createdAt: Date = Date(), detailsSnapshot: Data? = nil) {
        self.id = id
        self.rawTitle = rawTitle
        self.previewImageURL = previewImageURL
        self.tags = tags
        self.createdAt = createdAt
        self.detailsSnapshot = detailsSnapshot
    }
}

@MainActor
@Observable
public final class WorkshopBookmarkStore {
    public static let preferencesKey = "loomscreen.workshop.bookmarks.v1"
    public private(set) var bookmarks: [WorkshopBookmark] = []
    public private(set) var hasStorageError = false
    /// The stored archive exists but can't be decoded; saving stays refused until `resetUnreadableArchive()`.
    public private(set) var isArchiveUnreadable = false
    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        guard let stored = defaults.object(forKey: Self.preferencesKey) else { return }
        do {
            guard let data = stored as? Data else { throw CocoaError(.coderReadCorrupt) }
            bookmarks = try JSONDecoder().decode([WorkshopBookmark].self, from: data)
        } catch {
            isArchiveUnreadable = true
            hasStorageError = true
            Logger.error("Could not read Workshop bookmarks", category: .ui)
        }
    }

    public func contains(_ id: UInt64) -> Bool {
        bookmarks.contains { $0.id == id }
    }

    public func add(_ bookmark: WorkshopBookmark) {
        guard !contains(bookmark.id) else { return }
        save(bookmarks + [bookmark])
    }

    /// Append new ids in input order and persist one archive on a healthy import.
    /// Existing entries win. Encoding failures retain sequential, per-item recovery.
    public func merge(_ incoming: [WorkshopBookmark]) {
        guard !incoming.isEmpty else { return }
        var ids = Set(bookmarks.map(\.id))
        var updated = bookmarks
        for bookmark in incoming where ids.insert(bookmark.id).inserted {
            updated.append(bookmark)
        }
        guard updated.count != bookmarks.count else { return }
        guard !isArchiveUnreadable else {
            hasStorageError = true
            return
        }
        do {
            let data = try JSONEncoder().encode(updated)
            commit(data, bookmarks: updated)
        } catch {
            // A rejected candidate must not reserve its id, and later valid
            // records still save. Replay the original input, not the deduped list.
            for bookmark in incoming {
                add(bookmark)
            }
        }
    }

    /// Hydration never re-adds a bookmark removed while its request was running.
    public func updateDetailsSnapshot(_ data: Data, for id: UInt64) {
        guard let index = bookmarks.firstIndex(where: { $0.id == id }),
              bookmarks[index].detailsSnapshot != data else { return }
        var updated = bookmarks
        let old = updated[index]
        updated[index] = WorkshopBookmark(
            id: old.id, rawTitle: old.rawTitle, previewImageURL: old.previewImageURL,
            tags: old.tags, createdAt: old.createdAt, detailsSnapshot: data
        )
        save(updated)
    }

    public func remove(_ id: UInt64) {
        save(bookmarks.filter { $0.id != id })
    }

    public func dismissStorageError() {
        hasStorageError = false
    }

    /// Discards the unreadable archive under this store's key alone.
    public func resetUnreadableArchive() {
        defaults.removeObject(forKey: Self.preferencesKey)
        bookmarks = []
        isArchiveUnreadable = false
        hasStorageError = false
    }

    public func resetAfterSettingsCleared() {
        bookmarks = []
        isArchiveUnreadable = false
        hasStorageError = false
    }

    private func save(_ updated: [WorkshopBookmark]) {
        // Preserve an unreadable archive instead of silently overwriting it.
        guard !isArchiveUnreadable else {
            hasStorageError = true
            return
        }
        do {
            let data = try JSONEncoder().encode(updated)
            commit(data, bookmarks: updated)
        } catch {
            hasStorageError = true
            Logger.error("Could not save Workshop bookmarks", category: .ui)
        }
    }

    private func commit(_ data: Data, bookmarks updated: [WorkshopBookmark]) {
        defaults.set(data, forKey: Self.preferencesKey)
        bookmarks = updated
        hasStorageError = false
    }
}
