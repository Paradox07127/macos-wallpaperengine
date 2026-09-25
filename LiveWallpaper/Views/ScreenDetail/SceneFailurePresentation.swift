#if !LITE_BUILD
import AppKit
import LiveWallpaperCore
import SwiftUI

struct SceneFailurePresentation {
    let failureClass: WallpaperFailureClass
    let tint: Color
    let symbol: String
    let code: String
    let title: Text
    let message: Text
    /// File names and raw values only, never a sentence; nil = no technical line.
    let detail: String?
    let recovery: [WallpaperFailureRecovery]
}

extension FallbackReason {
    var failureClass: WallpaperFailureClass {
        switch self {
        case .unsupportedType, .sceneShaderUnsupported, .requiresWindowsPlugin, .texContainerUnsupported, .texUnsupportedFormat:
            .fatal
        case .sceneParseFailed, .sceneLoadFailed, .texDecodeFailed:
            .blocked
        case .missingDependency, .sceneResourceMissing:
            .needsParts
        }
    }

    /// Mapped through `failureClass`, so a reason cannot carry two colours.
    var tint: Color {
        failureClass.tint
    }

    var symbol: String {
        switch self {
        case .requiresWindowsPlugin: "nosign"
        case .unsupportedType, .sceneShaderUnsupported: "xmark.octagon.fill"
        case .texContainerUnsupported: "doc.questionmark.fill"
        case .sceneParseFailed: "exclamationmark.octagon.fill"
        case .sceneLoadFailed: "exclamationmark.triangle.fill"
        case .missingDependency: "puzzlepiece.extension.fill"
        case .sceneResourceMissing: "folder.badge.questionmark"
        case .texUnsupportedFormat, .texDecodeFailed: "photo.badge.exclamationmark"
        }
    }

    var code: String {
        switch self {
        case .unsupportedType: "WPE_UNSUPPORTED_TYPE"
        case .sceneParseFailed: "WPE_SCENE_PARSE"
        case .sceneLoadFailed: "WPE_SCENE_LOAD"
        case .sceneShaderUnsupported: "WPE_SHADER_UNSUPPORTED"
        case .sceneResourceMissing: "WPE_RESOURCE_MISS"
        case .missingDependency: "WPE_MISSING_DEPENDENCY"
        case .requiresWindowsPlugin: "WPE_WINDOWS_PLUGIN"
        case .texContainerUnsupported: "WPE_TEX_CONTAINER"
        case .texUnsupportedFormat: "WPE_TEX_FORMAT"
        case .texDecodeFailed: "WPE_TEX_DECODE"
        }
    }

    var detail: String? {
        switch self {
        case let .sceneParseFailed(parserDetail): "scene.json · \(LogPrivacyRedactor.scrub(parserDetail))"
        case let .texContainerUnsupported(magic): ".tex · \(magic)"
        case let .sceneLoadFailed(loadDetail): LogPrivacyRedactor.scrub(loadDetail)
        case let .texDecodeFailed(decodeDetail): LogPrivacyRedactor.scrub(decodeDetail)
        case .requiresWindowsPlugin: ".dll"
        case .unsupportedType, .sceneShaderUnsupported, .sceneResourceMissing, .missingDependency, .texUnsupportedFormat: nil
        }
    }

