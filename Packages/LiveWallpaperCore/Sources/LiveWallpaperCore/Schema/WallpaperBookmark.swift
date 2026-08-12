import Foundation

/// Global saved shortcut. Nil `playbackSettings` = legacy (apply leaves target settings).
public struct WallpaperBookmark: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var label: String
    public let createdAt: Date
    public var content: WallpaperContent
    public var sourceDisplayName: String?
    public var playbackSettings: BookmarkPlaybackSettings?
    /// Workshop provenance for scene dependency / source-folder restore on apply.
    public var wpeOrigin: WPEOrigin?

    public init(
        label: String,
        content: WallpaperContent,
        id: UUID = UUID(),
        createdAt: Date = Date(),
        sourceDisplayName: String? = nil,
        playbackSettings: BookmarkPlaybackSettings? = nil,
        wpeOrigin: WPEOrigin? = nil
    ) {
        self.id = id
        self.label = label
        self.content = content
        self.createdAt = createdAt
        self.sourceDisplayName = sourceDisplayName
        self.playbackSettings = playbackSettings
        self.wpeOrigin = wpeOrigin
    }

    public var wallpaperType: WallpaperType { content.wallpaperType }

    /// CAS local-HTML grant (id + original Data). Advances matching `wpeOrigin` too.
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

    /// CAS WPE source-folder grant; advances matching HTML content copies.
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
