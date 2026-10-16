#if !LITE_BUILD
import Foundation
import LiveWallpaperCore

enum WPEProjectError: LocalizedError, Equatable, Sendable {
    case manifestNotFound
    case manifestUnreadable
    case manifestMalformed(String)

    var errorDescription: String? {
        switch self {
        case .manifestNotFound:
            String(
                localized: "it isn't a Wallpaper Engine project",
                bundle: .appLanguage, comment: "Scene import refusal reason, interpolated into a sentence: the project manifest is absent."
            )
        case .manifestUnreadable:
            String(
                localized: "its project information can't be read",
                bundle: .appLanguage, comment: "Scene import refusal reason, interpolated into a sentence: the project manifest could not be read."
            )
        case .manifestMalformed:
            String(
                localized: "its project information is damaged",
                bundle: .appLanguage, comment: "Scene import refusal reason, interpolated into a sentence: the project manifest is malformed."
            )
        }
    }
}

#endif
