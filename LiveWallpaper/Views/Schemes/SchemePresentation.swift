import LiveWallpaperCore
import SwiftUI

extension ScreenScheme {
    var presentationTint: Color {
        switch configuration.activeWallpaper {
        case .video: DesignTokens.Colors.ContentType.video
        case .html: DesignTokens.Colors.ContentType.html
        case .scene: DesignTokens.Colors.ContentType.scene
        }
    }

    var iconName: String {
        switch configuration.activeWallpaper {
        case .video: "play.rectangle"
        case let .html(source, _): source.iconName
        case .scene: "cube.transparent"
        }
    }
}
