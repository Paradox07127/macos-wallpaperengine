#if !LITE_BUILD
import Foundation

/// Detached decoder state; textures, decoders and VM values never cross the actor boundary.
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
}
#endif
