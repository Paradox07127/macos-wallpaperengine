import AppKit
import CoreGraphics
@testable import LiveWallpaperCore
import Testing

@Suite("Visible app-window detection")
@MainActor
struct AppWindowDetectionTests {
    private let displays: [(id: CGDirectDisplayID, frame: CGRect)] = [
        (1, CGRect(x: 0, y: 0, width: 1000, height: 1000)),
        (2, CGRect(x: 1000, y: 0, width: 1000, height: 1000)),
    ]

    private func window(_ frame: CGRect, owner: String = "WhatsApp", layer: Int = 0, alpha: Double = 1) -> [String: Any] {
        [
            kCGWindowBounds as String: ["X": frame.minX, "Y": frame.minY, "Width": frame.width, "Height": frame.height],
            kCGWindowOwnerName as String: owner,
            kCGWindowLayer as String: layer,
            kCGWindowAlpha as String: alpha,
        ]
    }

    @Test("Desktop surfaces, system panels and transparent windows cannot pause themselves")
    func ignoresNonAppSurfaces() {
        _ = NSApplication.shared
        let detector = FullScreenDetector()
        let rect = CGRect(x: 10, y: 10, width: 300, height: 400)
        detector.scanWindows([
            window(rect, owner: "Dock"), window(rect, owner: "Window Server"),
            window(rect, owner: "SystemUIServer"), window(rect, layer: -1),
            window(rect, layer: 2), window(rect, alpha: 0),
        ], screenFrames: displays)
        #expect(detector.appWindowScreens.values.allSatisfy { !$0 })
        detector.scanWindows([window(rect, owner: "Finder")], screenFrames: displays)
        #expect(detector.appWindowScreens[1] == true, "Ordinary Finder windows still count")
    }

    @Test("Stage Manager previews cannot hold a display paused, but real windows in front still count")
    func ignoresParkedAppPreviews() {
        _ = NSApplication.shared
        let detector = FullScreenDetector()
        let preview = CGRect(x: 15, y: 501, width: 95, height: 148)
        let system = window(preview, owner: "WindowManager")
        let parked = window(preview)
        let parkedTitle = window(CGRect(x: 16, y: 502, width: 8, height: 5))
        detector.scanWindows([system, parkedTitle, parked], screenFrames: displays)
        #expect(detector.appWindowScreens.values.allSatisfy { !$0 })
        detector.scanWindows([parked, system], screenFrames: displays)
        #expect(detector.appWindowScreens[1] == true, "An ordinary window in front of the preview must count")
        detector.scanWindows([system, parked, window(CGRect(x: 1200, y: 20, width: 300, height: 400))], screenFrames: displays)
        #expect(detector.appWindowScreens[1] == false)
        #expect(detector.appWindowScreens[2] == true)
    }
}
