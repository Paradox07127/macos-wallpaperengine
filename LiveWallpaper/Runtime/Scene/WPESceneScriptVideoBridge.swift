#if !LITE_BUILD
import Foundation

/// Detached source state; no decoder, texture backing, or VM object crosses lanes.
struct WPEVideoPlaybackSnapshot: Sendable, Equatable {
    let sourceGeneration: UUID
    var currentTime: Double
    let duration: Double
    var isPlaying: Bool
    var rate: Double
    var loop: Bool
    let hasPresentedFrame: Bool
    var acknowledgedPausedSeekTime: Double?
    var playbackRequested: Bool?
    var decoderCurrentTime: Double?

    mutating func applyEvaluationIntent(_ command: WPELayerVideoCommand) {
        switch command {
        case .play:
            isPlaying = true
            playbackRequested = true
        case .pause:
            isPlaying = false
            playbackRequested = false
        case .stop:
            isPlaying = false
            playbackRequested = false
            currentTime = acknowledgedPausedSeekTime ?? 0
        case let .setRate(value): rate = value
        case let .setLoop(value): loop = value
        case let .seek(seconds):
            guard seconds.isFinite else { return }
            guard seconds > 0, seconds < duration else {
                acknowledgedPausedSeekTime = nil
                currentTime = decoderCurrentTime ?? currentTime
                return
            }
            guard !(playbackRequested ?? isPlaying), hasPresentedFrame else { return }
            if acknowledgedPausedSeekTime == nil {
                acknowledgedPausedSeekTime = seconds
            }
            currentTime = acknowledgedPausedSeekTime ?? currentTime
        }
    }
}

/// Last committed script transport for one video source. nil = never commanded; seek is not kept.
struct WPEVideoScriptTransport: Sendable, Equatable {
    enum Playback: Sendable, Equatable { case play, pause, stop }

    var playback: Playback?
    var rate: Double?
    var loop: Bool?

    mutating func record(_ command: WPELayerVideoCommand) {
        switch command {
        case .play: playback = .play
        case .pause: playback = .pause
        case .stop: playback = .stop
        case let .setRate(value): rate = value
        case let .setLoop(value): loop = value
        case .seek: break
        }
    }

    /// `automaticPlayback`: whether a fresh source would auto-start. Script control disables
    /// auto-start, so a rate/loop-only history must request that playback itself.
    func apply(to source: WPEVideoTextureSource, automaticPlayback: Bool) {
        if let loop {
            source.scriptSetLoop(loop)
        }
        if let rate {
            source.scriptSetRate(rate)
        }
        switch playback {
        case .play: source.scriptPlay()
        case .pause: source.scriptPause()
        case .stop: source.scriptStop()
        case nil where (rate != nil || loop != nil) && automaticPlayback: source.scriptPlay()
        case nil: break
        }
    }
}

extension WPEMetalSceneRenderer {
    func publishVideoPlaybackSnapshots() {
        var bySource: [String: WPEVideoPlaybackSnapshot] = [:]
        var byObject: [String: WPEVideoPlaybackSnapshot] = [:]
        for (objectID, key) in layerVideoSourceKey {
            if bySource[key] == nil,
               let source = dynamicTextureSources[key] as? WPEVideoTextureSource {
                bySource[key] = source.scriptPlaybackSnapshot
            }
            byObject[objectID] = bySource[key]
        }
        sceneScriptSharedState?.publishVideoPlayback(byObject, sourceKeys: layerVideoSourceKey)
    }
}
#endif
