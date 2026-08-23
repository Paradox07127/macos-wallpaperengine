import Foundation
import LiveWallpaperCore

/// Everything the Now Playing layer draws from. The Monitor board's
/// `MonitorWidgetContext` carries a widget placement and a metric history the
/// music layer has no use for; keeping them apart is what lets the layer stop
/// being a board widget.
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
