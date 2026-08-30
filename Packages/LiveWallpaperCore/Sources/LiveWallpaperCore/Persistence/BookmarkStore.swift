import Foundation
import Observation

/// Persistence seam (SettingsManager in app; in-memory in tests).
@MainActor
public protocol BookmarkPersisting {
    func load() -> [WallpaperBookmark]
    func save(_ bookmarks: [WallpaperBookmark])
}

/// Saved wallpaper shortcuts. App-wired `.shared` lives in SettingsManagerStoreBindings.swift.
@MainActor
@Observable
public final class BookmarkStore {
    public private(set) var bookmarks: [WallpaperBookmark]
    @ObservationIgnored private let persistence: any BookmarkPersisting

    public init(persistence: any BookmarkPersisting) {
        self.persistence = persistence
        var loaded = persistence.load()
        var didMigrate = false
        for index in loaded.indices where loaded[index].sourceDisplayName == nil {
            loaded[index].sourceDisplayName = Self.defaultSourceDisplayName(for: loaded[index].content) ?? ""
            didMigrate = true
        }
        self.bookmarks = loaded
        if didMigrate {
            persistence.save(loaded)
        }
    }

    @discardableResult
    public func add(
        label: String,
        content: WallpaperContent,
        sourceDisplayName: String? = nil,
        playbackSettings: BookmarkPlaybackSettings? = nil,
        wpeOrigin: WPEOrigin? = nil
    ) -> WallpaperBookmark {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedSourceDisplayName = sourceDisplayName
            ?? Self.nonResolvingSourceDisplayName(for: content)
            ?? ""
        let resolved = trimmed.isEmpty
            ? Self.defaultLabel(for: content, sourceDisplayName: resolvedSourceDisplayName)
            : trimmed
        let bookmark = WallpaperBookmark(
            label: resolved,
            content: content,
            sourceDisplayName: resolvedSourceDisplayName,
            playbackSettings: playbackSettings,
            wpeOrigin: wpeOrigin
        )
        bookmarks.append(bookmark)
        persist()
        Logger.info("Bookmark added: type \(content.wallpaperType.rawValue), total \(bookmarks.count)", category: .ui)
        return bookmark
    }

    public func remove(_ id: UUID) {
        let removedType = bookmarks.first(where: { $0.id == id })?.wallpaperType.rawValue ?? "Unknown"
        bookmarks.removeAll { $0.id == id }
        persist()
        Logger.info("Bookmark removed: type \(removedType), total \(bookmarks.count)", category: .ui)
    }

    public func resetAfterSettingsCleared() {
        bookmarks.removeAll()
    }

    public func reload() {
        bookmarks = persistence.load()
    }

    public func rename(_ id: UUID, to newLabel: String) {
        let trimmed = newLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = bookmarks.firstIndex(where: { $0.id == id }) else { return }
        bookmarks[index].label = trimmed
        persist()
        Logger.info("Bookmark renamed: type \(bookmarks[index].wallpaperType.rawValue)", category: .ui)
    }

    public func equivalentBookmark(
        content: WallpaperContent,
        wpeOrigin: WPEOrigin? = nil
    ) -> WallpaperBookmark? {
        bookmarks.first { existing in
            existing.content == content && existing.wpeOrigin == wpeOrigin
        }
    }

    public func containsWPEBookmark(workshopID: String) -> Bool {
        bookmarks.contains { Self.matchesWPEBookmark($0, workshopID: workshopID) }
    }

    public func removeWPEBookmarks(workshopID: String) {
        let removedCount = bookmarks.filter { Self.matchesWPEBookmark($0, workshopID: workshopID) }.count
        guard removedCount > 0 else { return }

        bookmarks.removeAll { Self.matchesWPEBookmark($0, workshopID: workshopID) }
        persist()
        Logger.info("WPE bookmarks removed: workshop \(workshopID), count \(removedCount), total \(bookmarks.count)", category: .ui)
    }

    /// CAS local-HTML grant by shortcut id + original Data.
    @discardableResult
    public func replaceHTMLBookmark(
        id bookmarkID: UUID,
        matching original: Data,
        with refreshed: Data
    ) -> Bool {
        guard let index = bookmarks.firstIndex(where: { $0.id == bookmarkID }),
              let updated = bookmarks[index].replacingHTMLBookmark(
                id: bookmarkID,
                matching: original,
                with: refreshed
              ) else { return false }
        bookmarks[index] = updated
        persist()
        return true
    }

    /// CAS by old Data only (no shortcut id — screen-config restore path).
    @discardableResult
    public func replaceMatchingHTMLBookmarks(
        matching original: Data,
        with refreshed: Data
    ) -> Bool {
        var next = bookmarks
        var didReplace = false
        for index in next.indices {
            guard case .html(let source, let config) = next[index].content,
                  let updatedSource = source.replacingLocalBookmark(
                    matching: original,
                    with: refreshed
                  ) else { continue }
            next[index].content = .html(source: updatedSource, config: config)
            if let origin = next[index].wpeOrigin,
               let updatedOrigin = origin.replacingSourceFolderBookmark(
                matching: original,
                with: refreshed
               ) {
                next[index].wpeOrigin = updatedOrigin
            }
            didReplace = true
        }
        guard didReplace else { return false }
        bookmarks = next
        persist()
        return true
    }

    /// CAS WPE grants on shortcuts; updates memory + disk together.
    @discardableResult
    public func replaceWPEOriginBookmark(
        workshopID: String,
        matching original: Data,
        with refreshed: Data
    ) -> Bool {
        var next = bookmarks
        var didReplace = false
        for index in next.indices {
            guard let updated = next[index].replacingWPEOriginBookmark(
                workshopID: workshopID,
                matching: original,
                with: refreshed
            ) else { continue }
            next[index] = updated
            didReplace = true
        }
        guard didReplace else { return false }
        bookmarks = next
        persist()
        return true
    }

    private func persist() {
        persistence.save(bookmarks)
    }

    private static func matchesWPEBookmark(_ bookmark: WallpaperBookmark, workshopID: String) -> Bool {
        if bookmark.wpeOrigin?.workshopID == workshopID {
            return true
        }
        return bookmark.content.sceneDescriptor?.workshopID == workshopID
    }

    public static func defaultLabel(for content: WallpaperContent, sourceDisplayName: String? = nil) -> String {
        if let name = nonResolvingSourceDisplayName(for: content) {
            return name
        }
        if let trimmed = sourceDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !trimmed.isEmpty {
            return trimmed
        }
        return String(localized: "Video", bundle: .appLanguage)
    }

    /// Content→display-name; `.video` is nil (needs label or bookmark resolve).
    public static func nonResolvingSourceDisplayName(for content: WallpaperContent) -> String? {
        switch content {
        case .video:
            return nil
        case .html(let source, _):
            return source.displayName
        case .scene(let descriptor):
            return String(localized: "Scene \(descriptor.workshopID)", bundle: .appLanguage, comment: "Default source label for a Wallpaper Engine scene. The placeholder is the Workshop ID.")
        }
    }

    public static func defaultSourceDisplayName(for content: WallpaperContent) -> String? {
        if case .video(let bookmarkData, _) = content {
            return ResourceUtilities.resolveBookmarkName(bookmarkData)
        }
        return nonResolvingSourceDisplayName(for: content)
    }
}
