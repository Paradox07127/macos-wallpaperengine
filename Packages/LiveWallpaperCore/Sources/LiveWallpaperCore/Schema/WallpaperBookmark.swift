import Foundation

/// Applying one never touches the target display's settings; `playbackSettings` is
/// kept for older files and never read (see `.notes/plan/screen-schemes.md`).
public struct WallpaperBookmark: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var label: String
    public let createdAt: Date
    public var content: WallpaperContent
    public var sourceDisplayName: String?
    public var playbackSettings: BookmarkPlaybackSettings?
    /// Workshop provenance for scene dependency / source-folder restore on apply.
    public var wpeOrigin: WPEOrigin?
    /// File name of the still captured when this was saved, in the app's cover directory.
    /// Nil for older entries and for captures that did not come back in time.
    public var coverFileName: String?

    public init(
        label: String,
        content: WallpaperContent,
        id: UUID = UUID(),
        createdAt: Date = Date(),
        sourceDisplayName: String? = nil,
        playbackSettings: BookmarkPlaybackSettings? = nil,
        wpeOrigin: WPEOrigin? = nil,
        coverFileName: String? = nil
    ) {
        self.id = id
        self.label = label
        self.content = content
        self.createdAt = createdAt
        self.sourceDisplayName = sourceDisplayName
        self.playbackSettings = playbackSettings
        self.wpeOrigin = wpeOrigin
        self.coverFileName = coverFileName
    }

    public var wallpaperType: WallpaperType { content.wallpaperType }

    public func replacingHTMLBookmark(
        id bookmarkID: UUID,
        matching original: Data,
        with refreshed: Data
    ) -> WallpaperBookmark? {
        guard id == bookmarkID,
              case .html(let source, let config) = content,
              let updatedSource = source.replacingLocalBookmark(
                matching: original,
                with: refreshed
              ) else { return nil }

        var copy = self
        copy.content = .html(source: updatedSource, config: config)
        if let origin = copy.wpeOrigin,
           let updatedOrigin = origin.replacingSourceFolderBookmark(
            matching: original,
            with: refreshed
           ) {
            copy.wpeOrigin = updatedOrigin
        }
        return copy
    }

    public func replacingWPEOriginBookmark(
        workshopID: String,
        matching original: Data,
        with refreshed: Data
    ) -> WallpaperBookmark? {
        guard let origin = wpeOrigin,
              origin.workshopID == workshopID,
              let updatedOrigin = origin.replacingSourceFolderBookmark(
                matching: original,
                with: refreshed
              ) else { return nil }

        var copy = self
        copy.wpeOrigin = updatedOrigin
        if case .html(let source, let config) = copy.content,
           let updatedSource = source.replacingLocalBookmark(
            matching: original,
            with: refreshed
           ) {
            copy.content = .html(source: updatedSource, config: config)
        }
        return copy
    }

    public var iconName: String {
        switch content {
        case .video: return "play.rectangle"
        case .html(let source, _): return source.iconName
        case .scene: return "cube.transparent"
        }
    }

}
