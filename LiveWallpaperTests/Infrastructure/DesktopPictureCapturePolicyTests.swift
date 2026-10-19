@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

@Suite("Desktop picture capture policy")
struct DesktopPictureCapturePolicyTests {
    private static func shouldCapture(
        globallyEnabled: Bool = true,
        userPaused: Bool = false,
        suspended: Bool = false,
        userAbsent: Bool = false,
        wallpaperType: WallpaperType = .video,
        setAsLockScreen: Bool = true
    ) -> Bool {
        LockScreenSnapshotCoordinator.shouldCapture(
            globallyEnabled: globallyEnabled,
            userPaused: userPaused,
            suspended: suspended,
            userAbsent: userAbsent,
            wallpaperType: wallpaperType,
            setAsLockScreen: setAsLockScreen
        )
    }

    @Test("A playing video display that opted in is captured")
    func playingOptedInVideoIsCaptured() {
        #expect(Self.shouldCapture())
    }

    @Test("Wallpapers switched off globally are not captured")
    func globalSwitchOffSkips() {
        #expect(!Self.shouldCapture(globallyEnabled: false))
    }

    @Test("A display the user paused is not captured")
    func userPauseSkips() {
        #expect(!Self.shouldCapture(userPaused: true))
    }

    @Test("A display suspended by policy is not captured")
    func policySuspensionSkips() {
        #expect(!Self.shouldCapture(suspended: true))
    }

    @Test("Nothing is captured while the user is away")
    func userAbsenceSkips() {
        #expect(!Self.shouldCapture(userAbsent: true))
    }

    @Test("Displays that did not opt in, or are not showing video, are not captured")
    func configurationGates() {
        #expect(!Self.shouldCapture(setAsLockScreen: false))
        #expect(!Self.shouldCapture(wallpaperType: .scene))
    }
}
