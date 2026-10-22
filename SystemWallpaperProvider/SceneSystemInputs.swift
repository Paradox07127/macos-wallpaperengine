#if !LITE_BUILD
import Foundation

/// The wallpaper extension has no system-audio tap or desktop music monitor.
enum SystemAudioCaptureManager {
    static let isCapturing = false
    static let broker = AudioSpectrumBroker()
}

#endif
