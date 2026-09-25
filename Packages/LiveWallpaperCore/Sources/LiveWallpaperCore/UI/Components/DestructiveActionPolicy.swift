import SwiftUI

/// Attach with `.confirmDestructive($action)`.
public enum DestructiveAction: Identifiable, Equatable {
    case removePlaylistItem(isLast: Bool, displayName: String)
    case removeSceneHistory(sceneName: String)
    case deleteBookmark(bookmarkName: String)
    case deleteScheme(schemeName: String)
    case applyScheme(schemeName: String, displayName: String)
    case replaceScheme(schemeName: String, displayName: String)
    case removeScheduleSlot(slotLabel: String)
    case disableSchedule(slotCount: Int)
    case clearAllStorageCaches(byteSize: String)
    case clearSceneVideoCache(byteSize: String)
    case applyConfigurationToAllDisplays(otherCount: Int)
    case applyOverlayToAllDisplays(overlayName: String, otherCount: Int)
    case clearCurrentWallpaper(displayName: String)
    /// `sceneCapable` = the build renders scenes; false (Lite) omits scene settings from the copy.
    case resetDisplaySettings(displayName: String, sceneCapable: Bool)
    /// `sceneCapable` = the build renders scenes; false (Lite) omits presets and Wallpaper Engine assets.
    case resetAllSettings(sceneCapable: Bool)
    case removeSystemWallpaper(title: String, isInUse: Bool)
    case clearSystemWallpaperLibrary(itemCount: Int, formattedSize: String)
    case disconnectAerialsLibrary
    case forgetSteamWebAPIKey
    case removeManagedSteamCMD
    #if DEBUG
    case clearTestTempArtifacts(itemCount: Int, formattedSize: String)
    #endif

    public var id: String {
        switch self {
        case .removePlaylistItem(let isLast, let name): return "removePlaylistItem-\(isLast)-\(name)"
        case .removeSceneHistory(let s): return "removeSceneHistory-\(s)"
        case .removeSystemWallpaper(let t, let u): return "removeSystemWallpaper-\(t)-\(u)"
        case .deleteBookmark(let n): return "deleteBookmark-\(n)"
        case let .deleteScheme(n): return "deleteScheme-\(n)"
        case let .applyScheme(n, d): return "applyScheme-\(n)-\(d)"
        case let .replaceScheme(n, d): return "replaceScheme-\(n)-\(d)"
        case .removeScheduleSlot(let l): return "removeScheduleSlot-\(l)"
        case .disableSchedule(let c): return "disableSchedule-\(c)"
        case .clearAllStorageCaches(let b): return "clearAllStorageCaches-\(b)"
        case .clearSystemWallpaperLibrary(let n, let b): return "clearSystemWallpaperLibrary-\(n)-\(b)"
        case .clearSceneVideoCache(let b): return "clearSceneVideoCache-\(b)"
        case .applyConfigurationToAllDisplays(let c): return "applyConfigurationToAllDisplays-\(c)"
        case .applyOverlayToAllDisplays(let n, let c): return "applyOverlayToAllDisplays-\(n)-\(c)"
        case .clearCurrentWallpaper(let n): return "clearCurrentWallpaper-\(n)"
        case let .resetDisplaySettings(n, _): return "resetDisplaySettings-\(n)"
        case .resetAllSettings: return "resetAllSettings"
        case .disconnectAerialsLibrary: return "disconnectAerialsLibrary"
        case .forgetSteamWebAPIKey: return "forgetSteamWebAPIKey"
        case .removeManagedSteamCMD: return "removeManagedSteamCMD"
        #if DEBUG
        case .clearTestTempArtifacts(let i, let b): return "clearTestTempArtifacts-\(i)-\(b)"
        #endif
        }
    }

