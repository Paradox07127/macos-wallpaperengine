import Foundation

/// One row in the global Wallpaper Engine import history (LRU, capped at 20).
public struct WPEHistoryEntry: Codable, Equatable, Sendable, Identifiable {
    public let origin: WPEOrigin
    public let importedAt: Date
    public var lastUsedAt: Date?
    /// On-disk size of the source folder, computed once and persisted. `nil` until first
    /// measured, and for entries imported before this field existed.
    public var sizeBytes: Int64?

    public init(origin: WPEOrigin, importedAt: Date, lastUsedAt: Date? = nil, sizeBytes: Int64? = nil) {
        self.origin = origin
        self.importedAt = importedAt
        self.lastUsedAt = lastUsedAt
        self.sizeBytes = sizeBytes
    }

    public var id: String { origin.workshopID }

    public func replacingSourceFolderBookmark(
        workshopID: String,
        matching original: Data,
        with refreshed: Data
    ) -> WPEHistoryEntry? {
        guard origin.workshopID == workshopID,
              let updatedOrigin = origin.replacingSourceFolderBookmark(
                matching: original,
                with: refreshed
              ) else { return nil }
        return WPEHistoryEntry(
            origin: updatedOrigin,
            importedAt: importedAt,
            lastUsedAt: lastUsedAt,
            sizeBytes: sizeBytes
        )
    }
}
