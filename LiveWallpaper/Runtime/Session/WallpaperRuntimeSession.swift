import AppKit
import LiveWallpaperCore

enum WallpaperPreparationResult: Equatable {
    case ready
    case failed
    case timedOut
    case cancelled
}

@MainActor
protocol WallpaperRuntimeSession: AnyObject {
    var wallpaperType: WallpaperType { get }
    var summary: WallpaperSessionSummary { get }
    var videoPlayer: WallpaperVideoPlayer? { get }
    var wallpaperWindow: NSWindow? { get }
    /// Latest user-visible failure, or nil while healthy.
    var runtimeError: WallpaperRuntimeError? { get }

    func show()
    func applyCapturePolicy(_ sharingType: NSWindow.SharingType)
    func applyPerformanceProfile(_ profile: WallpaperPerformanceProfile)
    func updateFrame(to frame: CGRect)
    func cleanup()

    func retry() async

    func prepareForDisplay(timeout: Duration) async -> WallpaperPreparationResult
}

extension WallpaperRuntimeSession {
    var runtimeError: WallpaperRuntimeError? { nil }

    func applyCapturePolicy(_ sharingType: NSWindow.SharingType) {
        wallpaperWindow?.sharingType = sharingType
    }

    func retry() async {}
}
