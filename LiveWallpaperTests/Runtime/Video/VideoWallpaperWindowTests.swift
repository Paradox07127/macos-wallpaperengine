import AppKit
@testable import LiveWallpaper
@testable import LiveWallpaperCore
import Security
import Testing

/// The wallpaper window carries every wallpaper type (video, HTML, Metal scene,
/// ambient), so one wrong flag here silently changes behaviour for all of them.
@Suite("Wallpaper window capture policy", .serialized)
@MainActor
struct VideoWallpaperWindowTests {
    private func makeWindow() -> VideoWallpaperWindow {
        VideoWallpaperWindow(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    }

    private func makeOverlay() -> OverlayWindow {
        OverlayWindow(screenFrame: NSRect(x: 0, y: 0, width: 800, height: 600), level: .desktop)
    }

    /// Shipped hard-coded as `.none` until 2026-08-23, which excluded the
    /// wallpaper from every capture — including the user's own screenshots.
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

    /// The Monitor board sits directly above the wallpaper; if the two disagree
    /// a screenshot shows widgets floating over the system desktop picture.
    @Test("The Monitor overlay tracks the wallpaper's capture policy in both directions")
    func overlayMatchesWallpaperCapturePolicy() {
        let restore = WallpaperCapturePolicy.allowsScreenCapture
        defer { WallpaperCapturePolicy.allowsScreenCapture = restore }

        for allowed in [true, false] {
            WallpaperCapturePolicy.allowsScreenCapture = allowed
            #expect(makeOverlay().sharingType == makeWindow().sharingType)
        }
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
        // No AVPlayer is installed, matching the owner shape during deep sleep.
        #expect(currentPlayer.player == nil)
        for sharing: NSWindow.SharingType in [.none, .readOnly] {
            screen.applyCapturePolicy(sharing)
            #expect(currentWindow.sharingType == sharing)
            #expect(currentPlayer.playbackWindow === currentWindow)
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                #expect(oldPlayer.isCleanedUp)
            } else {
                #expect(!oldPlayer.isCleanedUp)
                #expect(oldWindow.sharingType == sharing)
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
        #expect(window.sharingType == .readOnly)

        WallpaperCapturePolicy.allowsScreenCapture = false
        session.show()
        #expect(window.sharingType == .none)
        #expect(player.playbackWindow === window)
        WallpaperCapturePolicy.allowsScreenCapture = true
        player.orderWindowBack() // Retry publishes through the same player entry point.
        #expect(window.sharingType == .readOnly)
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
        #expect(window.sharingType == .none)
        screen.applyCapturePolicy(.readOnly)
        #expect(window.sharingType == .readOnly)
    }
}

@Suite("Screen-capture setting persistence")
struct WallpaperCaptureSettingTests {
    /// Installs predating the key inherit the new default (visible), which is
    /// deliberately the opposite of the behaviour they shipped with.
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
            : NSWindow(contentRect: NSRect(x: 0, y: 0, width: 32, height: 32), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        for sharing: NSWindow.SharingType in [.readOnly, .none, .readOnly] {
            window.sharingType = sharing
            #expect(window.sharingType == sharing)
        }
    }
}

/// Measured with the same test code: the ad-hoc host accepts `.none` but
/// cannot restore `.readOnly`; project signing passes both directions.
/// Gate only this known host condition. Unknown signing information must
/// run the assertions, so a failed lookup cannot silently waive a regression.
private enum CaptureSharingTestHost {
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