    public var title: LocalizedStringKey {
        switch self {
        case .removePlaylistItem(let isLast, _):
            return isLast ? "Remove the last playlist item?" : "Remove this playlist item?"
        case .removeSceneHistory:        return "Remove this scene from history?"
        case .deleteBookmark:            return "Delete this bookmark?"
        case .deleteScheme: return "Delete this scheme?"
        case .applyScheme: return "Replace this display's entire setup?"
        case .replaceScheme: return "Overwrite this saved scheme?"
        case .removeScheduleSlot:        return "Remove this schedule slot?"
        case .disableSchedule:           return "Disable schedule?"
        case .clearAllStorageCaches:      return "Clear all storage caches?"
        case .clearSystemWallpaperLibrary: return "Remove every System Wallpaper?"
        case .clearSceneVideoCache:       return "Clear scene video texture cache?"
        case .applyConfigurationToAllDisplays: return "Apply this wallpaper to every other display?"
        case .applyOverlayToAllDisplays: return "Apply this overlay to every other display?"
        case .clearCurrentWallpaper:     return "Clear current wallpaper?"
        case .resetDisplaySettings:      return "Reset this display's settings?"
        case .resetAllSettings: return "Reset all settings?"
        case .removeSystemWallpaper:     return "Remove this video from System Wallpaper?"
        case .disconnectAerialsLibrary:  return "Disconnect Apple Aerials library?"
        case .forgetSteamWebAPIKey: return "Forget the Steam Web API key?"
        case .removeManagedSteamCMD: return "Remove the SteamCMD copy Loomscreen installed?"
        #if DEBUG
        case .clearTestTempArtifacts:    return "Delete leftover test artifacts?"
        #endif
        }
    }

