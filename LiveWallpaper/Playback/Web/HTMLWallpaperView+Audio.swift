import Foundation
import LiveWallpaperCore
import WebKit

extension HTMLWallpaperView {
    nonisolated static let audioSpectrumMessageName = "lwAudioSpectrum"
}

#if LITE_BUILD

/// Lite ships no system-audio capture, so the global is never installed and pages take the
/// fallback path Wallpaper Engine documents for hosts without audio processing.
extension HTMLWallpaperView {
    var audioSpectrumBridgeScript: String? {
        nil
    }

    func installAudioSpectrumMessageHandler() {}

    func noteAudioSpectrumListenerRegistered() {}

    func dropAudioSpectrumListeners() {}

    func reconcileAudioSpectrumPump() {}
}

#else

/// `WKUserContentController` retains its handlers and the view owns the web view, so the handler
/// itself must not be the view.
@MainActor
final class AudioSpectrumMessageProxy: NSObject, WKScriptMessageHandler {
    private weak var target: HTMLWallpaperView?

    init(target: HTMLWallpaperView) {
        self.target = target
        super.init()
    }

    nonisolated func userContentController(
        _: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        MainActor.assumeIsolated {
            // Only the wallpaper's own document registers a visualizer; a subframe posting here must not retain the tap.
            guard message.frameInfo.isMainFrame else { return }
            target?.noteAudioSpectrumListenerRegistered()
        }
    }
}

extension HTMLWallpaperView {
    /// Wallpaper Engine delivers roughly 30 Hz.
    nonisolated static let audioSpectrumPushInterval: Duration = .milliseconds(33)

    var audioSpectrumBridgeScript: String? {
        HTMLWallpaperRuntimeScript.audioSpectrumBridge(messageName: Self.audioSpectrumMessageName)
    }

    func installAudioSpectrumMessageHandler() {
        let controller = webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: Self.audioSpectrumMessageName)
        controller.add(AudioSpectrumMessageProxy(target: self), name: Self.audioSpectrumMessageName)
    }

    func noteAudioSpectrumListenerRegistered() {
        guard !audioSpectrumListenerActive else { return }
        audioSpectrumListenerActive = true
        #if DEBUG
        Logger.info("[web audio] page registered an audio listener", category: .screenManager)
        #endif
        reconcileAudioSpectrumPump()
    }

    /// A reload or a hibernation drop takes the page's listeners with it; without this the tap
    /// would stay retained against an `about:blank` document.
    func dropAudioSpectrumListeners() {
        guard audioSpectrumListenerActive else { return }
        audioSpectrumListenerActive = false
        reconcileAudioSpectrumPump()
    }

    func reconcileAudioSpectrumPump() {
        let shouldRun = audioSpectrumListenerActive && !mediaPlaybackSuspended && !isCleaningUp
        setAudioSpectrumCaptureDemand(shouldRun)

        guard shouldRun else {
            audioSpectrumPumpTask?.cancel()
            audioSpectrumPumpTask = nil
            return
        }
        guard audioSpectrumPumpTask == nil else { return }
        #if DEBUG
        Logger.info("[web audio] spectrum pump started", category: .screenManager)
        #endif

        audioSpectrumPumpTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                pushAudioSpectrumFrame()
                try? await Task.sleep(for: HTMLWallpaperView.audioSpectrumPushInterval)
            }
        }
    }

    private func setAudioSpectrumCaptureDemand(_ retained: Bool) {
        guard retained != audioSpectrumCaptureRetained else { return }
        audioSpectrumCaptureRetained = retained
        if retained {
            SystemAudioCaptureManager.shared.retain()
        } else {
            SystemAudioCaptureManager.shared.release()
        }
    }

    /// Wallpaper Engine's layout: 64 left bins then 64 right bins, low frequency first.
    nonisolated static func audioSpectrumValues(for frame: AudioSpectrumFrame) -> [Double] {
        var values = [Double]()
        values.reserveCapacity(frame.left.count + frame.right.count)
        for bin in frame.left {
            values.append(Double(bin))
        }
        for bin in frame.right {
            values.append(Double(bin))
        }
        return values
    }

    private func pushAudioSpectrumFrame() {
        let values = Self.audioSpectrumValues(
            for: SystemAudioCaptureManager.broker.snapshot(clampedTo01: false)
        )

        webView.callAsyncJavaScript(
            HTMLWallpaperRuntimeScript.audioSpectrumPush,
            arguments: ["values": values],
            in: nil,
            in: .page,
            completionHandler: { _ in }
        )
    }
}

#endif
