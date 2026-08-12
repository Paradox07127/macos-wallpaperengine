import SwiftUI

/// Unified destructive-action confirmation following macOS 26 Tahoe HIG:
/// destructive button on top, Cancel on bottom keeping default focus; subtitle
/// carries action target + side-effect + recovery path. Attach with
/// `.confirmDestructive($action)`.
public enum DestructiveAction: Identifiable, Equatable {
    case removePlaylistItem(isLast: Bool, displayName: String)
    case removeSceneHistory(sceneName: String)
    case deleteBookmark(bookmarkName: String)
    case removeScheduleSlot(slotLabel: String)
    case disableSchedule(slotCount: Int)
    case clearAllStorageCaches(byteSize: String)
    case clearSceneVideoCache(byteSize: String)
    case applyConfigurationToAllDisplays(otherCount: Int)
    case clearCurrentWallpaper(displayName: String)
    case resetDisplaySettings(displayName: String)
    case disconnectAerialsLibrary
    #if DEBUG
    /// Storage tab's debug-only cleanup of test-run scratch dirs. Gated so a
    /// shipping build carries neither the case nor its strings.
    case clearTestTempArtifacts(itemCount: Int, formattedSize: String)
    #endif

    public var id: String {
        switch self {
        case .removePlaylistItem(let isLast, let name): return "removePlaylistItem-\(isLast)-\(name)"
        case .removeSceneHistory(let s): return "removeSceneHistory-\(s)"
        case .deleteBookmark(let n): return "deleteBookmark-\(n)"
        case .removeScheduleSlot(let l): return "removeScheduleSlot-\(l)"
        case .disableSchedule(let c): return "disableSchedule-\(c)"
        case .clearAllStorageCaches(let b): return "clearAllStorageCaches-\(b)"
        case .clearSceneVideoCache(let b): return "clearSceneVideoCache-\(b)"
        case .applyConfigurationToAllDisplays(let c): return "applyConfigurationToAllDisplays-\(c)"
        case .clearCurrentWallpaper(let n): return "clearCurrentWallpaper-\(n)"
        case .resetDisplaySettings(let n): return "resetDisplaySettings-\(n)"
        case .disconnectAerialsLibrary: return "disconnectAerialsLibrary"
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
        case .removeScheduleSlot:        return "Remove this schedule slot?"
        case .disableSchedule:           return "Disable schedule?"
        case .clearAllStorageCaches:      return "Clear all storage caches?"
        case .clearSceneVideoCache:       return "Clear scene video texture cache?"
        case .applyConfigurationToAllDisplays: return "Apply this wallpaper to every other display?"
        case .clearCurrentWallpaper:     return "Clear current wallpaper?"
        case .resetDisplaySettings:      return "Reset this display's settings?"
        case .disconnectAerialsLibrary:  return "Disconnect Apple Aerials library?"
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
                    comment: "Destructive confirm message. Placeholder is the display name."
                )
                : String(
                    localized: "The item will be removed from the playlist. Other displays using this video keep their copy.",
                    comment: "Destructive confirm message for removing a non-last playlist item."
                )
        case .removeSceneHistory(let sceneName):
            return String(
                localized: "\(sceneName) won't appear in your recent history anymore. The local cache is kept.",
                comment: "Destructive confirm message. Placeholder is the scene name."
            )
        case .deleteBookmark(let name):
            return String(
                localized: "'\(name)' will be removed from your library. Displays using this bookmark fall back to their saved wallpaper.",
                comment: "Destructive confirm message. Placeholder is the bookmark name."
            )
        case .removeScheduleSlot(let slotLabel):
            return String(
                localized: "The \(slotLabel) slot will be removed. Wallpapers outside this window keep their schedules.",
                comment: "Destructive confirm message. Placeholder is the schedule slot label."
            )
        case .disableSchedule(let count):
            return String(
                localized: "All \(count) time-based wallpaper rules will be cleared. The current wallpaper stays applied.",
                comment: "Destructive confirm message. Placeholder is the number of schedule rules."
            )
        case .clearAllStorageCaches(let byteSize):
            return String(
                localized: "Removes \(byteSize) of reclaimable cache files. Active wallpapers keep their source assignments and rebuild cached files when needed.",
                comment: "Destructive confirm message. Placeholder is a formatted byte size."
            )
        case .clearSceneVideoCache(let byteSize):
            return String(
                localized: "Deletes \(byteSize) of extracted scene video files. Scenes re-extract the video textures the next time they render.",
                comment: "Destructive confirm message. Placeholder is a formatted byte size."
            )
        case .applyConfigurationToAllDisplays(let count):
            return String(
                localized: "This replaces the wallpaper on \(count) other displays with the same content and settings as this one.",
                comment: "Destructive confirm message. Placeholder is the number of other displays."
            )
        case .clearCurrentWallpaper(let displayName):
            return String(
                localized: "Only removes the current wallpaper from \(displayName). Source files, bookmarks, and library items are not deleted.",
                comment: "Destructive confirm message. Placeholder is the display name."
            )
        case .resetDisplaySettings(let displayName):
            return String(
                localized: "Restores playback, color, particle, audio, and layout settings on \(displayName) to defaults. The wallpaper itself, playlist bookmarks, and library items stay.",
                comment: "Destructive confirm message. Placeholder is the display name."
            )
        case .disconnectAerialsLibrary:
            return String(
                localized: "LiveWallpaper will release its read access to the local Apple Aerials folder. Existing aerial wallpapers stay applied; you'll need to reconnect to browse the library again.",
                comment: "Destructive confirm message for disconnecting the Aerials library."
            )
        #if DEBUG
        case .clearTestTempArtifacts(let itemCount, let formattedSize):
            return String(
                localized: "Deletes \(itemCount) scratch items · \(formattedSize) created by test runs in the container's tmp folder. Nothing else reads them.",
                comment: "DEBUG destructive confirm. Placeholders are item count and formatted size."
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
        case .removeScheduleSlot:        return "Remove Slot"
        case .disableSchedule:           return "Disable Schedule"
        case .clearAllStorageCaches:      return "Clear All Caches"
        case .clearSceneVideoCache:       return "Clear Video Cache"
        case .applyConfigurationToAllDisplays: return "Apply to All Displays"
        case .clearCurrentWallpaper:     return "Clear Wallpaper"
        case .resetDisplaySettings:      return "Reset Settings"
        case .disconnectAerialsLibrary:  return "Disconnect"
        #if DEBUG
        case .clearTestTempArtifacts(let itemCount, _): return "Delete \(itemCount) Items"
        #endif
        }
    }
}

public struct PendingDestructive: Identifiable {
    public let id = UUID()
    public let action: DestructiveAction
    public let perform: () -> Void

    public init(_ action: DestructiveAction, perform: @escaping () -> Void) {
        self.action = action
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
            Button(current.action.destructiveButtonTitle, role: .destructive) {
                let captured = current.perform
                pending = nil
                captured()
            }
            Button("Cancel", role: .cancel) {
                pending = nil
            }
        } message: { current in
            Text(current.action.message)
        }
    }
}
