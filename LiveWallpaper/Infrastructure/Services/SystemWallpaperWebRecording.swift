#if !LITE_BUILD
import AppKit
import AVFoundation
import LiveWallpaperCore
import ScreenCaptureKit

@available(macOS 26.0, *)
private final class SystemWallpaperRecordingEvents: NSObject, SCRecordingOutputDelegate, Sendable {
    enum Event: Sendable { case started, finished }
    let stream: AsyncThrowingStream<Event, Error>
    private let continuation: AsyncThrowingStream<Event, Error>.Continuation
    private let watchdog: Task<Void, Never>

    init(timeout: TimeInterval) {
        (stream, continuation) = AsyncThrowingStream.makeStream()
        let continuation = continuation
        watchdog = Task {
            do {
                try await Task.sleep(for: .seconds(timeout))
                continuation.finish(throwing: SystemWallpaperWebRecording.Failure.recordingStopped)
            } catch {}
        }
        super.init()
    }

    deinit { watchdog.cancel() }

    func recordingOutputDidStartRecording(_: SCRecordingOutput) {
        continuation.yield(.started)
    }

    func recordingOutputDidFinishRecording(_: SCRecordingOutput) {
        watchdog.cancel()
        continuation.yield(.finished)
        continuation.finish()
    }

    func recordingOutput(_: SCRecordingOutput, didFailWithError error: Error) {
        watchdog.cancel()
        continuation.finish(throwing: error)
    }
}

/// Captures composited WebKit output; snapshots can omit GPU-rendered page content.
@available(macOS 26.0, *)
@MainActor
enum SystemWallpaperWebRecording {
    enum Failure: LocalizedError {
        case windowUnavailable, pageFailed, recordingStopped
        var errorDescription: String? {
            switch self {
            case .windowUnavailable:
                String(localized: "Couldn't capture the wallpaper preview window.", bundle: .appLanguage)
            case .pageFailed:
                String(localized: "The web wallpaper did not finish loading or stopped during recording.", bundle: .appLanguage)
            case .recordingStopped:
                String(localized: "The wallpaper recording stopped before it finished.", bundle: .appLanguage)
            }
        }
    }

    static func record(
        source: HTMLSource, config: HTMLConfig, url: URL,
        size: CGSize, duration: TimeInterval, framesPerSecond: Int, progress: (Double) -> Void
    ) async throws {
        var config = config
        config.muteAudio = true
        config.audioVolume = 0
        config.allowMouseInteraction = false
        let screen = NSScreen.main
        let scale = screen?.backingScaleFactor ?? 2
        let frame = CGRect(origin: screen?.visibleFrame.origin ?? .zero,
                           size: CGSize(width: size.width / scale, height: size.height / scale))
        let session = AmbientWallpaperSessionBuilder().makeHTMLSession(source: source, config: config, frame: frame)
        defer { session.cleanup() }
        guard let window = session.wallpaperWindow,
              let view = window.contentView as? HTMLWallpaperView else { throw Failure.windowUnavailable }
        // A real preview keeps WebKit animating; no private occlusion overrides or transparent windows.
        window.level = .normal
        window.sharingType = .readOnly
        window.orderFront(nil)
        session.setFrameRateCeiling(framesPerSecond)
        session.play()
        let clock = ContinuousClock()
        let readyDeadline = clock.now.advanced(by: .seconds(30))
        while view.completedNavigationGeneration == nil {
            try Task.checkCancellation()
            guard session.runtimeError == nil, clock.now < readyDeadline else { throw Failure.pageFailed }
            try await clock.sleep(for: .milliseconds(100))
        }
        try await view.hideClockCalendarForSystemWallpaperRecording()
        try await clock.sleep(for: .seconds(1))

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let captured = content.windows.first(where: { $0.windowID == UInt32(window.windowNumber) }) else {
            throw Failure.windowUnavailable
        }
        let configuration = SCStreamConfiguration()
        configuration.width = Int(size.width)
        configuration.height = Int(size.height)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(framesPerSecond))
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.captureMicrophone = false
        configuration.queueDepth = 3
        configuration.ignoreShadowsSingleWindow = true
        let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: captured), configuration: configuration, delegate: nil)
        let events = SystemWallpaperRecordingEvents(timeout: duration + 60)
        let recordingConfiguration = SCRecordingOutputConfiguration()
        recordingConfiguration.outputURL = url
        recordingConfiguration.outputFileType = .mov
        recordingConfiguration.videoCodecType = .h264
        let output = SCRecordingOutput(configuration: recordingConfiguration, delegate: events)
        try stream.addRecordingOutput(output)
        var iterator = events.stream.makeAsyncIterator()
        do {
            try await stream.startCapture()
            guard try await iterator.next() == .started else { throw Failure.recordingStopped }
            let start = clock.now
            while start.duration(to: clock.now) < .seconds(duration) {
                try Task.checkCancellation()
                guard session.runtimeError == nil, window.isVisible else { throw Failure.pageFailed }
                try await clock.sleep(for: .milliseconds(100))
                let elapsed = start.duration(to: clock.now)
                let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                progress(min(seconds / duration, 1))
            }
            try await stream.stopCapture()
            guard try await iterator.next() == .finished else { throw Failure.recordingStopped }
            try Task.checkCancellation()
        } catch {
            try? await stream.stopCapture()
            throw error
        }
    }
}
#endif
