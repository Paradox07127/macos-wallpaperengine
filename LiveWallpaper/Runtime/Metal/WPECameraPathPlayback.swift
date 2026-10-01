#if !LITE_BUILD
import Foundation
import LiveWallpaperProWPE

struct WPECameraPathPlayback: Equatable, Sendable {
    let paths: [WPESceneCameraPath]
    private(set) var index = 0
    private(set) var elapsed = 0.0
    private var previousSceneTime: Double?

    init?(paths: [WPESceneCameraPath]) {
        guard !paths.isEmpty,
              paths.allSatisfy({ !$0.transforms.isEmpty && $0.transforms.count <= 2 }),
              paths.count == 1 || paths.allSatisfy({ $0.playbackDuration > 0 }) else { return nil }
        self.paths = paths
    }

    var needsFrames: Bool {
        paths.count > 1 || paths.contains { $0.transforms.count > 1 && $0.playbackDuration > 0 }
    }

    mutating func sample(sceneTime: Double) -> WPESceneCameraMotionSample? {
        guard sceneTime.isFinite else { return nil }
        let path = paths[index]
        let pose = path.sample(at: min(elapsed, path.duration))
        let delta = previousSceneTime.map { max(0, sceneTime - $0) } ?? 0
        previousSceneTime = sceneTime
        if path.playbackDuration > 0 {
            if elapsed >= path.playbackDuration {
                index = (index + 1) % paths.count
                elapsed = 0
            } else {
                // The last transform can hold until the measured loop boundary.
                // Queue changes discard overshoot; g_Time is not the queue clock.
                elapsed = min(elapsed + delta, path.playbackDuration)
            }
        }
        guard let pose else { return nil }
        let transforms = WPEScriptCameraTransforms(eye: pose.eye, center: pose.center, up: pose.up, zoom: pose.zoom)
        return transforms.isValid ? transforms.motion : nil
    }

    mutating func suspend() {
        previousSceneTime = nil
    }
}
#endif
