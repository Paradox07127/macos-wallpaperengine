import AppKit
import Observation
import LiveWallpaperCore

// Isolates the wallpaper runtime and display; all gesture and transform code is
// the product WebTransformCanvas. Writes are captured, never applied to a desktop.
@MainActor struct Screen {
    let id: UInt32
    let frame = CGRect(x: 0, y: 0, width: 960, height: 720)
}
@MainActor @Observable final class ScreenManager {
    var writes: [HTMLConfig] = []
    func updateHTMLConfig(_ config: HTMLConfig, for screen: Screen) { writes.append(config) }
}
@MainActor enum TransformTrace {
    static var translation = CGSize.zero
    static var manipulating = false
}
