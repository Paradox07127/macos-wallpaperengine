import CoreGraphics
import Foundation
import LiveWallpaperCore

struct LibraryItem: Identifiable, Equatable {
    enum Kind: Equatable { case video, web, scene, aerial }

    enum Source: Equatable {
        case bookmark(WallpaperBookmark)
        case aerial(AerialAsset)
        #if !LITE_BUILD
        case workshop(WPEHistoryEntry)
        #endif
    }

    let id: String
    var title: String
    var kind: Kind
    var source: Source
    var isSteam: Bool
    var createdAt: Date
    var lastUsedAt: Date?
    var onDisplays: [CGDirectDisplayID]
    var thumbnail: ShelfThumbnailCache.Request?
    var metadata: LibraryMetadata?
    var isVariant: Bool
    var parentID: String?
    var isSupported: Bool
}
