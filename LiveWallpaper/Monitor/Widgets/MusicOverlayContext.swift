import Foundation
import LiveWallpaperCore

struct MusicOverlayContext {
    /// The pump's latest frame; the layer reads only `nowPlaying` from it.
    var snapshot: MonitorSnapshot
    var size: MusicOverlaySize
    var options: [String: MonitorWidgetOptionValue]
    /// True in the Settings preview, where the layer draws a placeholder rather
    /// than disappearing when nothing is playing.
    var isEditing: Bool
    var reduceMotion: Bool
    var now: Date
}
