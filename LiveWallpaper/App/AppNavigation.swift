import CoreGraphics

enum Navigation: Hashable {
    case general
    case screen(CGDirectDisplayID)
    case appleAerials
    case bookmarks
    case workshop
    case systemWallpaper
}
