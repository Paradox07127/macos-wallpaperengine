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

    public init(id: UInt64, rawTitle: String?, previewImageURL: URL?, tags: [String], createdAt: Date = Date()) {
        self.id = id
        self.rawTitle = rawTitle
        self.previewImageURL = previewImageURL
        self.tags = tags
        self.createdAt = createdAt
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
            defaults.set(data, forKey: Self.preferencesKey)
            bookmarks = updated
            hasStorageError = false
        } catch {
            hasStorageError = true
            Logger.error("Could not save Workshop bookmarks", category: .ui)
        }
    }
}
