#if !LITE_BUILD
import Foundation
import LiveWallpaperCore

/// Display only: `requiredtags` / `excludedtags` and selection state keep the
/// English tag, which is what Steam matches on.
enum WorkshopTagLocalization {
    /// Known tag localized, anything else verbatim — resolution tags are bare
    /// numbers and Steam serves whatever an author typed.
    static func displayName(_ tag: String) -> String {
        switch tag.lowercased() {
        case "abstract": String(localized: "Abstract", bundle: .appLanguage, comment: "Workshop genre tag.")
        case "animal": String(localized: "Animal", bundle: .appLanguage, comment: "Workshop genre tag.")
        case "anime": String(localized: "Anime", bundle: .appLanguage, comment: "Workshop genre tag.")
        case "cartoon": String(localized: "Cartoon", bundle: .appLanguage, comment: "Workshop genre tag.")
        case "cgi": String(localized: "CGI", bundle: .appLanguage, comment: "Workshop genre tag: computer-generated imagery.")
        case "cyberpunk": String(localized: "Cyberpunk", bundle: .appLanguage, comment: "Workshop genre tag.")
        case "fantasy": String(localized: "Fantasy", bundle: .appLanguage, comment: "Workshop genre tag.")
        case "game": String(localized: "Game", bundle: .appLanguage, comment: "Workshop genre tag: video-game artwork.")
        case "girls": String(localized: "Girls", bundle: .appLanguage, comment: "Workshop genre tag: wallpapers featuring female characters.")
        case "guys": String(localized: "Guys", bundle: .appLanguage, comment: "Workshop genre tag: wallpapers featuring male characters.")
        case "landscape": String(localized: "Landscape", bundle: .appLanguage, comment: "Workshop genre tag: scenery, not the aspect ratio.")
        case "medieval": String(localized: "Medieval", bundle: .appLanguage, comment: "Workshop genre tag.")
        case "memes": String(localized: "Memes", bundle: .appLanguage, comment: "Workshop genre tag.")
        case "mmd": String(localized: "MMD", bundle: .appLanguage, comment: "Workshop genre tag: MikuMikuDance. Kept as the acronym in every language.")
        case "music": String(localized: "Music", bundle: .appLanguage, comment: "Workshop genre tag.")
        case "nature": String(localized: "Nature", bundle: .appLanguage, comment: "Workshop genre tag.")
        case "pixel art": String(localized: "Pixel art", bundle: .appLanguage, comment: "Workshop genre tag.")
        case "relaxing": String(localized: "Relaxing", bundle: .appLanguage, comment: "Workshop genre tag.")
        case "retro": String(localized: "Retro", bundle: .appLanguage, comment: "Workshop genre tag.")
        case "sci-fi": String(localized: "Sci-Fi", bundle: .appLanguage, comment: "Workshop genre tag: science fiction.")
        case "sports": String(localized: "Sports", bundle: .appLanguage, comment: "Workshop genre tag.")
        case "technology": String(localized: "Technology", bundle: .appLanguage, comment: "Workshop genre tag.")
        case "television": String(localized: "Television", bundle: .appLanguage, comment: "Workshop genre tag: film and TV.")
        case "vehicle": String(localized: "Vehicle", bundle: .appLanguage, comment: "Workshop genre tag.")
        case "unspecified": String(localized: "Unspecified", bundle: .appLanguage, comment: "Workshop genre tag: the author picked no genre.")
        case "scene": String(localized: "Scene", bundle: .appLanguage, comment: "Workshop content-type filter: scene wallpapers.")
        case "video": String(localized: "Video", bundle: .appLanguage, comment: "Workshop content-type filter: video wallpapers.")
        case "web": String(localized: "Web", bundle: .appLanguage, comment: "Workshop content-type filter: web wallpapers.")
        case "everyone": String(localized: "Everyone", bundle: .appLanguage, comment: "Workshop maturity filter: everyone.")
        case "questionable": String(localized: "Questionable", bundle: .appLanguage, comment: "Workshop maturity filter: questionable.")
        case "mature": String(localized: "Mature", bundle: .appLanguage, comment: "Workshop maturity filter: mature.")
        case "approved": String(localized: "Approved", bundle: .appLanguage, comment: "Workshop tag: the item passed Wallpaper Engine's content review.")
        case "audio responsive": String(localized: "Audio responsive", bundle: .appLanguage, comment: "Workshop tag: the wallpaper reacts to system audio.")
        case "customizable": String(localized: "Customizable", bundle: .appLanguage, comment: "Workshop tag: the wallpaper exposes user properties.")
        case "media integration": String(localized: "Media Integration", bundle: .appLanguage, comment: "Workshop tag: the wallpaper shows what is playing.")
        case "user shortcut": String(localized: "User Shortcut", bundle: .appLanguage, comment: "Workshop tag: the wallpaper binds its own hot key.")
        case "video texture": String(localized: "Video Texture", bundle: .appLanguage, comment: "Workshop tag: the scene plays video inside a texture.")
        case "asset pack": String(localized: "Asset Pack", bundle: .appLanguage, comment: "Workshop tag: reusable assets rather than a finished wallpaper.")
        case "standard definition": String(localized: "Standard Definition", bundle: .appLanguage, comment: "Workshop resolution filter display label.")
        case "preset": String(localized: "Preset", bundle: .appLanguage)
        // `3D`, `HDR`, `Puppet Warp` deliberately absent — acronyms, and a WPE
        // feature name its own editor leaves untranslated.
        default: tag
        }
    }
}
#endif
