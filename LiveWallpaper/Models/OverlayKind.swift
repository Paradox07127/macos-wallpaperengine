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

    var feature: ProductFeature {
        switch self {
        case .weather: .videoEffects
        case .monitor, .music, .clock: .monitorOverlay
        }
    }
}
