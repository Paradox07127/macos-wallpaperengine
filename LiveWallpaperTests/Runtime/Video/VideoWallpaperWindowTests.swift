import AppKit
@testable import LiveWallpaper
@testable import LiveWallpaperCore
import Security
import Testing

@Suite("Wallpaper window capture policy", .serialized)
@MainActor
struct VideoWallpaperWindowTests {
    private func makeWindow() -> VideoWallpaperWindow {
        VideoWallpaperWindow(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    }

    private func makeOverlay() -> OverlayWindow {
        OverlayWindow(screenFrame: NSRect(x: 0, y: 0, width: 800, height: 600), level: .desktop)
    }

    @Test("Default policy leaves the wallpaper capturable")
    func defaultPolicyIsCapturable() {
        #expect(GlobalSettings().wallpaperVisibleInScreenCapture)
    }

    @Test("A window built while capture is allowed is readable by capture")
    func windowFollowsPolicyWhenAllowed() {
        let restore = WallpaperCapturePolicy.allowsScreenCapture
        defer { WallpaperCapturePolicy.allowsScreenCapture = restore }

        WallpaperCapturePolicy.allowsScreenCapture = true
        #expect(makeWindow().sharingType == .readOnly)
    }

    @Test("A window built while capture is denied is excluded from capture")
    func windowFollowsPolicyWhenDenied() {
        let restore = WallpaperCapturePolicy.allowsScreenCapture
        defer { WallpaperCapturePolicy.allowsScreenCapture = restore }

        WallpaperCapturePolicy.allowsScreenCapture = false
        #expect(makeWindow().sharingType == .none)
    }

    @Test("The Monitor overlay tracks the wallpaper's capture policy in both directions")
    func overlayMatchesWallpaperCapturePolicy() {
        let restore = WallpaperCapturePolicy.allowsScreenCapture
        defer { WallpaperCapturePolicy.allowsScreenCapture = restore }

        for allowed in [true, false] {
            WallpaperCapturePolicy.allowsScreenCapture = allowed
            #expect(makeOverlay().sharingType == makeWindow().sharingType)
        }
    }
    /// `NSWindow.canHide` defaults to YES (AppKit `NSWindow.h`), so cmd+H would
    /// take the wallpaper and the desktop decorations down with the app's UI.
    @Test("Desktop-level windows survive NSApplication.hide")
    func desktopWindowsSurviveApplicationHide() {
        #expect(makeWindow().canHide == false)
        #expect(makeOverlay().canHide == false)
    }

    @Test("Reframing a wallpaper window in the test host keeps it off every display")
    func updateFrameKeepsWindowParked() {
        let window = VideoWallpaperWindow(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        defer { window.close() }
        let target = CGRect(x: 100, y: 50, width: 640, height: 360)

        window.updateFrame(target)
        #expect(TestHostWindowParking.logicalFrame(window) == target)
        #expect(NSScreen.screens.allSatisfy { !$0.frame.intersects(window.frame) })

        let parked = window.frame
        // Every path past the early return resets the level, so it shows whether that return was taken.
        window.level = .normal
        window.updateFrame(target)
        #expect(window.frame == parked)
        #expect(window.level == .normal, "an unchanged frame went through the full reframe")
    }

    @Test("Capture updates reach active and still-retiring video windows",
          .enabled(if: !CaptureSharingTestHost.isAdHocSigned, "Window sharing updates require the project signing environment; ad-hoc hosted execution is not a capture-policy verdict"))
    func policyReachesActiveAndRetiringVideoWindows() throws {
        let screen = try #require(NSScreen.screens.first.map(Screen.init(nsScreen:)))
        let oldWindow = makeWindow()
        let currentWindow = makeWindow()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("capture-routing-\(UUID().uuidString).mov")
        let oldPlayer = WallpaperVideoPlayer(url: url, frame: screen.frame, loadImmediately: false)
        let currentPlayer = WallpaperVideoPlayer(url: url, frame: screen.frame, loadImmediately: false)
        oldPlayer.installPlaybackWindowForTesting(oldWindow)
        currentPlayer.installPlaybackWindowForTesting(currentWindow)
        let oldSession = VideoWallpaperSession(player: oldPlayer)
        let currentSession = VideoWallpaperSession(player: currentPlayer)
        screen.installRuntimeSession(oldSession)
        screen.installRuntimeSession(currentSession)
        defer { screen.resetRuntimeSession() }

        #expect(oldSession.wallpaperWindow == nil)
        #expect(currentSession.wallpaperWindow == nil)
        #expect(screen.activeWallpaperWindow == nil, "The existing non-video UI contract must stay intact")
        #expect(currentPlayer.player == nil)
        for sharing: NSWindow.SharingType in [.none, .readOnly] {
            screen.applyCapturePolicy(sharing)
            #expect(CaptureSharingTestHost.hasWindowServerSharingType(sharing, on: currentWindow))
            #expect(currentPlayer.playbackWindow === currentWindow)
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                #expect(oldPlayer.isCleanedUp)
            } else {
                #expect(!oldPlayer.isCleanedUp)
                #expect(CaptureSharingTestHost.hasWindowServerSharingType(sharing, on: oldWindow))
            }
        }
    }

    @Test("A hidden video uses the latest capture policy when published",
          .enabled(if: !CaptureSharingTestHost.isAdHocSigned, "Window sharing updates require the project signing environment; ad-hoc hosted execution is not a capture-policy verdict"))
    func hiddenVideoReadsPolicyAtPublication() {
        let previous = WallpaperCapturePolicy.allowsScreenCapture
        defer { WallpaperCapturePolicy.allowsScreenCapture = previous }
        WallpaperCapturePolicy.allowsScreenCapture = true
        let window = makeWindow()
        window.orderOut(nil)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("capture-publish-\(UUID().uuidString).mov")
        let player = WallpaperVideoPlayer(url: url, frame: window.frame, startsHidden: true, loadImmediately: false)
        player.installPlaybackWindowForTesting(window)
        let session = VideoWallpaperSession(player: player)
        defer { session.cleanup() }
        #expect(CaptureSharingTestHost.hasWindowServerSharingType(.readOnly, on: window))

        WallpaperCapturePolicy.allowsScreenCapture = false
        session.show()
        #expect(CaptureSharingTestHost.hasWindowServerSharingType(.none, on: window))
        #expect(player.playbackWindow === window)
        WallpaperCapturePolicy.allowsScreenCapture = true
        player.orderWindowBack()
        #expect(CaptureSharingTestHost.hasWindowServerSharingType(.readOnly, on: window))
        #expect(player.playbackWindow === window)
    }

    @Test("Default session capture capability still updates non-video windows",
          .enabled(if: !CaptureSharingTestHost.isAdHocSigned, "Window sharing updates require the project signing environment; ad-hoc hosted execution is not a capture-policy verdict"), arguments: [WallpaperType.html, .scene])
    func defaultCaptureCapabilityReachesWindow(type: WallpaperType) throws {
        let screen = try #require(NSScreen.screens.first.map(Screen.init(nsScreen:)))
        let window = makeWindow()
        let session = CaptureWindowSession(window: window, type: type)
        screen.installRuntimeSession(session)
        defer { screen.resetRuntimeSession() }
        screen.applyCapturePolicy(.none)
        #expect(CaptureSharingTestHost.hasWindowServerSharingType(.none, on: window))
        screen.applyCapturePolicy(.readOnly)
        #expect(CaptureSharingTestHost.hasWindowServerSharingType(.readOnly, on: window))
    }
}

@Suite("Screen-capture setting persistence")
struct WallpaperCaptureSettingTests {
    @Test("A settings blob without the key decodes as visible")
    func legacyBlobDecodesAsVisible() throws {
        let legacy = Data(#"{"showInDock":true}"#.utf8)
        let decoded = try JSONDecoder().decode(GlobalSettings.self, from: legacy)
        #expect(decoded.wallpaperVisibleInScreenCapture)
    }

    @Test("An explicit opt-out survives a round trip")
    func optOutRoundTrips() throws {
        var settings = GlobalSettings()
        settings.wallpaperVisibleInScreenCapture = false
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(GlobalSettings.self, from: data)
        #expect(!decoded.wallpaperVisibleInScreenCapture)
    }
}

@MainActor
private final class CaptureWindowSession: WallpaperRuntimeSession {
    let wallpaperType: WallpaperType
    let wallpaperWindow: NSWindow?
    let videoPlayer: WallpaperVideoPlayer? = nil
    var summary: WallpaperSessionSummary {
        .notConfigured
    }

