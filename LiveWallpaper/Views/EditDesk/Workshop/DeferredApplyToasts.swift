#if !LITE_BUILD
import CoreGraphics
import Foundation
import LiveWallpaperCore

@MainActor
enum DeferredApplyToasts {
    struct Message: Equatable {
        let text: String
        let style: EditDeskToastCenter.Toast.Style
        /// Stays until dismissed: the download did not end up on the display the user chose.
        var persists = false
        /// The display the toast opens and whose failure toast it replaces; nil when it is about none.
        var screenID: CGDirectDisplayID?
        /// The undo step the toast's Undo button reverts; nil draws no button.
        var undoStepID: UUID?
    }

    /// `screenID` is the ticket's target; `wallpapersOn` is the master switch.
    static func messages(
        for state: DeferredApplyCoordinator.State, screenName: String,
        screenID: CGDirectDisplayID? = nil, wallpapersOn: Bool = true
    ) -> [Message]? {
        switch state {
        case let .finished(report):
            var messages: [Message] = []
            if report.exitedSpanMode {
                messages.append(Message(text: String(localized: "Left span mode", bundle: .appLanguage), style: .info))
            }
            // A Pro scene attempt has already raised its failure card, which opens that attempt.
            if case .prepareFailed(_, _?) = report.outcome {
                return messages
            }
            // A preset joins the library without touching the display.
            let changesDisplay = if case .registeredPreset = report.outcome {
                false
            } else {
                true
            }
            let style: EditDeskToastCenter.Toast.Style = if report.outcome == .applied {
                .success
            } else if changesDisplay {
                .failure
            } else {
                .info
            }
            messages.append(Message(
                text: appliedText(report, screenName: screenName, wallpapersOn: wallpapersOn),
                style: style,
                persists: changesDisplay && report.outcome != .applied,
                screenID: changesDisplay ? screenID : nil,
                undoStepID: report.undoStepID
            ))
            return messages
        case .downloadOnly(.failed):
            return [Message(
                text: String(
                    localized: "The download failed, so nothing was applied to \(screenName).",
                    bundle: .appLanguage,
                    comment: "Workshop deferred apply dropped because the download failed. Placeholder is a display name."
                ),
                style: .failure,
                persists: true,
                screenID: screenID
            )]
        case .invalidated(.newerSelection):
            return [Message(
                text: String(
                    localized: "\(screenName) changed in the meantime, so the download wasn’t applied.",
                    bundle: .appLanguage,
                    comment: "Workshop deferred apply dropped because the user applied something else there. Placeholder is a display name."
                ),
                style: .info,
                persists: true,
                screenID: screenID
            )]
        case let .downloadOnly(.unsupported(entry)):
            let reason = FallbackCard.cannotRunSummary(for: entry.origin)
            return [Message(
                text: String(
                    localized: "Downloaded, but it can't run on this Mac (\(reason)). Not applied to \(screenName).",
                    bundle: .appLanguage,
                    comment: "Workshop deferred apply dropped because this Mac cannot run the download. Placeholders are the reason and a display name."
                ),
                style: .failure,
                persists: true,
                screenID: screenID
            )]
        case .invalidated(.screenUnavailable):
            return [Message(
                text: String(
                    localized: "\(screenName) is no longer connected, so the download wasn’t applied.",
                    bundle: .appLanguage,
                    comment: "Workshop deferred apply dropped because the target display went away. Placeholder is a display name."
                ),
                style: .info,
                persists: true
            )]
        case .downloadOnly, .invalidated, .waiting, .applying:
            return nil
        }
    }

    static func appliedText(_ report: ApplyReport, screenName: String, wallpapersOn: Bool = true) -> String {
        switch report.outcome {
        case .applied:
            ApplyOutcome.appliedText(on: screenName, wallpapersOn: wallpapersOn)
        case let .registeredPreset(name):
            ApplyOutcome.registeredPresetText(name)
        case let .failed(failure):
            failure.toastText
        case let .prepareFailed(reason, _):
            reason
        case .importingLibrary:
            String(localized: "Importing from folder…", bundle: .appLanguage)
        }
    }

    /// The display as it is named now, or as it was when queued once it is no longer connected.
    static func screenName(for target: DeferredApplyCoordinator.Target, in screens: [Screen]) -> String {
        screens.first { $0.id == target.screenID }?.name ?? target.screenName
    }
}
#endif
