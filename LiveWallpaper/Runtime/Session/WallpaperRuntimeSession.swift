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
    func hide()
    func applyPerformanceProfile(_ profile: WallpaperPerformanceProfile)
    func updateFrame(to frame: CGRect)
    func cleanup()

    /// User-triggered retry from the error banner.
    func retry() async

    /// Wait for first frame so transitions do not flash empty.
    func prepareForDisplay(timeout: Duration) async -> WallpaperPreparationResult
}

extension WallpaperRuntimeSession {
    var runtimeError: WallpaperRuntimeError? { nil }

    func retry() async {}
}
