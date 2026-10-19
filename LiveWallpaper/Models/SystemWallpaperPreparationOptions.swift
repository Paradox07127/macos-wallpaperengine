import CoreGraphics
import Foundation

struct SystemWallpaperPreparationOptions: Codable, Equatable, Sendable {
    enum SceneMode: String, Codable, CaseIterable, Sendable { case live, videoCopy }
    var sceneMode: SceneMode = .live
    var containsLiveData = false
    var duration: TimeInterval = 15
    var framesPerSecond = 30
    var size = CGSize(width: 1920, height: 1080)

    var isValid: Bool {
        duration.isFinite && (1 ... 60).contains(duration)
            && [15, 30, 60].contains(framesPerSecond)
            && size.width.isFinite && size.height.isFinite
            && (64 ... 3840).contains(size.width) && (64 ... 2160).contains(size.height)
            && size.width.rounded(.down) == size.width && size.height.rounded(.down) == size.height
            && Int(size.width).isMultiple(of: 2) && Int(size.height).isMultiple(of: 2)
    }
}
