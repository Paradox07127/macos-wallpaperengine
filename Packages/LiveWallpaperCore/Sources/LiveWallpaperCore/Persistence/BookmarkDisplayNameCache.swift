import Foundation
import Observation

/// Sync display-name cache for security-scoped bookmarks (`@Observable` for SwiftUI).
@MainActor
@Observable
public final class BookmarkDisplayNameCache {
    private var names: [Data: String] = [:]

    @ObservationIgnored private var unresolved: Set<Data> = []

    public init() {}

    public func name(for bookmarkData: Data) -> String? {
        names[bookmarkData]
    }

    /// A nil/empty `name` clears the entry and marks the bookmark unresolved.
    public func record(_ bookmarkData: Data, name: String?) {
        guard !bookmarkData.isEmpty else { return }
        guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            names.removeValue(forKey: bookmarkData)
            unresolved.insert(bookmarkData)
            return
        }
        names[bookmarkData] = trimmed
        unresolved.remove(bookmarkData)
    }

    public func resolveIfNeeded(_ bookmarkData: Data) {
        guard !bookmarkData.isEmpty,
              names[bookmarkData] == nil,
              !unresolved.contains(bookmarkData) else { return }
        record(bookmarkData, name: ResourceUtilities.resolveBookmarkName(bookmarkData))
    }

    public func prime(bookmarks: [Data]) {
        for bookmarkData in bookmarks {
            resolveIfNeeded(bookmarkData)
        }
    }
}
