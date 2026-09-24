import Foundation

/// Content only: display playback preferences and overlay settings stay with the display.
public struct WallpaperQueueEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var content: WallpaperContent
    public var origin: WPEOrigin?

    public init(id: String = UUID().uuidString, title: String, content: WallpaperContent, origin: WPEOrigin? = nil) {
        self.id = id
        self.title = title
        self.content = content
        self.origin = origin
    }
}

public extension ScreenConfiguration {
    /// Read-through migration preserves the primary position and cursor of older video lists.
    var effectiveWallpaperQueue: [WallpaperQueueEntry] {
        if let wallpaperQueue {
            return wallpaperQueue
        }
        return combinedPlaylist.enumerated().map { index, bookmark in
            WallpaperQueueEntry(
                id: "legacy-video-\(index)", title: "",
                content: .video(bookmarkData: bookmark, packageEntryName: bookmark == savedVideoBookmarkData ? savedVideoPackageEntryName : nil)
            )
        }
    }

    func applyingAutomationEntry(_ entry: WallpaperQueueEntry) -> ScreenConfiguration {
        var result = self
        result.rememberCurrentSceneCustomization()
        switch entry.content {
        case let .video(data, package):
            result.activeWallpaper = .video(bookmarkData: data, packageEntryName: package)
        case let .html(source, config):
            result.setHTMLWallpaper(source: source, config: config)
        case let .scene(descriptor):
            result.setSceneWallpaper(descriptor, origin: entry.origin)
        }
        result.wpeOrigin = entry.origin
        return result
    }
}

public extension WallpaperQueueEntry {
    func refreshingScenePresets(in library: [String: ScenePreset]) -> Self {
        var copy = self
        if case let .scene(descriptor) = content {
            copy.content = .scene(descriptor.refreshingPresetSnapshot(in: library))
        }
        return copy
    }

    func replacingVideoBookmark(_ original: Data, with replacement: Data) -> Self {
        var copy = self
        if case let .video(data, package) = content, data == original {
            copy.content = .video(bookmarkData: replacement, packageEntryName: package)
        }
        return copy
    }

    func replacingHTMLBookmark(_ original: Data, with replacement: Data) -> Self {
        var copy = self
        if case let .html(source, config) = content,
           let updated = source.replacingLocalBookmark(matching: original, with: replacement) {
            copy.content = .html(source: updated, config: config)
        }
        return copy
    }
}
