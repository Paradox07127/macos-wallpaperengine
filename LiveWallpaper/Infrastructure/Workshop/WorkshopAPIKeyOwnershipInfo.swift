#if !LITE_BUILD
import Foundation
import LiveWallpaperCore

/// Single source of truth for the official Valve links + the user-facing copy that explains the Steam Web API key belongs to the user's own Steam account (not Loomscreen), and the eligibility gate Valve enforces.
/// Shared across `SteamWebAPIKeyEntrySheet`, `WorkshopSettingsView`, and `OnboardingSheet` so translations stay aligned.
enum WorkshopAPIKeyOwnershipInfo {
    static var prerequisitesLine: String { String(
        localized: "Prerequisites: a Steam account with Mobile Steam Guard and at least $5 of Steam Store spend (non-limited).",
        bundle: .appLanguage, comment: "Reminder shown above the API-key entry field. Explains Valve's eligibility gate."
    ) }
    static var forgetTooltip: String { String(
        localized: "Removes the stored key from this Mac. Your key remains active under your Steam account at steamcommunity.com/dev/apikey until you revoke it there.",
        bundle: .appLanguage, comment: "Tooltip on the Forget button in WorkshopSettingsView."
    ) }
    static var passwordReassurance: String { String(
        localized: "Loomscreen never reads your Steam password — only this key, stored locally on this Mac.",
        bundle: .appLanguage, comment: "Secondary reassurance under the API-key-required state and entry sheet."
    ) }
}
#endif
