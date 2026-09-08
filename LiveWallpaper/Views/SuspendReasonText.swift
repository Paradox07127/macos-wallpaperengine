import Foundation
import LiveWallpaperCore

/// User-visible suspension reasons; system limits take precedence over configurable policies.
enum SuspendReasonText {
    /// A configurable reason must not hide a higher-priority system limit.
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

    /// Keeps literal keys visible to extraction and localization coverage checks.
    private static func copy(for reason: WallpaperSuspendReason) -> String {
        switch reason {
        case .thermal, .memoryPressure:
            String(
                localized: "Paused for system resource limits",
                bundle: .appLanguage
            )
        case .applicationRule:
            String(localized: "Paused by an application rule", bundle: .appLanguage)
        case .battery:
            String(localized: "Paused on battery", bundle: .appLanguage)
        case .lowPowerMode:
            String(localized: "Paused in Low Power Mode", bundle: .appLanguage)
        case .fullScreen, .windowOcclusion:
            String(localized: "Paused while covered", bundle: .appLanguage)
        case .userAbsent:
            // Excluded from user-visible reasons by localized(for:).
            String(localized: "Paused by system", bundle: .appLanguage)
        }
    }
}
