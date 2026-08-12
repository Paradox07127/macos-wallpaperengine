import SwiftUI

public enum WallpaperType: String, Codable, CaseIterable, Identifiable, Sendable {
    case video = "Video"
    case html = "HTML"
    case scene = "Scene"

    public var id: String { rawValue }

    public var titleKey: LocalizedStringKey {
        switch self {
        case .video: return "Video"
        case .html: return "Web"
        case .scene: return "Scene"
        }
    }
}
