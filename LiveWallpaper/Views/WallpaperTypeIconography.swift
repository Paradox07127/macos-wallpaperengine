import LiveWallpaperCore

/// WallpaperType → SF Symbol used by MenuBarDisplayRow.
extension WallpaperType {
    var displaySymbolName: String {
        switch self {
        case .video:
            return "play.rectangle"
        case .html:
            return "globe"
        case .scene:
            return "cube.transparent"
        }
    }

    /// `nil` = no wallpaper configured; falls back to the bare display glyph.
    static func displaySymbolName(for type: WallpaperType?) -> String {
        type?.displaySymbolName ?? "display"
    }
}
