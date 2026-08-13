import Foundation

public enum WPESceneObjectKind: String, Equatable, Sendable {
    case image
    case sound
    case particle
    case text
    case light
    case unknown

    public var displayName: String {
        switch self {
        case .image: return "Image"
        case .sound: return "Sound"
        case .particle: return "Particle"
        case .text: return "Text"
        case .light: return "Light"
        case .unknown: return "Unknown"
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
