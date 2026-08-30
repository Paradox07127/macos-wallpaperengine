import Foundation
import LiveWallpaperCore

/// Centralized localized strings for AppKit-bridged surfaces (NSOpenPanel, NSWindow, NSMenu) where SwiftUI's automatic LocalizedStringKey resolution is unavailable.
enum L10n {
    enum Panel {
        static var useAsWallpaper: String { String(
            localized: "panel.prompt.use_as_wallpaper",
            defaultValue: "Use as Wallpaper",
            bundle: .appLanguage, comment: "Confirmation button in file pickers for applying a selected file as wallpaper."
        ) }

        static var importProject: String { String(
            localized: "panel.prompt.import_project",
            defaultValue: "Apply Project",
            bundle: .appLanguage, comment: "Confirmation button for linking and applying a local project folder in place."
        ) }

        static var grantAccess: String { String(
            localized: "panel.prompt.grant_access",
            defaultValue: "Grant Access",
            bundle: .appLanguage, comment: "Confirmation button for granting one-time folder access."
        ) }

        static var addVideos: String { String(
            localized: "panel.prompt.add_videos",
            defaultValue: "Add Videos",
            bundle: .appLanguage, comment: "Confirmation button for adding selected videos to a playlist."
        ) }

        static var setVideo: String { String(
            localized: "panel.prompt.set_video",
            defaultValue: "Set Video",
            bundle: .appLanguage, comment: "Confirmation button for assigning a selected video to a schedule slot."
        ) }

        static var appleAerialsAccessMessage: String { String(
            localized: "panel.message.apple_aerials_access",
            defaultValue: "macOS requires one-time approval to read Apple's wallpaper folder. Click \"Grant Access\" — you do not need to pick any specific file.",
            bundle: .appLanguage, comment: "Message shown in the folder picker for granting access to Apple's wallpaper folder."
        ) }
    }

    enum Window {
        static var settingsTitle: String { String(
            localized: "window.title.settings",
            defaultValue: "Loomscreen Settings",
            bundle: .appLanguage, comment: "Title of the settings window."
        ) }
    }

    enum Toolbar {
        static var preferences: String { String(
            localized: "toolbar.preferences",
            defaultValue: "Preferences",
            bundle: .appLanguage, comment: "Settings window toolbar button for opening general preferences."
        ) }
        static var addWallpaper: String { String(
            localized: "toolbar.addWallpaper",
            defaultValue: "Add wallpaper",
            bundle: .appLanguage, comment: "Settings window toolbar button that opens a video picker for the selected display."
        ) }
    }
}
