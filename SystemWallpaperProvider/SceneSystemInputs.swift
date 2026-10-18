#if !LITE_BUILD
import Foundation

/// The wallpaper extension has no system-audio tap or desktop music monitor.
enum SystemAudioCaptureManager {
    static let isCapturing = false
    static let broker = AudioSpectrumBroker()
}

@MainActor
final class WPEEnrichedNowPlayingFeed: WPENowPlayingEventSource {
    static let shared = WPEEnrichedNowPlayingFeed()
    func subscribe(id _: UUID, handler: @escaping @Sendable (UInt64, MonitorNowPlayingState) -> Void) {
        handler(0, MonitorNowPlayingState(phase: .noPlayer, title: ""))
    }

    func unsubscribe(id _: UUID) {}
}
#endif
