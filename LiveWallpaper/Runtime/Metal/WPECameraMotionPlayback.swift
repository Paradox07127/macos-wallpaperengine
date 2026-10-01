#if !LITE_BUILD
import Foundation
import LiveWallpaperProWPE

struct WPECameraMotionPlayback: Equatable, Sendable {
    static let zoomScriptKey = "\u{1}camera-zoom"
    let definition: WPESceneCameraMotion
    private(set) var elapsed = 0.0
    private var previousSceneTime: Double?
    private var hasDrawn = false
    private var evaluatedTime = 0.0

    var needsFrames: Bool {
        definition.needsFrames(at: evaluatedTime)
    }

    mutating func sample(sceneTime: Double) -> WPESceneCameraMotionSample {
        guard sceneTime.isFinite else { return definition.seed }
        let value = hasDrawn ? definition.sample(at: elapsed) : definition.seed
        evaluatedTime = elapsed
        if let previousSceneTime {
            elapsed += max(0, sceneTime - previousSceneTime)
        }
        previousSceneTime = sceneTime
        hasDrawn = true
        return value
    }

    mutating func suspend() {
        previousSceneTime = nil
    }
}
#endif
