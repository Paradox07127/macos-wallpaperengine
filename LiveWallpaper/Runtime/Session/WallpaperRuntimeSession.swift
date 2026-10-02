import AppKit
import LiveWallpaperCore
import Metal

/// A copy of the frame a session last put on screen; its pixel format is the texture's.
struct WallpaperFrameCapture {
    let texture: any MTLTexture
    let colorSpace: CGColorSpace?
    /// True when values are extended-linear and may exceed 1.
    let isEDR: Bool
}

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
    func setTransitionHold(_ held: Bool)
    func updateFrame(to frame: CGRect)
    func cleanup()

    func retry() async

    func prepareForDisplay(timeout: Duration) async -> WallpaperPreparationResult

    /// `pixelFormat` and `colorSpace` are a request a session may ignore; nil = no frame to give.
    func captureDisplayedFrame(device: any MTLDevice, pixelFormat: MTLPixelFormat, colorSpace: CGColorSpace) async -> WallpaperFrameCapture?
}

extension WallpaperRuntimeSession {
    var runtimeError: WallpaperRuntimeError? { nil }

    func applyCapturePolicy(_ sharingType: NSWindow.SharingType) {
        wallpaperWindow?.sharingType = sharingType
    }

    func retry() async {}

    /// No-op: web and spanned-scene sessions are not frozen and keep playing through a transition.
    func setTransitionHold(_: Bool) {}

    /// Web and spanned-scene sessions cannot capture; their transitions fall back to the crossfade.
    func captureDisplayedFrame(device _: any MTLDevice, pixelFormat _: MTLPixelFormat, colorSpace _: CGColorSpace) async -> WallpaperFrameCapture? {
        nil
    }
}
