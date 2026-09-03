#if !LITE_BUILD
import Foundation
import LiveWallpaperCore

extension WorkshopQueryError {
    /// What went wrong, with no remedy attached.
    ///
    /// Three surfaces map this error and each had grown its own switch: browse
    /// covered every case, key validation covered five and sent the rest to
    /// "Validation failed.", and the presets row named none of them. A cause
    /// belongs to the error, so a new case cannot be worded in one place and
    /// left generic in the other two.
    ///
    /// Remedies stay at the call sites, because they differ: the same rejected
    /// key means "update it in Settings" while browsing and "paste a new one"
    /// inside the key sheet. Every sentence here is deliberately the wording
    /// one of those surfaces already shipped, so the catalog keys — and their
    /// translations — carry over unchanged.
    var causeDescription: String {
        switch self {
        case .missingAPIKey:
            String(
                localized: "No Steam Web API key is set.",
                bundle: .appLanguage, comment: "Workshop failure cause when no Steam Web API key is stored."
            )
        case .keychainUnreadable:
            String(
                localized: "The stored API key couldn't be read. Paste it again.",
                bundle: .appLanguage, comment: "Workshop failure cause when the stored key exists but cannot be read back."
            )
        case .keychainAccessDenied:
            String(
                localized: "macOS wouldn't unlock your saved API key — allow access when it asks, or set the key again in Settings.",
                bundle: .appLanguage, comment: "Workshop browse error when the keychain refused to hand over the stored API key."
            )
        case .unauthorized:
            String(localized: "Steam rejected the key.", bundle: .appLanguage, comment: "Steam Web API key validation error.")
        case .keyDisabled:
            String(
                localized: "Your Steam API key was disabled by Valve.",
                bundle: .appLanguage, comment: "Steam Web API key validation error."
            )
        case .rateLimited:
            String(
                localized: "Steam is rate-limiting. Retry in a moment.",
                bundle: .appLanguage, comment: "Workshop browse error when Steam rate-limits requests."
            )
        case .secureConnectionFailed:
            String(
                localized: "The secure connection to Steam failed. A proxy or security software may be intercepting it.",
                bundle: .appLanguage, comment: "Workshop failure cause when TLS to Steam could not be established."
            )
        case let .networkFailure(code):
            String(
                localized: "The request to Steam failed (error \(code)).",
                bundle: .appLanguage, comment: "Workshop failure cause for a transport error with no established meaning; the placeholder is the system error code."
            )
        case .networkUnreachable:
            String(
                localized: "Couldn't reach Steam. Check your connection.",
                bundle: .appLanguage, comment: "Workshop browse error when Steam is unreachable."
            )
        case .timeout:
            String(localized: "Steam took too long to respond.", bundle: .appLanguage, comment: "Steam Web API key validation error.")
        case let .http(status):
            String(
                localized: "Steam returned HTTP \(status).",
                bundle: .appLanguage, comment: "Workshop browse error with HTTP status. Placeholder is the status code."
            )
        case .responseParseFailure, .schemaMismatch:
            String(
                localized: "Steam returned an unexpected response.",
                bundle: .appLanguage, comment: "Workshop browse error when the Steam payload cannot be parsed."
            )
        case .cancelled:
            String(localized: "Cancelled", bundle: .appLanguage, comment: "Workshop browse request cancelled.")
        }
    }
}
#endif
