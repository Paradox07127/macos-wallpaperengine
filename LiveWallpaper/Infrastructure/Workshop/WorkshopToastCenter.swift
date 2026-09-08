#if !LITE_BUILD
import CoreGraphics
import Foundation
import LiveWallpaperCore
import Observation

/// One channel for every terminal Workshop outcome — SteamCMD downloads and
/// local folder imports both post here, so a single `DownloadToastHost`
/// renders them with consistent ordering.
struct WorkshopToastEvent: Equatable, Sendable {
    let token: Int
    let headline: String
    let title: String
    let message: String
    let isSuccess: Bool
    var failure: WallpaperFailureSnapshot?
    var screenID: CGDirectDisplayID?
}

/// The monotonic token lets the host re-fire on every post, including a repeat
/// of an identical outcome.
@MainActor
@Observable
final class WorkshopToastCenter {
    static let shared = WorkshopToastCenter()

    private(set) var lastEvent: WorkshopToastEvent?

    @ObservationIgnored private var token = 0

    private init() {}

    func postFailure(_ failure: WallpaperFailureSnapshot, screenID: CGDirectDisplayID) {
        guard lastEvent?.failure?.id != failure.id else { return }
        token += 1
        lastEvent = WorkshopToastEvent(token: token,
                                       headline: String(localized: "Last wallpaper application failed", bundle: .appLanguage),
                                       title: "\(failure.title) · \(failure.displayName)",
                                       message: failure.cause.reason, isSuccess: false,
                                       failure: failure, screenID: screenID)
    }

    func post(headline: String, title: String, message: String, isSuccess: Bool) {
        token += 1
        lastEvent = WorkshopToastEvent(
            token: token,
            headline: headline,
            title: title,
            message: message,
            isSuccess: isSuccess
        )
    }
}
#endif
