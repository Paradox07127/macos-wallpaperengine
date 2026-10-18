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

@Suite("Detection when displays share one Space")
@MainActor
struct SharedSpaceDetectionTests {
    private let displays: [(id: CGDirectDisplayID, frame: CGRect)] = [
        (1, CGRect(x: 0, y: 0, width: 1000, height: 1000)),
        (2, CGRect(x: 1000, y: 0, width: 1000, height: 1000)),
    ]
    private let coveringWindow: [String: Any] = [
        kCGWindowBounds as String: ["X": 0, "Y": 0, "Width": 1000, "Height": 900] as [String: CGFloat],
        kCGWindowOwnerName as String: "WhatsApp",
        kCGWindowLayer as String: 0,
        kCGWindowAlpha as String: 1.0,
    ]

    private func detect(_ detector: FullScreenDetector, systemFullScreen: Bool) {
        detector.detect(
            screenFrames: displays,
            safeAreaFrames: [:],
            screensHaveSeparateSpaces: false,
            systemFullScreen: systemFullScreen
        ) { [coveringWindow] in [coveringWindow] }
    }

    @Test("Without app-window tracking only the system full-screen flag decides, windows are not scanned")
    func systemFlagDecidesWithoutTracking() {
        _ = NSApplication.shared
        let detector = FullScreenDetector()
        detector.setAppWindowTrackingEnabled(false)

        detect(detector, systemFullScreen: false)
        #expect(detector.hiddenScreens == [1: false, 2: false])
        #expect(detector.occludedScreens == [1: false, 2: false], "A covering window must not occlude without separate Spaces")
        #expect(detector.occlusionFractions == [1: 0, 2: 0])
        #expect(detector.appWindowScreens.isEmpty)

        detect(detector, systemFullScreen: true)
        #expect(detector.hiddenScreens == [1: true, 2: true])
        #expect(detector.occludedScreens == [1: true, 2: true])
        #expect(detector.occlusionFractions == [1: 1, 2: 1])
    }

    @Test("With app-window tracking the window scan still runs")
    func trackingScansWindows() {
        _ = NSApplication.shared
        let detector = FullScreenDetector()
        detector.setAppWindowTrackingEnabled(true)

        detect(detector, systemFullScreen: false)
        #expect(detector.appWindowScreens == [1: true, 2: false])
        #expect(detector.occludedScreens[1] == true)
    }
}
