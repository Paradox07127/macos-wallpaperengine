#if !LITE_BUILD
import AppKit
import LiveWallpaperCore
import SwiftUI

extension AppStorageLocation.Kind {
    var title: LocalizedStringKey {
        switch self {
        case .video: "Scene Video Texture Cache"
        case .query: "Workshop Search Cache"
        case .previews: "Workshop Preview Images"
        case .shaders: "Shader Translation Cache"
        case .audio: "Audio Transcode Cache"
        case .webCache: "Web Wallpaper Cache"
        case .configuration: "Settings & Library"
        case .covers: "Saved Covers"
        case .legacyScenes: "Legacy Scene Files"
        case .diagnostics: "Scene Diagnostics"
        case .logs: "Runtime Logs"
        case .webData: "Web Wallpaper Data"
        case .preferences: "App Preferences"
        case .support: "Other App Support"
        case .systemCaches: "Other System Caches"
        case .temporary: "Temporary Files"
        case .systemMetadata: "System Wallpaper Metadata"
        case .steamTools: "SteamCMD Installation"
        case .steamProfiles: "Steam Sign-in Profiles"
        case .credentials: "Credential Files"
        case .application: "Application"
        case .localWallpapers: "Local Wallpaper Files"
        }
    }

    var detail: LocalizedStringKey {
        switch self {
        case .video: "Extracted scene video textures. Up to 2 GB; leased files stay until playback releases them."
        case .query: "Search results and item metadata. Up to 100 MB; refreshed from Steam after clearing."
        case .previews: "Downloaded Workshop previews. Up to 256 MB; images download again when viewed."
        case .shaders: "Translated shader source. Up to 64 MB per schema; scenes compile it again when needed."
        case .audio: "Ogg audio converted for web wallpapers. Up to 256 MB; active conversions are kept."
        case .webCache: "WebKit page and resource caches. Clearing keeps cookies and website local data."
        case .configuration: "Display setups, saved schemes and library records. Covers are measured separately."
        case .covers: "Saved wallpaper and scheme artwork. Kept with your library, rather than cleared as a cache."
        case .legacyScenes: "Older extracted scene resources may still be the only copy of an imported wallpaper. Manage them in the library."
        case .diagnostics: "Scene debug reports, captures and oracle output. Excludes legacy scene resources."
        case .logs: "Rotating runtime logs used for troubleshooting. The running app owns these files."
        case .webData: "Cookies, local storage and databases for persistent web wallpapers. Kept when clearing caches."
        case .preferences: "App preferences and folder access bookmarks stored by macOS."
        case .support: "Other support files, monitor cursors and protected credentials. Excludes separately listed locations."
        case .systemCaches: "macOS, networking and updater caches. Managed by their owners; excludes separately measured caches."
        case .temporary: "In-use package mappings, conversions, exports and test scratch files. Owners remove these after use or at the next launch."
        case .systemMetadata: "Shared manifest and provider state. Video copies are counted under System Wallpaper."
        case .steamTools: "SteamCMD installation required by the Workshop connector. Managed automatically."
        case .steamProfiles: "Protected Steam sign-in data that keeps your account connected. Managed automatically."
        case .credentials: "App-managed credential files. Credentials in macOS Keychain are protected and their disk size cannot be measured separately."
        case .application: "The running Loomscreen application, including its bundled resources and extensions. Managed by installation and updates."
        case .localWallpapers: "Local wallpaper files and folders, including linked Apple Aerials. Included in wallpaper storage."
        }
    }

    var symbol: String {
        switch self {
        case .video: "film"
        case .query: "magnifyingglass"
        case .previews, .covers: "photo.stack"
        case .shaders: "cpu"
        case .audio: "waveform"
        case .webCache, .webData: "globe"
        case .configuration, .preferences: "slider.horizontal.3"
        case .logs, .diagnostics: "doc.text"
        case .temporary: "clock"
        case .steamProfiles, .credentials: "lock"
        case .application: "app"
        default: "folder"
        }
    }
}
#endif
