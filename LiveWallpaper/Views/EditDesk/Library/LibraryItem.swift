import CoreGraphics
import Foundation
import LiveWallpaperCore

struct LibraryItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case video, web, scene, aerial

        var localizedName: String {
            switch self {
            case .video: String(localized: "Video", bundle: .appLanguage)
            case .web: String(localized: "Web", bundle: .appLanguage)
            case .scene: String(localized: "Scene", bundle: .appLanguage)
            case .aerial: String(localized: "Aerial", bundle: .appLanguage)
            }
        }
    }

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
    /// The last background probe found the file or folder gone or no longer granted.
    var isSourceMissing = false

    /// Localized; nil while the item can run and its source was found.
    var statusBadge: String? {
        if !isSupported {
            return String(localized: "Not supported on this Mac", bundle: .appLanguage, comment: "Library card badge: this Mac cannot run the wallpaper's type.")
        }
        if isSourceMissing {
            return String(localized: "File unavailable", bundle: .appLanguage, comment: "Library card badge: the wallpaper's file or folder is gone or no longer accessible.")
        }
        return nil
    }

    /// The Workshop "Currently in use" and "Update available" switches reach Workshop projects only.
    func cardBadges(
        among displays: [StageDisplay], updatedWorkshopIDs: Set<String>, preferences: GalleryCardPreferences
    ) -> LibraryCardBadges {
        let onBadge = StageCard.onBadge(on: onDisplays, among: displays)
        #if !LITE_BUILD
        if case let .workshop(entry) = source {
            return LibraryCardBadges(
                onBadge: preferences.showsInUse ? onBadge : nil,
                needsUpdate: preferences.showsUpdate && updatedWorkshopIDs.contains(entry.id)
            )
        }
        #endif
        return LibraryCardBadges(onBadge: onBadge)
    }
}

/// What a library grid tile draws over its thumbnail.
struct LibraryCardBadges: Equatable {
    /// `ON Studio` while the item runs on a display; nil otherwise, or while its switch hides it.
    var onBadge: String?
    var needsUpdate = false

    /// VoiceOver's reading of a tile titled `title` that carries these badges.
    func accessibilityLabel(title: String) -> String {
        var parts = [title]
        if onBadge != nil {
            parts.append(String(localized: "Currently in use", bundle: .appLanguage, comment: "A11y: this wallpaper is the active one."))
        }
        if needsUpdate {
            parts.append(String(localized: "Update available", bundle: .appLanguage, comment: "A11y: the installed item has a newer version on Steam."))
        }
        return parts.joined(separator: ", ")
    }
}