    public var message: String {
        switch self {
        case .removePlaylistItem(let isLast, let displayName):
            return isLast
                ? String(
                    localized: "This is the only wallpaper in the playlist. Removing it will clear the wallpaper on \(displayName).",
                    bundle: .appLanguage, comment: "Destructive confirm message. Placeholder is the display name."
                )
                : String(
                    localized: "The item will be removed from the playlist. Other displays using this video keep their copy.",
                    bundle: .appLanguage, comment: "Destructive confirm message for removing a non-last playlist item."
                )
        case .removeSystemWallpaper(let title, let isInUse):
            return isInUse
                ? String(
                    localized: "“\(title)” is on screen right now. It stops playing and its file is deleted immediately; the desktop keeps the last frame until you pick another wallpaper in System Settings.",
                    bundle: .appLanguage, comment: "Destructive confirm message for removing the system wallpaper that is currently displayed. Placeholder is the video title."
                )
                : String(
                    localized: "“\(title)” and its copy in Loomscreen's shared folder are deleted. Your original video is untouched.",
                    bundle: .appLanguage, comment: "Destructive confirm message for removing a published system wallpaper. Placeholder is the video title."
                )
        case .removeSceneHistory(let sceneName):
            return String(
                localized: "\(sceneName) won't appear in your recent history anymore. The local cache is kept.",
                bundle: .appLanguage, comment: "Destructive confirm message. Placeholder is the scene name."
            )
        case .deleteBookmark(let name):
            return String(
                localized: "'\(name)' will be removed from your library. Displays using this bookmark fall back to their saved wallpaper.",
                bundle: .appLanguage, comment: "Destructive confirm message. Placeholder is the bookmark name."
            )
        case let .deleteScheme(name):
            return String(
                localized: "'\(name)' will be removed from your saved schemes. Displays it was applied to keep what is on screen.",
                bundle: .appLanguage, comment: "Destructive confirm message. Placeholder is the scheme name."
            )
        case let .applyScheme(schemeName, displayName):
            return String(
                localized: "'\(schemeName)' replaces the wallpaper, overlay layout, and every setting on \(displayName). Save that display's current setup as a scheme first if you want it back.",
                bundle: .appLanguage, comment: "Confirm message for applying a saved scheme. Placeholders are the scheme name and the target display name."
            )
        case let .replaceScheme(schemeName, displayName):
            return String(
                localized: "'\(schemeName)' is overwritten with what \(displayName) is showing now. The setup saved under that name cannot be recovered.",
                bundle: .appLanguage, comment: "Confirm message for overwriting a saved scheme with a display's current setup. Placeholders are the scheme name and the source display name."
            )
        case .removeScheduleSlot(let slotLabel):
            return String(
                localized: "The \(slotLabel) slot will be removed. Wallpapers outside this window keep their schedules.",
                bundle: .appLanguage, comment: "Destructive confirm message. Placeholder is the schedule slot label."
            )
        case .disableSchedule(let count):
            return String(
                localized: "All \(count) time-based wallpaper rules will be cleared. The current wallpaper stays applied.",
                bundle: .appLanguage, locale: AppLanguagePreference.current.locale, comment: "Destructive confirm message. Placeholder is the number of schedule rules."
            )
        case .clearSystemWallpaperLibrary(let itemCount, let formattedSize):
            return String(
                localized: "\(itemCount) video(s) and \(formattedSize) are deleted from the folder macOS reads. Your originals in Loomscreen are untouched.",
                bundle: .appLanguage, comment: "Destructive confirm message for clearing the whole system wallpaper library. Placeholders are the item count and the formatted size on disk."
            )
        case .clearAllStorageCaches(let byteSize):
            return String(
                localized: "Removes \(byteSize) of reclaimable cache files. Active wallpapers keep their source assignments and rebuild cached files when needed.",
                bundle: .appLanguage, comment: "Destructive confirm message. Placeholder is a formatted byte size."
            )
        case .clearSceneVideoCache(let byteSize):
            return String(
                localized: "Deletes \(byteSize) of extracted scene video files. Scenes re-extract the video textures the next time they render.",
                bundle: .appLanguage, comment: "Destructive confirm message. Placeholder is a formatted byte size."
            )
        case .applyConfigurationToAllDisplays(let count):
            return String(
                localized: "The wallpaper, playlist, schedule, effect layer, and all other settings on \(count) other displays are replaced with this display's. Their widget, music, and clock overlays are not changed.",
                bundle: .appLanguage, locale: AppLanguagePreference.current.locale, comment: "Destructive confirm message. Placeholder is the number of other displays."
            )
        case .applyOverlayToAllDisplays(let overlayName, let count):
            return String(
                localized: "This replaces the \(overlayName) overlay on \(count) other displays. Their wallpapers are left alone.",
                bundle: .appLanguage, locale: AppLanguagePreference.current.locale, comment: "Destructive confirm message. Placeholders are the overlay's name and the number of other displays."
            )
        case .clearCurrentWallpaper(let displayName):
            return String(
                localized: "Removes everything saved for \(displayName): the wallpaper, playlist, schedule, effect layer, and all other settings for this display. The wallpaper library, source files, and the widget, music, and clock overlays are kept.",
                bundle: .appLanguage, comment: "Destructive confirm message. Placeholder is the display name."
            )
        case let .resetDisplaySettings(displayName, sceneCapable):
            return sceneCapable
                ? String(
                    localized: "On \(displayName), this:\n• Resets playback settings, web wallpaper settings, and blur, brightness, saturation, warmth, vignette, and auto warm tint\n• Turns off the effect layer and returns its Density, Match local weather, Match density to weather, and Follow wind direction to their defaults\n• Turns off On Lock, shuffle, and rotation\n• Clears the schedule and switches back to the playlist\nThe wallpaper, playlist items, and scene custom settings are kept.",
                    bundle: .appLanguage, comment: "Destructive confirm message. Placeholder is the display name. Capitalized names are control labels."
                )
                : String(
                    localized: "On \(displayName), this:\n• Resets playback settings, web wallpaper settings, and blur, brightness, saturation, warmth, vignette, and auto warm tint\n• Turns off the effect layer and returns its Density, Match local weather, Match density to weather, and Follow wind direction to their defaults\n• Turns off On Lock, shuffle, and rotation\n• Clears the schedule and switches back to the playlist\nThe wallpaper and playlist items are kept.",
                    bundle: .appLanguage, comment: "Destructive confirm message in a build without scenes. Placeholder is the display name. Capitalized names are control labels."
                )
        case let .resetAllSettings(sceneCapable):
            return sceneCapable
                ? String(
                    localized: "This clears:\n• Every display's wallpaper, playlist, schedule, scene custom settings, overlays, and custom name\n• The wallpaper library, presets, and schemes\n• All preferences, shortcuts, and display defaults\n• Trusted origins, and folder access for Apple Aerials, Wallpaper Engine assets, and AI session history\nWallpaper files on disk are not deleted.",
                    bundle: .appLanguage, comment: "Destructive confirm message for resetting every app setting from Settings › Advanced."
                )
                : String(
                    localized: "This clears:\n• Every display's wallpaper, playlist, schedule, overlays, and custom name\n• The wallpaper library and schemes\n• All preferences, shortcuts, and display defaults\n• Trusted origins, and folder access for Apple Aerials and AI session history\nWallpaper files on disk are not deleted.",
                    bundle: .appLanguage, comment: "Destructive confirm message for resetting every app setting from Settings › Advanced, in a build without scenes."
                )
        case .disconnectAerialsLibrary:
            return String(
                localized: "LiveWallpaper will release its read access to the local Apple Aerials folder. Existing aerial wallpapers stay applied; you'll need to reconnect to browse the library again.",
                bundle: .appLanguage, comment: "Destructive confirm message for disconnecting the Aerials library."
            )
        case .forgetSteamWebAPIKey:
            return String(
                localized: "The key is removed from this Mac. Ratings, authors, and faster search are unavailable until you enter a key again. The key stays active in your Steam account until you revoke it at steamcommunity.com/dev/apikey.",
                bundle: .appLanguage, comment: "Destructive confirm message for forgetting the stored Steam Web API key."
            )
        case .removeManagedSteamCMD:
            return String(
                localized: "This copy is deleted from your Mac. If Loomscreen is using it, it switches to another SteamCMD found on this Mac; if none is found, set up SteamCMD again before downloading from the Workshop. Your Steam sign-in and downloaded wallpapers are kept.",
                bundle: .appLanguage, comment: "Destructive confirm message for removing the SteamCMD copy that Loomscreen installed."
            )
        #if DEBUG
        case .clearTestTempArtifacts(let itemCount, let formattedSize):
            return String(
                localized: "Deletes \(itemCount) scratch items · \(formattedSize) created by test runs in the container's tmp folder. Nothing else reads them.",
                bundle: .appLanguage, locale: AppLanguagePreference.current.locale, comment: "DEBUG destructive confirm. Placeholders are item count and formatted size."
            )
        #endif
        }
    }

