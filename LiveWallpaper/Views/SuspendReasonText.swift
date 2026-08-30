import Foundation
import LiveWallpaperCore

/// User-facing wording for why a wallpaper stopped.
/// Grouped by what the user can do about it, not which subsystem raised it: safety reasons
/// have no setting to turn off, so they get a "this lifts on its own" note instead of a cause
/// the user would go hunting for in preferences.
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
        return copy(for: reason)
    }

    // Each case resolves its own literal rather than returning a key for one
    // shared lookup: a key that only exists as a runtime value is invisible to
    // both the string extractor and `LocalizationCoverageTests`.
    private static func copy(for reason: WallpaperSuspendReason) -> String {
        switch reason {
        case .thermal, .memoryPressure:
            String(
                localized: "System resources are tight — playback resumes automatically",
                bundle: .appLanguage
            )
        case .applicationRule:
            String(localized: "Paused by a per-app rule", bundle: .appLanguage)
        case .battery:
            String(localized: "Paused on battery", bundle: .appLanguage)
        case .lowPowerMode:
            String(localized: "Paused in Low Power Mode", bundle: .appLanguage)
        case .fullScreen, .windowOcclusion:
            String(localized: "Paused while covered", bundle: .appLanguage)
        case .userAbsent:
            // Filtered out above: nobody is looking at the screen to read it.
            String(localized: "Paused by system", bundle: .appLanguage)
        }
    }
}
