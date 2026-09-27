import Foundation
import LiveWallpaperCore

enum DropFailure: Equatable {
    case applyNotConfirmed
    case unrecognizedDrop
    case sceneUnsupportedInBuild
    case videoBookmarkFailed
    case sourceMissing
    case htmlBookmarkFailed
    #if !LITE_BUILD
    case sceneProjectUnsupported
    case sceneImportRejected(reason: String)
    #endif

    var toastText: String {
        switch self {
        case .applyNotConfirmed:
            String(localized: "Couldn't confirm this wallpaper was applied. Try again.", bundle: .appLanguage)
        case .unrecognizedDrop:
            String(localized: "Choose a video, web file, or wallpaper folder.", bundle: .appLanguage)
        case .sceneUnsupportedInBuild:
            String(
                localized: "Wallpaper Engine projects need Loomscreen Pro, a separate free download.", bundle: .appLanguage,
                comment: "Shown in Lite when a Wallpaper Engine project folder is dropped or chosen. Both editions are free; Pro is a separate build, not a paid tier."
            )
        case .videoBookmarkFailed:
            String(localized: "Couldn't get secure access to this video.", bundle: .appLanguage)
        case .sourceMissing:
            String(
                localized: "Can't find the file. It may have been deleted, or its disk isn't connected.", bundle: .appLanguage,
                comment: "A saved or chosen wallpaper file no longer exists where it was."
            )
        case .htmlBookmarkFailed:
            String(localized: "Couldn't get secure access to this web resource.", bundle: .appLanguage)
        #if !LITE_BUILD
        case .sceneProjectUnsupported:
            String(localized: "This Wallpaper Engine project type isn't supported.", bundle: .appLanguage)
        case let .sceneImportRejected(reason):
            String(localized: "Couldn't import this project: \(reason)", bundle: .appLanguage)
        #endif
        }
    }
}
