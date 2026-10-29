#if !LITE_BUILD
import Foundation
import LiveWallpaperCore

enum WorkshopAPIKeyOwnershipInfo {
    static var prerequisitesLine: String {
        String(
            localized: "Use your own Steam account. Valve determines whether it can create a Web API key. The key is optional for SteamCMD downloads.",
            bundle: .appLanguage, comment: "Reminder shown above the API-key entry field. Explains Valve's eligibility gate."
        )
    }

    static var forgetTooltip: String {
        String(
            localized: "Removes the stored key from this Mac. Your key remains active under your Steam account at steamcommunity.com/dev/apikey until you revoke it there.",
            bundle: .appLanguage, comment: "Tooltip on the Forget button in WorkshopSettingsView."
        )
    }

    static var passwordReassurance: String {
        String(
            localized: "This field accepts only your Steam Web API key, which is stored in this Mac's keychain. SteamCMD sign-in is separate.",
            bundle: .appLanguage, comment: "Secondary reassurance under the API-key-required state and entry sheet."
        )
    }
}
#endif