    /// `engineAssetsAuthorized`: assets already linked means "Set Up Assets" would send the user
    /// back through a step they completed; the Workshop page is then the place to re-download.
    func recovery(workshopID: String, engineAssetsAuthorized: Bool = false) -> [WallpaperFailureRecovery] {
        let isSteamItem = !workshopID.isEmpty && workshopID.allSatisfy(\.isNumber)
        switch self {
        case let .missingDependency(ids):
            var actions: [WallpaperFailureRecovery] = [.copyDependencyIDs(ids), .retry]
            if isSteamItem {
                actions.insert(.openWorkshop(workshopID), at: 1)
            }
            return actions
        case .sceneResourceMissing:
            var actions: [WallpaperFailureRecovery] = engineAssetsAuthorized ? [.retry] : [.configureEngineAssets, .retry]
            if isSteamItem {
                actions.append(.openWorkshop(workshopID))
            }
            return actions
        case .sceneParseFailed, .sceneLoadFailed, .texDecodeFailed:
            return isSteamItem ? [.retry, .openWorkshop(workshopID)] : [.retry]
        case .unsupportedType, .sceneShaderUnsupported, .requiresWindowsPlugin,
             .texContainerUnsupported, .texUnsupportedFormat:
            return isSteamItem ? [.openWorkshop(workshopID)] : []
        }
    }

    func presentation(origin: WPEOrigin, engineAssetsAuthorized: Bool) -> SceneFailurePresentation {
        SceneFailurePresentation(
            failureClass: failureClass,
            tint: tint,
            symbol: symbol,
            code: code,
            title: Text(verbatim: localizedTitle(originalType: origin.originalType)),
            message: Text(verbatim: localizedMessage(
                originalType: origin.originalType,
                engineAssetsAuthorized: engineAssetsAuthorized
            )),
            detail: detail,
            recovery: recovery(workshopID: origin.workshopID, engineAssetsAuthorized: engineAssetsAuthorized)
        )
    }

    func localizedTitle(originalType: WPEType) -> String {
        switch self {
        case .unsupportedType:
            switch originalType {
            case .application:
                return String(localized: "Executable wallpapers can't be imported", defaultValue: "Executable wallpapers can't be imported", bundle: .appLanguage, comment: "Wallpaper Engine fallback warning title.")
            case .scene:
                return String(localized: "Unsupported scene format", defaultValue: "Unsupported scene format", bundle: .appLanguage, comment: "Wallpaper Engine fallback warning title.")
            default:
                return String(localized: "This wallpaper type is not supported", defaultValue: "This wallpaper type is not supported", bundle: .appLanguage, comment: "Wallpaper Engine fallback warning title.")
            }
        case .sceneParseFailed:
            return String(localized: "This scene can't be opened", defaultValue: "This scene can't be opened", bundle: .appLanguage, comment: "Wallpaper Engine fallback warning title.")
        case .sceneLoadFailed:
            return String(localized: "This wallpaper didn't load", bundle: .appLanguage)
        case .sceneShaderUnsupported:
            return String(localized: "This scene uses effects Loomscreen can't render", defaultValue: "This scene uses effects Loomscreen can't render", bundle: .appLanguage, comment: "Wallpaper Engine fallback warning title.")
        case .sceneResourceMissing:
            return String(localized: "Some scene assets are missing", defaultValue: "Some scene assets are missing", bundle: .appLanguage, comment: "Wallpaper Engine fallback warning title.")
        case let .missingDependency(ids):
            if ids.count == 1 {
                return String(localized: "Missing 1 Workshop dependency", defaultValue: "Missing 1 Workshop dependency", bundle: .appLanguage, comment: "Wallpaper Engine fallback warning title.")
            }
            return String(localized: "Missing \(ids.count) Workshop dependencies", bundle: .appLanguage, comment: "Wallpaper Engine fallback warning title. The placeholder is the missing dependency count.")
        case .requiresWindowsPlugin:
            return String(localized: "This wallpaper only works on Windows", defaultValue: "This wallpaper only works on Windows", bundle: .appLanguage, comment: "Wallpaper Engine fallback warning title.")
        case .texContainerUnsupported, .texUnsupportedFormat:
            return String(localized: "This wallpaper uses a file format Loomscreen can't read", defaultValue: "This wallpaper uses a file format Loomscreen can't read", bundle: .appLanguage, comment: "Wallpaper Engine fallback warning title.")
        case .texDecodeFailed:
            return String(localized: "Some images in this scene can't be read", defaultValue: "Some images in this scene can't be read", bundle: .appLanguage, comment: "Wallpaper Engine fallback warning title.")
        }
    }

