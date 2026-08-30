import Foundation
import LiveWallpaperCore

public enum WPESceneObjectKind: String, Equatable, Sendable {
    case image
    case sound
    case particle
    case text
    case light
    case unknown

    public var displayName: String {
        switch self {
        case .image: return String(localized: "Image", bundle: .appLanguage, comment: "Wallpaper Engine scene object type.")
        case .sound: return String(localized: "Sound", bundle: .appLanguage, comment: "Wallpaper Engine scene object type.")
        case .particle: return String(localized: "Particle", bundle: .appLanguage, comment: "Wallpaper Engine scene object type.")
        case .text: return String(localized: "Text", bundle: .appLanguage, comment: "Wallpaper Engine scene object type.")
        case .light: return String(localized: "Light", bundle: .appLanguage, comment: "Wallpaper Engine scene object type.")
        case .unknown: return String(localized: "Unknown", bundle: .appLanguage, comment: "Wallpaper Engine scene object type.")
        }
    }
}

struct WPESceneObjectKindResolution: Equatable, Sendable {
    let primary: WPESceneObjectKind
    let candidates: [WPESceneObjectKind]
    let explicitType: String?

    init(primary: WPESceneObjectKind, candidates: [WPESceneObjectKind], explicitType: String?) {
        self.primary = primary
        self.candidates = candidates
        self.explicitType = explicitType
    }

    var isAmbiguous: Bool { candidates.count > 1 }
}
