import Foundation
import LiveWallpaperCore

/// User-facing wording for why a wallpaper stopped.
///
/// Grouped by what the user can do about it rather than by which subsystem
/// raised it: safety reasons have no setting to turn off, so they get a
/// "this lifts on its own" note instead of a cause the user would go hunting
/// for in preferences.
enum SuspendReasonText {
    /// The single reason worth showing when several apply at once.
    /// Safety wins — it is the one the user cannot do anything about, and
    /// telling them to change a setting that would not help is worse than
    /// saying nothing.
    static func primary(from reasons: Set<WallpaperSuspendReason>) -> WallpaperSuspendReason? {
        let order: [WallpaperSuspendReason] = [
            .thermal, .memoryPressure, .userAbsent,
            .applicationRule, .lowPowerMode, .battery, .fullScreen, .windowOcclusion,
        ]
        return order.first(where: reasons.contains)
    }

    static func localized(for reasons: Set<WallpaperSuspendReason>) -> String? {
        guard let reason = primary(from: reasons), reason.isUserVisible else { return nil }
        return AppLanguagePreference.localizedString(key(for: reason))
    }

    private static func key(for reason: WallpaperSuspendReason) -> String {
        switch reason {
        case .thermal, .memoryPressure:
            "System resources are tight — playback resumes automatically"
        case .applicationRule:
            "Paused by a per-app rule"
        case .battery:
            "Paused on battery"
        case .lowPowerMode:
            "Paused in Low Power Mode"
        case .fullScreen, .windowOcclusion:
            "Paused while covered"
        case .userAbsent:
            // Filtered out above: nobody is looking at the screen to read it.
            "Paused by system"
        }
    }
}
