import Foundation

/// One row of the System Wallpaper page's display list: what macOS shows on a display Loomscreen follows.
struct SystemWallpaperDisplayStatus: Equatable, Identifiable {
    enum State: Equatable {
        case playing
        /// nil = the preparation has not reported a fraction yet.
        case preparing(progress: Double?)
        case queued
        case needsRecording
        case cancelled
        case preparationFailed(message: String)
        /// `code` is the extension's `playbackFailures` value for the copy this display resolved to.
        case playbackFailed(code: String)
        case notUsingTile
    }

    let displayID: UInt32
    let title: String
    let state: State

    var id: UInt32 {
        displayID
    }

    static func evaluate(
        follow: SystemWallpaperFollowState,
        showsTile: (UInt32) -> Bool,
        playbackFailures: [String: String],
        preparationProgress: Double?
    ) -> [SystemWallpaperDisplayStatus] {
        follow.displays.values.sorted { $0.displayID < $1.displayID }.map { display in
            let state: State = switch display.phase {
            case .preparing:
                .preparing(progress: preparationProgress)
            case .needsRecording:
                .needsRecording
            case let .failed(message):
                .preparationFailed(message: message)
            case .cancelled:
                .cancelled
            case .queued:
                showsTile(display.displayID) ? .queued : .notUsingTile
            case let .ready(itemID):
                if let code = playbackFailures[itemID] {
                    .playbackFailed(code: code)
                } else {
                    showsTile(display.displayID) ? .playing : .notUsingTile
                }
            }
            return SystemWallpaperDisplayStatus(displayID: display.displayID, title: display.title, state: state)
        }
    }
}
