#if !LITE_BUILD
import AppKit
import LiveWallpaperCore
import SwiftUI

/// What the user can still do about a failure, which is what actually decides
/// the colour and the action set — not how alarming the error sounds. Split out
/// because `FallbackCard` and `SceneDetailView` had drifted into two different
/// severity tables for the same `FallbackReason`.
enum SceneFailureClass: Equatable {
    /// Nothing on this Mac can render it, ever. No recovery action exists.
    case fatal
    /// The scene will not run, but there is a way out.
    case blocked
    /// Something is missing; supplying it fixes the scene.
    case needsParts
    /// One layer was skipped — the wallpaper is still playing.
    case degraded
}

/// The recovery affordances a reason earns. Both surfaces read this list, so a
/// reason cannot offer "subscribe in Steam" on one screen and no button on the other.
enum SceneFailureRecovery: Equatable, Hashable {
    case retry
    case copyDependencyIDs([String])
    case openWorkshop(String)
    case configureEngineAssets
}

/// Everything the UI needs to render one failure. Single source of truth.
struct SceneFailurePresentation {
    let failureClass: SceneFailureClass
    let tint: Color
    let symbol: String
    let code: String
    let title: Text
    let message: Text
    let recovery: [SceneFailureRecovery]
}

extension FallbackReason {
    var failureClass: SceneFailureClass {
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
    /// Matches the DESIGN.md gloss: danger = errors, warning = "won't run"
    /// blockers, caution = "needs deps" / pending.
    var tint: Color {
        switch failureClass {
        case .fatal: DesignTokens.Colors.Status.danger
        case .blocked: DesignTokens.Colors.Status.warning
        case .needsParts: DesignTokens.Colors.Status.caution
        case .degraded: DesignTokens.Colors.Status.caution
        }
    }

    /// Paired with a title on every surface (DESIGN.md rule 6 — colour alone
    /// never carries the meaning).
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

    func recovery(workshopID: String) -> [SceneFailureRecovery] {
        let isSteamItem = !workshopID.isEmpty && workshopID.allSatisfy(\.isNumber)
        switch self {
        case let .missingDependency(ids):
            var actions: [SceneFailureRecovery] = [.copyDependencyIDs(ids), .retry]
            if isSteamItem {
                actions.insert(.openWorkshop(workshopID), at: 1)
            }
            return actions
        case .sceneResourceMissing:
            return [.configureEngineAssets, .retry]
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
            recovery: recovery(workshopID: origin.workshopID)
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
            // Not "failed": the renderer skipped one layer and kept going, and a
            // title claiming failure sent readers hunting for a dead wallpaper.
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
            // Names where the files were looked for; the recovery action beside
            // it owns what to do about it.
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

/// Renders a reason's `recovery` list. Kept here so both surfaces emit the same
/// buttons in the same order for the same reason.
struct SceneFailureRecoveryActions: View {
    let recovery: [SceneFailureRecovery]
    let onRetry: (() -> Void)?
    var isCompact = true

    @State private var didCopy = false

    var body: some View {
        ForEach(Array(recovery.enumerated()), id: \.element) { index, action in
            // Only the first action can be prominent (DESIGN.md rule 8).
            control(for: action, isPrimary: index == 0)
        }
    }

    @ViewBuilder
    private func control(for action: SceneFailureRecovery, isPrimary: Bool) -> some View {
        switch action {
        case .retry:
            if let onRetry {
                emphasised(isPrimary) {
                    Button(action: onRetry) {
                        Label("Retry", systemImage: "arrow.clockwise")
                    }
                    .accessibilityHint(Text("Reloads the current scene."))
                }
            }
        case let .copyDependencyIDs(ids):
            emphasised(isPrimary) {
                Button {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(ids.joined(separator: "\n"), forType: .string)
                    didCopy = true
                } label: {
                    // Two literal Labels rather than a ternary inside one: a
                    // ternary's type is inferred, and which Label overload wins
                    // then decides whether the string is localised at all.
                    if didCopy {
                        Label("Copied", systemImage: "checkmark")
                    } else {
                        Label("Copy IDs", systemImage: "doc.on.doc")
                    }
                }
                .task(id: didCopy) {
                    guard didCopy else { return }
                    try? await Task.sleep(for: .seconds(2))
                    didCopy = false
                }
                .accessibilityHint(Text("Copies every missing workshop ID to your clipboard so you can subscribe in Steam"))
            }
        case let .openWorkshop(id):
            // Never prominent: leaving the app is not the recovery, it is a
            // detour on the way to one.
            Button {
                openWorkshop(workshopID: id)
            } label: {
                Label("Workshop", systemImage: "safari")
            }
            .buttonStyle(.bordered)
            .controlSize(isCompact ? .small : .regular)
            .accessibilityHint(Text("Opens this wallpaper's Steam Workshop page in your browser"))
        case .configureEngineAssets:
            emphasised(isPrimary) {
                Button {
                    NotificationCenter.default.post(
                        name: .openSettingsSection,
                        object: nil,
                        userInfo: [
                            "destination": SettingsNavigation.workshopSetup.rawValue,
                            "anchor": SettingsSearchAnchor.workshopAssets.rawValue,
                        ]
                    )
                } label: {
                    Label("Set Up Assets", systemImage: "shippingbox.and.arrow.backward")
                }
                .accessibilityHint(Text("Opens the Workshop settings page to download or link Wallpaper Engine assets"))
            }
        }
    }

    /// `buttonStyle` takes a concrete type, so the prominent/plain choice has to
    /// branch on whole views rather than on the style value.
    @ViewBuilder
    private func emphasised(_ isPrimary: Bool, @ViewBuilder content: () -> some View) -> some View {
        if isPrimary {
            content().buttonStyle(.borderedProminent).controlSize(isCompact ? .small : .regular)
        } else {
            content().buttonStyle(.bordered).controlSize(isCompact ? .small : .regular)
        }
    }

    private func openWorkshop(workshopID: String) {
        var components = URLComponents(string: "https://steamcommunity.com/sharedfiles/filedetails/")
        components?.queryItems = [URLQueryItem(name: "id", value: workshopID)]
        guard let url = components?.url else { return }
        NSWorkspace.shared.open(url)
    }
}
#endif
