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

    mutating func applyEvaluationIntent(_ command: WPELayerVideoCommand) {
        switch command {
        case .play: isPlaying = true
        case .pause: isPlaying = false
        case .stop:
            isPlaying = false
            currentTime = 0
        case let .setRate(value): rate = value
        case let .setLoop(value): loop = value
        case .seek: break
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
