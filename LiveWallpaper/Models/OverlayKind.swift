import LiveWallpaperCore
import SwiftUI

enum OverlayKind: Hashable, CaseIterable {
    case weather
    case monitor
    case music
    case clock

    var title: LocalizedStringKey {
        switch self {
        case .weather: "Weather"
        case .monitor: "Widgets"
        case .music: "Music"
        case .clock: "Clock"
        }
    }

    var applyToAllName: String {
        switch self {
        case .weather: String(localized: "Weather", bundle: .appLanguage, comment: "Overlay name inside the apply-to-all confirmation.")
        case .monitor: String(localized: "Widgets", bundle: .appLanguage, comment: "Overlay name inside the apply-to-all confirmation.")
        case .music: String(localized: "Music", bundle: .appLanguage, comment: "Overlay name inside the apply-to-all confirmation.")
        case .clock: String(localized: "Clock", bundle: .appLanguage, comment: "Independent decorative clock overlay.")
        }
    }

    var feature: ProductFeature {
        switch self {
        case .weather: .videoEffects
        case .monitor, .music, .clock: .monitorOverlay
        }
    }
}
