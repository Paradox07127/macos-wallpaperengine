import LiveWallpaperCore
import SwiftUI

enum DropFailure: Identifiable, Equatable {
    case applyNotConfirmed
    case unrecognizedDrop
    case sceneLibraryDrop
    case sceneUnsupportedInBuild
    case videoFormatUnsupported
    case videoBookmarkFailed
    case videoCopyFailed
    case htmlBookmarkFailed
    case htmlPickerWrongType
    #if !LITE_BUILD
    case sceneProjectUnsupported
    case sceneImportRejected(reason: String)
    #endif

    var id: String {
        switch self {
        case .applyNotConfirmed: "applyNotConfirmed"
        case .unrecognizedDrop: "unrecognizedDrop"
        case .sceneLibraryDrop: "sceneLibraryDrop"
        case .sceneUnsupportedInBuild: "sceneUnsupportedInBuild"
        case .videoFormatUnsupported: "videoFormatUnsupported"
        case .videoBookmarkFailed: "videoBookmarkFailed"
        case .videoCopyFailed: "videoCopyFailed"
        case .htmlBookmarkFailed: "htmlBookmarkFailed"
        case .htmlPickerWrongType: "htmlPickerWrongType"
        #if !LITE_BUILD
        case .sceneProjectUnsupported: "sceneProjectUnsupported"
        case .sceneImportRejected: "sceneImportRejected"
        #endif
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .applyNotConfirmed: "Couldn't confirm this wallpaper was applied. Try again."
        case .unrecognizedDrop: "Unsupported file type"
        case .sceneLibraryDrop: "That folder is a scene library"
        case .sceneUnsupportedInBuild: "This version doesn't play scenes"
        case .videoFormatUnsupported: "Video format not supported"
        case .videoBookmarkFailed: "Couldn't open video"
        case .videoCopyFailed: "Couldn't copy that video"
        case .htmlBookmarkFailed: "Couldn't open web resource"
        case .htmlPickerWrongType: "Pick a web file or folder"
        #if !LITE_BUILD
        case .sceneProjectUnsupported: "This Wallpaper Engine project type isn't supported."
        case let .sceneImportRejected(reason): "Couldn't import this scene: \(reason)"
        #endif
        }
    }

    var message: LocalizedStringKey {
        switch self {
        case .applyNotConfirmed:
            "Couldn't confirm this wallpaper was applied. Try again."
        case .unrecognizedDrop:
            "Drop a video file, web file, or folder to use it as a wallpaper."
        case .sceneLibraryDrop:
            "It holds many wallpapers rather than one. Import it from the Workshop library instead."
        case .sceneUnsupportedInBuild:
            "This copy of Loomscreen plays video and web wallpapers. Drop one of those instead."
        case .videoFormatUnsupported:
            "Choose an .mp4, .mov, .m4v, or similar video file."
        case .videoBookmarkFailed:
            "macOS couldn't grant the app secure access to that file. Try a different video, or move the file to a folder you own."
        case .videoCopyFailed:
            "Loomscreen couldn't copy it into its own storage. Check free space and try again."
        case .htmlBookmarkFailed:
            "macOS couldn't grant the app secure access to that resource. Try moving it to a folder you own."
        case .htmlPickerWrongType:
            "The selection isn't a web file or a folder containing an index page."
        #if !LITE_BUILD
        case .sceneProjectUnsupported:
            "This Wallpaper Engine project type isn't supported."
        case let .sceneImportRejected(reason):
            "Couldn't import this scene: \(reason)"
        #endif
        }
    }

    var toastText: String {
        switch self {
        case .applyNotConfirmed:
            String(localized: "Couldn't confirm this wallpaper was applied. Try again.", bundle: .appLanguage)
        case .unrecognizedDrop:
            String(localized: "Choose a video, web file, or wallpaper folder.", bundle: .appLanguage)
        case .sceneLibraryDrop:
            String(localized: "Import this folder from the Workshop library.", bundle: .appLanguage)
        case .sceneUnsupportedInBuild:
            String(localized: "This version supports video and web wallpapers only.", bundle: .appLanguage)
        case .videoFormatUnsupported:
            String(localized: "Choose a supported video format.", bundle: .appLanguage)
        case .videoBookmarkFailed:
            String(localized: "Couldn't get secure access to this video.", bundle: .appLanguage)
        case .videoCopyFailed:
            String(localized: "Couldn't copy this video; check free space.", bundle: .appLanguage)
        case .htmlBookmarkFailed:
            String(localized: "Couldn't get secure access to this web resource.", bundle: .appLanguage)
        case .htmlPickerWrongType:
            String(localized: "Choose a web file or a folder with an index page.", bundle: .appLanguage)
        #if !LITE_BUILD
        case .sceneProjectUnsupported:
            String(localized: "This Wallpaper Engine project type isn't supported.", bundle: .appLanguage)
        case let .sceneImportRejected(reason):
            String(localized: "Couldn't import this scene: \(reason)", bundle: .appLanguage)
        #endif
        }
    }
}