    init(window: NSWindow, type: WallpaperType) {
        wallpaperWindow = window
        wallpaperType = type
    }

    func show() {}
    func applyPerformanceProfile(_: WallpaperPerformanceProfile) {}
    func updateFrame(to _: CGRect) {}

    func cleanup() {
        wallpaperWindow?.close()
    }

    func prepareForDisplay(timeout _: Duration) async -> WallpaperPreparationResult {
        .ready
    }
}

@Suite("Capture sharing AppKit control",
       .enabled(if: !CaptureSharingTestHost.isAdHocSigned, "Window sharing updates require the project signing environment; ad-hoc hosted execution is not a capture-policy verdict"))
@MainActor
struct CaptureSharingAppKitControlTests {
    @Test("Direct window sharing updates are reversible", arguments: [false, true])
    func directWindowSharingControl(wallpaper: Bool) {
        let window: NSWindow = wallpaper
            ? VideoWallpaperWindow(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
            : NSWindow(contentRect: TestHostWindowParking.parkedFrame(NSRect(x: 0, y: 0, width: 32, height: 32)), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        for sharing: NSWindow.SharingType in [.readOnly, .none, .readOnly] {
            window.sharingType = sharing
            #expect(CaptureSharingTestHost.hasWindowServerSharingType(sharing, on: window))
        }
    }
}

/// Gate only the known ad-hoc host condition: unknown signing information must
/// still run the assertions, so a failed lookup cannot silently waive a regression.
enum CaptureSharingTestHost {
    /// AppKit's getter can remain `.none` after the server has accepted `.readOnly` (also reproduced
    /// in a signed standalone App). Read the actual owned window's server state, never a cached request.
    /// This validates policy delivery, not exclusion from modern ScreenCaptureKit capture.
    @MainActor
    static func hasWindowServerSharingType(_ expected: NSWindow.SharingType, on window: NSWindow) -> Bool {
        let wasVisible = window.isVisible
        if !wasVisible {
            window.orderBack(nil)
        }
        defer {
            if !wasVisible {
                window.orderOut(nil)
            }
        }
        let number = CGWindowID(window.windowNumber)
        let deadline = Date().addingTimeInterval(0.5)
        repeat {
            let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, number) as? [[String: Any]]
            if let row = rows?.first(where: {
                ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == number
                    && ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == ProcessInfo.processInfo.processIdentifier
            }), let state = row[kCGWindowSharingState as String] as? NSNumber,
               state.uintValue == expected.rawValue {
                return true
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        } while Date() < deadline
        return false
    }

    static var isAdHocSigned: Bool {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, [], &information) == errSecSuccess,
              let information = information as? [String: Any],
              let flags = information[kSecCodeInfoFlags as String] as? NSNumber else { return false }
        return SecCodeSignatureFlags(rawValue: flags.uint32Value).contains(.adhoc)
    }
}
