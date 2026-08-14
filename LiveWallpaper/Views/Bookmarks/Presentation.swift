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

    var subtitleText: Text {
        switch content {
        case .video:
            if let name = sourceDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines),
               !name.isEmpty {
                return Text(verbatim: name)
            }
            return Text("Source missing")
        case .html(let source, _):
            return Text(verbatim: source.displayName)
        case .scene(let descriptor):
            return Text("Workshop \(descriptor.workshopID)", comment: "Bookmark subtitle for a Workshop scene. The placeholder is the Workshop ID.")
        }
    }
}