    func localizedMessage(originalType: WPEType, engineAssetsAuthorized: Bool) -> String {
        switch self {
        case .unsupportedType:
            switch originalType {
            case .application:
                return String(localized: "For your security, LiveWallpaper does not run executable workshop projects.", defaultValue: "For your security, LiveWallpaper does not run executable workshop projects.", bundle: .appLanguage, comment: "Wallpaper Engine fallback warning body.")
            case .scene:
                return String(localized: "This scene requires rendering features that Loomscreen does not support. Other wallpapers continue playing.", defaultValue: "This scene requires rendering features that Loomscreen does not support. Other wallpapers continue playing.", bundle: .appLanguage, comment: "Scene fallback warning body.")
            default:
                return String(localized: "We couldn't recognize this project type.", defaultValue: "We couldn't recognize this project type.", bundle: .appLanguage, comment: "Project fallback warning body.")
            }
        case .sceneParseFailed:
            return String(localized: "The project file is damaged or incomplete. Re-download the wallpaper in Steam.", defaultValue: "The project file is damaged or incomplete. Re-download the wallpaper in Steam.", bundle: .appLanguage, comment: "Wallpaper Engine fallback warning body.")
        case .sceneLoadFailed:
            return String(localized: "Re-downloading the wallpaper in Steam can help. If it doesn't, this scene isn't supported yet.", defaultValue: "Re-downloading the wallpaper in Steam can help. If it doesn't, this scene isn't supported yet.", bundle: .appLanguage, comment: "Wallpaper Engine fallback warning body.")
        case .sceneShaderUnsupported:
            return Self.unsupportedType.localizedMessage(originalType: .scene, engineAssetsAuthorized: engineAssetsAuthorized)
        case .sceneResourceMissing:
            if engineAssetsAuthorized {
                return String(localized: "Image layers couldn't be found in this project or in your Wallpaper Engine assets.", defaultValue: "Image layers couldn't be found in this project or in your Wallpaper Engine assets.", bundle: .appLanguage, comment: "Scene resource failure body when shared assets are already linked.")
            }
            return String(localized: "Image layers couldn't be found in this project. Wallpaper Engine's shared assets normally supply them.", defaultValue: "Image layers couldn't be found in this project. Wallpaper Engine's shared assets normally supply them.", bundle: .appLanguage, comment: "Scene resource failure body when shared assets are not linked.")
        case let .missingDependency(ids):
            if ids.count <= 2 {
                return String(localized: "Subscribe to \(ids.joined(separator: ", ")) in Steam, then re-import.", bundle: .appLanguage, comment: "Scene dependency recovery hint. The placeholder is one or two Workshop IDs.")
            }
            let head = ids.prefix(2).joined(separator: ", ")
            return String(localized: "Subscribe to \(head) and \(ids.count - 2) more in Steam, then re-import.", bundle: .appLanguage, comment: "Scene dependency recovery hint. Placeholders are Workshop IDs and the remaining count.")
        case .requiresWindowsPlugin:
            return String(localized: "It relies on a Windows plugin that macOS can't run.", defaultValue: "It relies on a Windows plugin that macOS can't run.", bundle: .appLanguage, comment: "Wallpaper Engine fallback warning body.")
        case .texContainerUnsupported, .texUnsupportedFormat:
            return String(localized: "This project isn't supported yet.", defaultValue: "This project isn't supported yet.", bundle: .appLanguage, comment: "Wallpaper Engine fallback warning body.")
        case .texDecodeFailed:
            return String(localized: "Re-downloading the wallpaper in Steam usually fixes this.", defaultValue: "Re-downloading the wallpaper in Steam usually fixes this.", bundle: .appLanguage, comment: "Wallpaper Engine fallback warning body.")
        }
    }
}

#endif
