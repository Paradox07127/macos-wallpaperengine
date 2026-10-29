@testable import LiveWallpaperCore
import Testing

@Suite("DestructiveAction overlay copy (Core SPM)")
struct DestructiveActionOverlayCopyTests {
    @Test("Display-wide confirmations list the music overlay by default")
    func defaultCopyListsMusic() {
        #expect(DestructiveAction.clearCurrentWallpaper(displayName: "Studio").message
            .contains("the widget, music, and clock overlays are kept"))
        #expect(DestructiveAction.applyConfigurationToAllDisplays(otherCount: 2).message
            .contains("widget, music, and clock overlays are not changed"))
    }

    @Test("An edition without the music overlay leaves it out of display-wide confirmations")
    func musicFreeCopyOmitsMusic() {
        let clear = DestructiveAction.clearCurrentWallpaper(displayName: "Studio", mentionsMusicOverlay: false).message
        let applyAll = DestructiveAction.applyConfigurationToAllDisplays(otherCount: 2, mentionsMusicOverlay: false).message

        #expect(!clear.localizedCaseInsensitiveContains("music"))
        #expect(clear.contains("the widget and clock overlays are kept"))
        #expect(!applyAll.localizedCaseInsensitiveContains("music"))
        #expect(applyAll.contains("widget and clock overlays are not changed"))
    }

    @Test("A scene-free edition without On Lock leaves it out of the display reset confirmation")
    func onLockFreeResetCopyOmitsOnLock() {
        let withOnLock = DestructiveAction.resetDisplaySettings(displayName: "Studio", sceneCapable: false, mentionsOnLock: true).message
        let withoutOnLock = DestructiveAction.resetDisplaySettings(displayName: "Studio", sceneCapable: false, mentionsOnLock: false).message

        #expect(withOnLock.contains("On Lock"))
        #expect(!withoutOnLock.contains("On Lock"))
        #expect(withoutOnLock.contains("• Turns off shuffle and rotation"))
    }

    @Test("The music flag does not change identity")
    func identityIgnoresMusicFlag() {
        #expect(DestructiveAction.clearCurrentWallpaper(displayName: "Studio", mentionsMusicOverlay: false).id
            == DestructiveAction.clearCurrentWallpaper(displayName: "Studio").id)
    }
}
