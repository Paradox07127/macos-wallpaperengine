import Foundation
import LiveWallpaperCore

enum SuspendReasonText {
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
        case .fullScreen:
            String(localized: "Paused for a full-screen app", bundle: .appLanguage)
        case .windowOcclusion:
            String(localized: "Paused while covered", bundle: .appLanguage)
        case .userAbsent:
            // Excluded from user-visible reasons by localized(for:).
            String(localized: "Paused by system", bundle: .appLanguage)
        }
    }
}
