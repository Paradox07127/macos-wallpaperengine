#if !LITE_BUILD
import Foundation
import LiveWallpaperCore

@MainActor
enum DeferredApplyToasts {
    struct Message: Equatable {
        let text: String
        let style: EditDeskToastCenter.Toast.Style
    }

    static func messages(for state: DeferredApplyCoordinator.State, screenName: String) -> [Message]? {
        switch state {
        case let .finished(report):
            var messages: [Message] = []
            if report.exitedSpanMode {
                messages.append(Message(text: String(localized: "Left span mode", bundle: .appLanguage), style: .info))
            }
            messages.append(Message(
                text: appliedText(report, screenName: screenName),
                style: report.outcome == .applied ? .success : .failure
            ))
            return messages
        case .downloadOnly(.failed):
            return [Message(
                text: String(
                    localized: "The download failed, so nothing was applied to \(screenName).",
                    bundle: .appLanguage,
                    comment: "Workshop deferred apply dropped because the download failed. Placeholder is a display name."
                ),
                style: .failure
            )]
        case .invalidated(.newerSelection):
            return [Message(
                text: String(
                    localized: "\(screenName) changed in the meantime, so the download wasn’t applied.",
                    bundle: .appLanguage,
                    comment: "Workshop deferred apply dropped because the user applied something else there. Placeholder is a display name."
                ),
                style: .info
            )]
        case .invalidated(.screenUnavailable):
            return [Message(
                text: String(
                    localized: "\(screenName) is no longer connected, so the download wasn’t applied.",
                    bundle: .appLanguage,
                    comment: "Workshop deferred apply dropped because the target display went away. Placeholder is a display name."
                ),
                style: .info
            )]
        case .downloadOnly, .invalidated, .waiting, .applying:
            return nil
        }
    }

    static func appliedText(_ report: ApplyReport, screenName: String) -> String {
        switch report.outcome {
        case .applied:
            String(
                localized: "Applied to \(screenName)", bundle: .appLanguage,
                comment: "Toast after a wallpaper reached a display. Placeholder is a display name."
            )
        case let .registeredPreset(name):
            name
        case let .failed(failure):
            failure.toastText
        }
    }
}
#endif
