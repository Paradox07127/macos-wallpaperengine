#if !LITE_BUILD
import Foundation
import LiveWallpaperCore

/// Paths are relative to the immutable scene bundle published beside the videos.
struct SystemWallpaperSceneConfiguration: Codable, Sendable {
    struct Dependency: Codable, Sendable {
        let workshopID: String
        let directory: String
    }

    let descriptor: SceneDescriptor
    let dependencies: [Dependency]
    let hasEngineAssets: Bool
    var framesPerSecond = 30
    var renderSize = CGSize(width: 1920, height: 1080)
}
#endif
