@testable import LiveWallpaperCore
import SwiftUI
import Testing

@Suite("GlobalShortcutAction descriptions (Core SPM)")
struct GlobalShortcutActionDescriptionTests {
    @Test("A build without scenes describes mute and interaction without scenes")
    func sceneFreeDescriptionsOmitScenes() {
        #expect(GlobalShortcutAction.toggleMute.displayDescriptionKey(sceneCapable: false)
            == LocalizedStringKey("Mute or unmute video wallpapers."))
        #expect(GlobalShortcutAction.toggleMouseInteraction.displayDescriptionKey(sceneCapable: false)
            == LocalizedStringKey("Controls mouse interaction on web pages."))
    }

    @Test("A scene-capable build keeps the scene wording, and the property matches it")
    func sceneCapableDescriptionsKeepScenes() {
        #expect(GlobalShortcutAction.toggleMute.displayDescriptionKey(sceneCapable: true)
            == LocalizedStringKey("Mute or unmute video and scene wallpapers."))
        for action in GlobalShortcutAction.allCases {
            #expect(action.displayDescriptionKey == action.displayDescriptionKey(sceneCapable: true))
        }
        #expect(GlobalShortcutAction.togglePlayback.displayDescriptionKey(sceneCapable: false)
            == GlobalShortcutAction.togglePlayback.displayDescriptionKey)
    }
}
