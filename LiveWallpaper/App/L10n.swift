import Foundation
import LiveWallpaperCore

/// Centralized localized strings for AppKit-bridged surfaces (NSOpenPanel, NSWindow, NSMenu) where SwiftUI's automatic LocalizedStringKey resolution is unavailable.
enum L10n {
    enum Panel {
        static let useAsWallpaper = String(
            localized: "panel.prompt.use_as_wallpaper",
            defaultValue: "Use as Wallpaper",
            bundle: .appLanguage, comment: "Confirmation button in file pickers for applying a selected file as wallpaper."
        )

        static let importProject = String(
            localized: "panel.prompt.import_project",
            defaultValue: "Apply Project",
            bundle: .appLanguage, comment: "Confirmation button for linking and applying a local project folder in place."
        )

        static let grantAccess = String(
            localized: "panel.prompt.grant_access",
            defaultValue: "Grant Access",
            bundle: .appLanguage, comment: "Confirmation button for granting one-time folder access."
        )

        static let addVideos = String(
            localized: "panel.prompt.add_videos",
            defaultValue: "Add Videos",
            bundle: .appLanguage, comment: "Confirmation button for adding selected videos to a playlist."
        )

        static let setVideo = String(
            localized: "panel.prompt.set_video",
            defaultValue: "Set Video",
            bundle: .appLanguage, comment: "Confirmation button for assigning a selected video to a schedule slot."
        )

        static let appleAerialsAccessMessage = String(
            localized: "panel.message.apple_aerials_access",
            defaultValue: "macOS requires one-time approval to read Apple's wallpaper folder. Click \"Grant Access\" — you do not need to pick any specific file.",
            bundle: .appLanguage, comment: "Message shown in the folder picker for granting access to Apple's wallpaper folder."
        )
    }

    enum Window {
        static let settingsTitle = String(
            localized: "window.title.settings",
            defaultValue: "Loomscreen Settings",
            bundle: .appLanguage, comment: "Title of the settings window."
        )
    }

    enum Toolbar {
        static let preferences = String(
            localized: "toolbar.preferences",
            defaultValue: "Preferences",
            bundle: .appLanguage, comment: "Settings window toolbar button for opening general preferences."
        )
        static let addWallpaper = String(
            localized: "toolbar.addWallpaper",
            defaultValue: "Add wallpaper",
            bundle: .appLanguage, comment: "Settings window toolbar button that opens a video picker for the selected display."
        )
    }
}