    public var destructiveButtonTitle: LocalizedStringKey {
        switch self {
        case .removePlaylistItem(let isLast, _):
            return isLast ? "Remove & Clear" : "Remove"
        case .removeSceneHistory:        return "Remove"
        case .deleteBookmark:            return "Delete"
        case .deleteScheme: return "Delete"
        case .applyScheme: return "Replace Setup"
        case .replaceScheme: return "Overwrite Scheme"
        case .removeScheduleSlot:        return "Remove Slot"
        case .disableSchedule:           return "Disable Schedule"
        case .clearAllStorageCaches:      return "Clear All Caches"
        case .clearSystemWallpaperLibrary: return "Remove All"
        case .clearSceneVideoCache:       return "Clear Video Cache"
        case .applyConfigurationToAllDisplays: return "Apply to All Displays"
        case .applyOverlayToAllDisplays: return "Apply to All Displays"
        case .clearCurrentWallpaper:     return "Clear Wallpaper"
        case .resetDisplaySettings:      return "Reset Settings"
        case .resetAllSettings: return "Reset All Settings"
        case .removeSystemWallpaper:     return "Remove"
        case .disconnectAerialsLibrary:  return "Disconnect"
        case .forgetSteamWebAPIKey: return "Forget Key"
        case .removeManagedSteamCMD: return "Remove SteamCMD"
        #if DEBUG
        case .clearTestTempArtifacts(let itemCount, _): return "Delete \(itemCount) Items"
        #endif
        }
    }

    /// nil = the confirmation offers no alternative to the destructive button.
    public var alternativeButtonTitle: LocalizedStringKey? {
        switch self {
        case .resetAllSettings: "Export Configuration First"
        default: nil
        }
    }
}

public struct PendingDestructive: Identifiable {
    public let id = UUID()
    public let action: DestructiveAction
    public let perform: () -> Void
    /// Runs from `action.alternativeButtonTitle` instead of `perform`; nil hides that button.
    public let alternative: (() -> Void)?

    public init(_ action: DestructiveAction, alternative: (() -> Void)? = nil, perform: @escaping () -> Void) {
        self.action = action
        self.alternative = alternative
        self.perform = perform
    }
}

extension View {
    public func confirmDestructive(_ pending: Binding<PendingDestructive?>) -> some View {
        modifier(DestructiveConfirmationModifier(pending: pending))
    }
}

private struct DestructiveConfirmationModifier: ViewModifier {
    @Binding var pending: PendingDestructive?

    func body(content: Content) -> some View {
        content.alert(
            pending?.action.title ?? "",
            isPresented: Binding(
                get: { pending != nil },
                set: { if !$0 { pending = nil } }
            ),
            presenting: pending
        ) { current in
            // No `role: .destructive`: HIG says an alert confirming a deliberately-chosen
            // destructive action does not apply the destructive style.
            Button(current.action.destructiveButtonTitle) {
                let captured = current.perform
                pending = nil
                captured()
            }
            if let alternative = current.alternative, let title = current.action.alternativeButtonTitle {
                Button(title) {
                    pending = nil
                    alternative()
                }
            }
            Button("Cancel", role: .cancel) {
                pending = nil
            }
        } message: { current in
            Text(current.action.message)
        }
    }
}
