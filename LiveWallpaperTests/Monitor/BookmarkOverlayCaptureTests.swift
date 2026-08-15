import Foundation
import LiveWallpaperCore
import Testing
@testable import LiveWallpaper

/// A bookmark restores whether the Monitor overlay was showing, and on which
/// layer — but never the board's own layout. The board is arranged against one
/// display and shared by every wallpaper on it, so a bookmark carrying its own
/// copy would silently overwrite arrangement work done after the bookmark was
/// saved.
@Suite("Bookmark Monitor overlay capture")
struct BookmarkMonitorOverlayCaptureTests {

    private func configuration() -> ScreenConfiguration {
        ScreenConfiguration(screenID: 1, wallpaper: .video(bookmarkData: Data([0x01])), particleEffect: .snow)
    }

    @Test("A snapshot records the overlay's enabled state and layer")
    func snapshotCapturesOverlayState() {
        var overlay = MonitorOverlayConfiguration(enabled: true, level: .front)
        overlay.board.widgets = [MonitorWidgetPlacement(kind: .cpu, size: .medium, x: 0.4, y: 0.2)]

        let snapshot = BookmarkPlaybackSettings.snapshot(of: configuration(), monitorOverlay: overlay)

        #expect(snapshot.monitorOverlayEnabled == true)
        #expect(snapshot.monitorOverlayLevel == .front)
    }

    @Test("A snapshot taken without an overlay leaves the fields nil")
    func snapshotWithoutOverlayIsNil() {
        let snapshot = BookmarkPlaybackSettings.snapshot(of: configuration())
        #expect(snapshot.monitorOverlayEnabled == nil)
        #expect(snapshot.monitorOverlayLevel == nil)
    }

    /// Nil means "leave the target unchanged" for every other field on this
    /// type; the overlay fields must not become an exception.
    @Test("A legacy snapshot without the overlay fields still decodes")
    func legacySnapshotDecodes() throws {
        let legacy = Data("""
        {"playbackSpeed":1.5,"muted":true}
        """.utf8)
        let decoded = try JSONDecoder().decode(BookmarkPlaybackSettings.self, from: legacy)
        #expect(decoded.playbackSpeed == 1.5)
        #expect(decoded.monitorOverlayEnabled == nil, "an old bookmark must not claim the overlay was off")
        #expect(decoded.monitorOverlayLevel == nil)
    }

    @Test("The overlay fields survive a round-trip")
    func roundTrip() throws {
        let overlay = MonitorOverlayConfiguration(enabled: false, level: .desktop)
        let snapshot = BookmarkPlaybackSettings.snapshot(of: configuration(), monitorOverlay: overlay)
        let restored = try JSONDecoder().decode(
            BookmarkPlaybackSettings.self, from: JSONEncoder().encode(snapshot)
        )
        #expect(restored.monitorOverlayEnabled == false)
        #expect(restored.monitorOverlayLevel == .desktop)
    }

    /// The guard that keeps a bookmark from carrying board layout. If someone
    /// later adds a board field, this test should be the thing that makes them
    /// argue for it rather than slip it in.
    @Test("The snapshot carries no board layout")
    func snapshotOmitsBoardLayout() throws {
        var overlay = MonitorOverlayConfiguration(enabled: true, level: .desktop)
        overlay.board.widgets = [
            MonitorWidgetPlacement(kind: .cpu, size: .medium, x: 0.11, y: 0.22),
            MonitorWidgetPlacement(kind: .fleet, size: .large, x: 0.33, y: 0.44),
        ]
        let snapshot = BookmarkPlaybackSettings.snapshot(of: configuration(), monitorOverlay: overlay)
        let json = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)

        #expect(!json.contains("widgets"), "board layout must not ride along in a bookmark")
        #expect(!json.contains("refreshHz"))
    }
}
