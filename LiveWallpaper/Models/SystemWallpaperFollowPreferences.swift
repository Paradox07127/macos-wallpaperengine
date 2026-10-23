import CoreGraphics
import Foundation

/// Values are the SceneMode/ResolutionCap raw strings and integer fps/seconds.
enum SystemWallpaperFollowPreferences {
    static let sceneMode = "SystemWallpaper.Follow.SceneMode"
    static let resolutionCap = "SystemWallpaper.Follow.ResolutionCap"
    static let frameRate = "SystemWallpaper.Follow.FrameRate"
    static let loopLength = "SystemWallpaper.Follow.LoopLength"

    enum ResolutionCap: String, CaseIterable {
        case matchDisplay, p1080, p1440, p4K

        var size: CGSize {
            switch self {
            case .matchDisplay, .p4K: CGSize(width: 3840, height: 2160)
            case .p1080: CGSize(width: 1920, height: 1080)
            case .p1440: CGSize(width: 2560, height: 1440)
            }
        }
    }

    static func options(defaults: UserDefaults, displaySize: CGSize) -> SystemWallpaperPreparationOptions {
        var options = SystemWallpaperPreparationOptions()
        options.sceneMode = defaults.string(forKey: sceneMode)
            .flatMap(SystemWallpaperPreparationOptions.SceneMode.init(rawValue:)) ?? .live
        let fps = defaults.integer(forKey: frameRate)
        options.framesPerSecond = [15, 30, 60].contains(fps) ? fps : 30
        let seconds = defaults.integer(forKey: loopLength)
        options.duration = [15, 30, 60].contains(seconds) ? Double(seconds) : 15
        let cap = defaults.string(forKey: resolutionCap).flatMap(ResolutionCap.init(rawValue:)) ?? .matchDisplay
        let pixels = displaySize.width.isFinite && displaySize.height.isFinite
            && displaySize.width >= 64 && displaySize.height >= 64 ? displaySize : options.size
        let scale = min(1, cap.size.width / pixels.width, cap.size.height / pixels.height)
        // Movie encoders require even dimensions; retain the display's aspect ratio within the cap.
        options.size = CGSize(width: max(64, floor(pixels.width * scale / 2) * 2),
                              height: max(64, floor(pixels.height * scale / 2) * 2))
        return options
    }

    /// The 16:9 sizes the Generate Copy sheet offers, smallest first.
    static let copySizes = [CGSize(width: 1280, height: 720), CGSize(width: 1920, height: 1080),
                            CGSize(width: 2560, height: 1440), CGSize(width: 3840, height: 2160)]

    /// Starting values for the Generate Copy sheet: the follow preferences, with the size rounded down to a `copySizes` entry.
    static func copyOptions(defaults: UserDefaults, displaySize: CGSize) -> SystemWallpaperPreparationOptions {
        var options = options(defaults: defaults, displaySize: displaySize)
        options.size = copySizes.last { $0.height <= options.size.height } ?? copySizes[0]
        return options
    }
}
