import LiveWallpaperCore
import SwiftUI

extension WallpaperBookmark {
    var presentationTint: Color {
        switch content {
        case .video: return DesignTokens.Colors.ContentType.video
        case .html: return DesignTokens.Colors.ContentType.html
        case .scene: return DesignTokens.Colors.ContentType.scene
        }
    }
}
