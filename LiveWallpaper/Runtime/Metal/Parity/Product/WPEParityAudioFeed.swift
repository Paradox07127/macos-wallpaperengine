#if !LITE_BUILD
import Foundation
import LiveWallpaperCore
import LiveWallpaperProWPE

/// WPE provider bins over the shared capture's newest samples, recomputed only when new audio arrives.
struct WPEParityAudioFeed {
    /// nil until the first published window reveals the capture's sample rate.
    private var provider: WPEParityAudioProvider?
    private var providerRate: Float = 0
    /// `totalSamples` of the window `latest` was computed from.
    private var analyzedTotal = 0
    private var latest: AudioSpectrumFrame?
    private var loggedShortWindow = false

    mutating func frame(broker: AudioSpectrumBroker, isCapturing: Bool) -> AudioSpectrumFrame? {
        guard isCapturing else { return nil }
        // A count of 0 is served whenever an analyzer is attached, so it still reports the rate when L is not.
        guard var samples = broker.latestSamples(count: provider?.frameSamples ?? 0)
            ?? broker.latestSamples(count: 0) else { return nil }
        if samples.sampleRate != providerRate {
            let rebuilt = WPEParityAudioProvider(sampleRate: Double(samples.sampleRate))
            (provider, providerRate, latest) = (rebuilt, samples.sampleRate, nil)
            guard let resized = broker.latestSamples(count: rebuilt.frameSamples) else { return nil }
            samples = resized
        }
        guard let provider else { return nil }
        guard samples.left.count == provider.frameSamples else {
            // Enough audio yet no window means the analyzer's window is shorter than L (fs > 70.6 kHz).
            if samples.totalSamples >= provider.frameSamples, !loggedShortWindow {
                loggedShortWindow = true
                Logger.warning("Parity audio stays silent: \(providerRate) Hz needs \(provider.frameSamples) samples per window",
                               category: .wpeRender)
            }
            return nil
        }
        if samples.totalSamples == analyzedTotal, let latest {
            return latest
        }
        let bins = provider.bins(left: samples.left, right: samples.right)
        let frame = AudioSpectrumFrame(validatedLeft: Array(bins[..<64]), validatedRight: Array(bins[64...]),
                                       timestampNanos: DispatchTime.now().uptimeNanoseconds)
        (analyzedTotal, latest) = (samples.totalSamples, frame)
        return frame
    }
}
#endif
