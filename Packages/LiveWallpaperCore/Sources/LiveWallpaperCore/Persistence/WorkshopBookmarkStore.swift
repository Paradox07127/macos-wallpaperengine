import Foundation
import Observation

/// A saved Workshop reference; saving it never downloads or applies a wallpaper.
public struct WorkshopBookmark: Codable, Equatable, Identifiable, Sendable {
    public let id: UInt64
    public let title: String
    public let previewImageURL: URL?
    public let tags: [String]
    public let createdAt: Date

    public init(id: UInt64, title: String, previewImageURL: URL?, tags: [String], createdAt: Date = Date()) {
        self.id = id
        self.title = title
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
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var couldLoad = true

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        guard let data = defaults.data(forKey: Self.preferencesKey) else { return }
        do {
            bookmarks = try JSONDecoder().decode([WorkshopBookmark].self, from: data)
        } catch {
            couldLoad = false
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

    public func resetAfterSettingsCleared() {
        bookmarks = []
        couldLoad = true
        hasStorageError = false
    }

    private func save(_ updated: [WorkshopBookmark]) {
        // Preserve an unreadable archive instead of silently overwriting it.
        guard couldLoad else {
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
