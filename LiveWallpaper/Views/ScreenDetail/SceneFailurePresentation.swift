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
    let recovery: [WallpaperFailureRecovery]
}

extension FallbackReason {
    var failureClass: WallpaperFailureClass {
        switch self {
        case .unsupportedType, .sceneShaderUnsupported, .requiresWindowsPlugin, .texContainerUnsupported:
            .fatal
        case .sceneParseFailed, .texDecodeFailed:
            .blocked
        case .missingDependency, .sceneResourceMissing:
            .needsParts
        case .texUnsupportedFormat:
            .degraded
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
        case .missingDependency: "puzzlepiece.extension.fill"
        case .sceneResourceMissing: "folder.badge.questionmark"
        case .texUnsupportedFormat, .texDecodeFailed: "photo.badge.exclamationmark"
        }
    }

    var code: String {
        switch self {
        case .unsupportedType: "WPE_UNSUPPORTED_TYPE"
        case .sceneParseFailed: "WPE_SCENE_PARSE"
        case .sceneShaderUnsupported: "WPE_SHADER_UNSUPPORTED"
        case .sceneResourceMissing: "WPE_RESOURCE_MISS"
        case .missingDependency: "WPE_MISSING_DEPENDENCY"
        case .requiresWindowsPlugin: "WPE_WINDOWS_PLUGIN"
        case .texContainerUnsupported: "WPE_TEX_CONTAINER"
        case .texUnsupportedFormat: "WPE_TEX_FORMAT"
        case .texDecodeFailed: "WPE_TEX_DECODE"
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
        case .sceneParseFailed, .texDecodeFailed:
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
            return String(localized: "Couldn't read scene.json", defaultValue: "Couldn't read scene.json", bundle: .appLanguage, comment: "Wallpaper Engine fallback warning title.")
        case .sceneShaderUnsupported:
            return String(localized: "Scene uses unsupported shaders", defaultValue: "Scene uses unsupported shaders", bundle: .appLanguage, comment: "Wallpaper Engine fallback warning title.")
        case .sceneResourceMissing:
            return String(localized: "Some scene assets are missing", defaultValue: "Some scene assets are missing", bundle: .appLanguage, comment: "Wallpaper Engine fallback warning title.")
        case let .missingDependency(ids):
            if ids.count == 1 {
                return String(localized: "Missing 1 Workshop dependency", defaultValue: "Missing 1 Workshop dependency", bundle: .appLanguage, comment: "Wallpaper Engine fallback warning title.")
            }
            return String(localized: "Missing \(ids.count) Workshop dependencies", bundle: .appLanguage, comment: "Wallpaper Engine fallback warning title. The placeholder is the missing dependency count.")
        case .requiresWindowsPlugin:
            return String(localized: "Windows plugin required", defaultValue: "Windows plugin required", bundle: .appLanguage, comment: "Wallpaper Engine fallback warning title.")
        case .texContainerUnsupported:
            return String(localized: "Unsupported texture container", defaultValue: "Unsupported texture container", bundle: .appLanguage, comment: "Wallpaper Engine fallback warning title.")
        case .texUnsupportedFormat:
            // Not "failed": the renderer skipped one layer and kept going.
            return String(localized: "Some layers were skipped", defaultValue: "Some layers were skipped", bundle: .appLanguage, comment: "Title for a partial-degradation notice: one texture layer was skipped and the wallpaper is still playing.")
        case .texDecodeFailed:
            return String(localized: "Couldn't read texture file", defaultValue: "Couldn't read texture file", bundle: .appLanguage, comment: "Wallpaper Engine fallback warning title.")
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
        case let .sceneParseFailed(detail):
            return String(localized: "The author's scene.json couldn't be parsed: \(LogPrivacyRedactor.scrub(detail))", bundle: .appLanguage, comment: "Wallpaper Engine fallback warning body. The placeholder is parser detail.")
        case .sceneShaderUnsupported:
            return String(localized: "This scene uses a custom shader the renderer couldn't translate to Metal. Try re-downloading the project in Steam.", defaultValue: "This scene uses a custom shader the renderer couldn't translate to Metal. Try re-downloading the project in Steam.", bundle: .appLanguage, comment: "Wallpaper Engine fallback warning body.")
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
            return String(localized: "This wallpaper bundles a Windows `.dll` plugin (e.g. an audio visualizer or screensaver runtime). macOS can't load Windows native code, so the project is permanently unsupported here.", defaultValue: "This wallpaper bundles a Windows `.dll` plugin (e.g. an audio visualizer or screensaver runtime). macOS can't load Windows native code, so the project is permanently unsupported here.", bundle: .appLanguage, comment: "Wallpaper Engine fallback warning body.")
        case let .texContainerUnsupported(magic):
            return String(localized: "This wallpaper uses an unsupported `.tex` container (\(magic)).", bundle: .appLanguage, comment: "Wallpaper Engine fallback warning body. The placeholder is a texture container magic value.")
        case let .texUnsupportedFormat(code):
            switch code {
            case 8:
                return String(localized: "Texture format 8 (RGBA1010102) is unsupported. The renderer skips this layer and continues rendering the rest of the scene.", defaultValue: "Texture format 8 (RGBA1010102) is unsupported. The renderer skips this layer and continues rendering the rest of the scene.", bundle: .appLanguage, comment: "Texture fallback warning body.")
            case -1:
                return String(localized: "This format requires Metal-backed GPU decoding that this Mac doesn't support. Try rendering on a newer GPU.", defaultValue: "This format requires Metal-backed GPU decoding that this Mac doesn't support. Try rendering on a newer GPU.", bundle: .appLanguage, comment: "Wallpaper Engine fallback warning body.")
            default:
                return String(localized: "Texture format \(code) is unsupported. The renderer skips this layer and continues rendering the rest of the scene.", bundle: .appLanguage, comment: "Texture fallback warning body. The placeholder is a texture format code.")
            }
        case let .texDecodeFailed(detail):
            return String(localized: "A texture failed to decode (\(LogPrivacyRedactor.scrub(detail))). Re-downloading the wallpaper in Steam usually fixes it.", bundle: .appLanguage, comment: "Wallpaper Engine fallback warning body. The placeholder is decode detail.")
        }
    }
}

#endif
