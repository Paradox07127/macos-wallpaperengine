import SwiftUI

/// Attach with `.confirmDestructive($action)`.
public enum DestructiveAction: Identifiable, Equatable {
    case deleteScheme(schemeName: String)
    case applyScheme(schemeName: String, displayName: String)
    case replaceScheme(schemeName: String, displayName: String)
    case replaceLocalCopy(title: String)
    case clearAllStorageCaches(byteSize: String)
    case applyConfigurationToAllDisplays(otherCount: Int)
    case clearCurrentWallpaper(displayName: String)
    /// `sceneCapable` = the build renders scenes; false (Lite) omits scene settings from the copy.
    case resetDisplaySettings(displayName: String, sceneCapable: Bool)
    /// `sceneCapable` = the build renders scenes; false (Lite) omits presets and Wallpaper Engine assets.
    case resetAllSettings(sceneCapable: Bool)
    case removeSystemWallpaper(title: String, isInUse: Bool)
    case clearSystemWallpaperLibrary(itemCount: Int, formattedSize: String)
    /// `playingTitles` = legacy copies a display shows right now; they stop when deleted. `tileName` = the provider's tile name in System Settings.
    case clearLegacySystemWallpapers(itemCount: Int, formattedSize: String, playingTitles: [String], tileName: String)
    case disconnectAerialsLibrary
    case forgetSteamWebAPIKey
    case removeManagedSteamCMD
    #if DEBUG
    case clearTestTempArtifacts(itemCount: Int, formattedSize: String)
    #endif

    public var id: String {
        switch self {
        case .removeSystemWallpaper(let t, let u): return "removeSystemWallpaper-\(t)-\(u)"
        case let .deleteScheme(n): return "deleteScheme-\(n)"
        case let .applyScheme(n, d): return "applyScheme-\(n)-\(d)"
        case let .replaceScheme(n, d): return "replaceScheme-\(n)-\(d)"
        case let .replaceLocalCopy(t): return "replaceLocalCopy-\(t)"
        case .clearAllStorageCaches(let b): return "clearAllStorageCaches-\(b)"
        case .clearSystemWallpaperLibrary(let n, let b): return "clearSystemWallpaperLibrary-\(n)-\(b)"
        case let .clearLegacySystemWallpapers(n, b, p, _): return "clearLegacySystemWallpapers-\(n)-\(b)-\(p.joined(separator: "|"))"
        case .applyConfigurationToAllDisplays(let c): return "applyConfigurationToAllDisplays-\(c)"
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
        case .deleteScheme: return "Delete this scheme?"
        case .applyScheme: return "Replace this display's entire setup?"
        case .replaceScheme: return "Overwrite this saved scheme?"
        case .replaceLocalCopy: return "Replace the copy in your library?"
        case .clearAllStorageCaches:      return "Clear all storage caches?"
        case .clearSystemWallpaperLibrary: return "Remove every System Wallpaper?"
        case .clearLegacySystemWallpapers: return "Remove old copies?"
        case .applyConfigurationToAllDisplays: return "Apply this wallpaper to every other display?"
        case .clearCurrentWallpaper:     return "Clear current wallpaper?"
        case .resetDisplaySettings:      return "Reset this display's settings?"
        case .resetAllSettings: return "Reset all settings?"
        case .removeSystemWallpaper: return "Remove this wallpaper from System Wallpaper?"
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
        case .removeSystemWallpaper(let title, let isInUse):
            return isInUse
                ? String(
                    localized: "“\(title)” is on screen right now. It stops playing and its file is deleted immediately; the desktop keeps the last frame until you pick another wallpaper in System Settings.",
                    bundle: .appLanguage, comment: "Destructive confirm message for removing the system wallpaper that is currently displayed. Placeholder is the wallpaper title."
                )
                : String(
                    localized: "“\(title)” and its copy in Loomscreen's shared folder are deleted. Your original files are untouched.",
                    bundle: .appLanguage, comment: "Destructive confirm message for removing a published system wallpaper. Placeholder is the wallpaper title."
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
        case let .replaceLocalCopy(title):
            return String(
                localized: "'\(title)' is already in your library from another folder. The Steam download takes its place; that folder stays on disk.",
                bundle: .appLanguage, comment: "Confirm message before a Workshop download replaces a library copy imported from a local folder. Placeholder is the wallpaper title."
            )
        case .clearSystemWallpaperLibrary(let itemCount, let formattedSize):
            return String(
                localized: "\(itemCount) wallpapers and \(formattedSize) are deleted from the folder macOS reads. Your originals in Loomscreen are untouched.",
                bundle: .appLanguage, locale: AppLanguagePreference.current.locale, comment: "Destructive confirm message for clearing the whole system wallpaper library. Placeholders are the item count and the formatted size on disk."
            )
        case let .clearLegacySystemWallpapers(itemCount, formattedSize, playingTitles, tileName):
            let removed = String(
                localized: "\(itemCount) old copies and \(formattedSize) are deleted from the folder macOS reads. Your originals in Loomscreen are untouched.",
                bundle: .appLanguage, locale: AppLanguagePreference.current.locale, comment: "Destructive confirm message for removing system wallpaper copies that Loomscreen no longer follows. Placeholders are the item count and the formatted size on disk."
            )
            guard !playingTitles.isEmpty else { return removed }
            let titles = ListFormatter.localizedString(byJoining: playingTitles.map { "“\($0)”" })
            return removed + "\n\n" + String(
                localized: "On screen now: \(titles). Those displays stop playing until you select “\(tileName)” again in System Settings › Wallpaper.",
                bundle: .appLanguage, comment: "Second paragraph of the old-copies removal confirm. Placeholders are a list of quoted wallpaper titles and the tile name macOS shows, such as Loomscreen — Selected Wallpaper."
            )
        case .clearAllStorageCaches(let byteSize):
            return String(
                localized: "Removes \(byteSize) of reclaimable cache files. Active wallpapers keep their source assignments and rebuild cached files when needed.",
                bundle: .appLanguage, comment: "Destructive confirm message. Placeholder is a formatted byte size."
            )
        case .applyConfigurationToAllDisplays(let count):
            return String(
                localized: "The wallpaper, playlist, schedule, effect layer, and all other settings on \(count) other displays are replaced with this display's. Their widget, music, and clock overlays are not changed.",
                bundle: .appLanguage, locale: AppLanguagePreference.current.locale, comment: "Destructive confirm message. Placeholder is the number of other displays."
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
        case .deleteScheme: return "Delete"
        case .applyScheme: return "Replace Setup"
        case .replaceScheme: return "Overwrite Scheme"
        case .replaceLocalCopy: return "Replace"
        case .clearAllStorageCaches:      return "Clear All Caches"
        case .clearSystemWallpaperLibrary: return "Remove All"
        case .clearLegacySystemWallpapers: return "Remove Old Copies"
        case .applyConfigurationToAllDisplays: return "Apply to All Displays"
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
