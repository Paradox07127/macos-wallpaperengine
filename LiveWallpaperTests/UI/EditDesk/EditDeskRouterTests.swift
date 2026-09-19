import CoreGraphics
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

@MainActor
@Suite("Edit Desk router")
struct EditDeskRouterTests {
    @Test("General settings notification opens general and clears the search")
    func openGeneralSettings() {
        let router = makeRouter(.bookmarks)
        router.settingsSearchText = "volume"
        router.pendingSettingsSearchAnchor = .displayDefaultsVideo
        router.handle(Notification(name: .openGeneralSettings))
        #expect(router.page == .settings)
        #expect(router.settingsSelection == .general)
        #expect(router.settingsSearchText.isEmpty)
        #expect(router.pendingSettingsSearchAnchor == nil)
    }

    @Test("Settings section notification decodes destination and optional anchor")
    func openSettingsSection() {
        let router = makeRouter()
        router.handle(Notification(name: .openSettingsSection, userInfo: [
            "destination": "displayDefaults", "anchor": "displayDefaultsVideo",
        ]))
        #expect(router.page == .settings)
        #expect(router.settingsSelection == .displayDefaults)
        #expect(router.pendingSettingsSearchAnchor == .displayDefaultsVideo)

        router.handle(Notification(name: .openSettingsSection, userInfo: ["destination": "about"]))
        #expect(router.settingsSelection == .about)
        #expect(router.pendingSettingsSearchAnchor == nil)
        router.handle(Notification(name: .openSettingsSection, userInfo: ["destination": "invalid"]))
        #expect(router.settingsSelection == .about)
    }

    @Test("Workshop notification opens the available workshop")
    func openWorkshopPane() {
        let router = makeRouter(.general)
        router.handle(Notification(name: .openWorkshopPane))
        #expect(router.page == .workshop)
    }

    @Test("Apple Aerials notification selects the library aerials segment")
    func openAppleAerials() {
        let router = makeRouter(.general)
        router.handle(Notification(name: .openAppleAerials))
        #expect(router.page == .library)
        #expect(router.libraryFocus == .aerials)
    }

    @Test("Add wallpaper notification stores the kind without navigating")
    func promptAddWallpaper() {
        let router = makeRouter(.bookmarks)
        router.handle(Notification(name: .promptAddWallpaper, userInfo: ["kind": "html-folder"]))
        #expect(router.pendingAddWallpaperKind == "html-folder")
        #expect(router.page == .library)
        router.handle(Notification(name: .promptAddWallpaper))
        #expect(router.pendingAddWallpaperKind == "html-folder")
    }

    @Test("Screen selection notification opens detail with an optional failure")
    func selectScreenInSettings() {
        let router = makeRouter(.general)
        let failureID = UUID()
        router.handle(Notification(name: .selectScreenInSettings, userInfo: [
            "screenID": CGDirectDisplayID(42), "failureID": failureID,
        ]))
        #expect(router.page == .home)
        #expect(router.detailDisplayID == 42)
        #expect(router.pendingFailureID == failureID)

        router.handle(Notification(name: .selectScreenInSettings, userInfo: ["screenID": CGDirectDisplayID(7)]))
        #expect(router.detailDisplayID == 7)
        #expect(router.pendingFailureID == nil)
        router.handle(Notification(name: .selectScreenInSettings))
        #expect(router.detailDisplayID == 7)
    }

    @Test("Onboarding notification stores the request without navigating")
    func showOnboarding() {
        let router = makeRouter(.bookmarks)
        #expect(!router.onboardingRequested)
        router.handle(Notification(name: .showOnboarding))
        #expect(router.onboardingRequested)
        #expect(router.page == .library)
    }

    @Test("No initial navigation opens home and stores the initial prompt")
    func initialHome() {
        let router = EditDeskRouter(
            initialNavigation: nil, initialAddWallpaperPromptKind: "video", isWorkshopAvailable: { true }
        )
        #expect(router.page == .home)
        #expect(router.detailDisplayID == nil)
        #expect(router.overlayEditorDisplayID == nil)
        #expect(router.libraryFocus == .wallpapers)
        #expect(router.settingsSelection == nil)
        #expect(router.settingsSearchText.isEmpty)
        #expect(router.pendingSettingsSearchAnchor == nil)
        #expect(router.pendingAddWallpaperKind == "video")
        #expect(router.pendingFailureID == nil)
        #expect(router.previousPage == nil)
    }

    @Test("Initial general navigation opens general settings")
    func initialGeneral() {
        let router = makeRouter(.general)
        #expect(router.page == .settings)
        #expect(router.settingsSelection == .general)
    }

    @Test("Initial screen navigation opens home detail")
    func initialScreen() {
        let router = makeRouter(.screen(42))
        #expect(router.page == .home)
        #expect(router.detailDisplayID == 42)
    }

    @Test("Initial aerials navigation opens library aerials")
    func initialAppleAerials() {
        let router = makeRouter(.appleAerials)
        #expect(router.page == .library)
        #expect(router.libraryFocus == .aerials)
    }

    @Test("Initial bookmarks navigation opens library wallpapers")
    func initialBookmarks() {
        let router = makeRouter(.bookmarks)
        #expect(router.page == .library)
        #expect(router.libraryFocus == .wallpapers)
    }

    @Test("Initial system wallpaper navigation opens its library segment")
    func initialSystemWallpaper() {
        let router = makeRouter(.systemWallpaper)
        #expect(router.page == .library)
        #expect(router.libraryFocus == .systemWallpaper)
    }

    @Test("Initial workshop navigation opens the available workshop")
    func initialWorkshop() {
        let router = makeRouter(.workshop)
        #expect(router.page == .workshop)
    }

    @Test("Unavailable workshop lands on home for initial navigation, notifications and selection")
    func unavailableWorkshop() {
        let router = EditDeskRouter(
            initialNavigation: .workshop, initialAddWallpaperPromptKind: nil, isWorkshopAvailable: { false }
        )
        #expect(router.page == .home)
        router.select(.library)
        router.handle(Notification(name: .openWorkshopPane))
        #expect(router.page == .home)
        router.select(.library)
        router.select(.workshop)
        #expect(router.page == .home)
    }

    @Test("Screen refresh clears vanished detail and editor displays while preserving present ones")
    func screensRefreshed() {
        let router = makeRouter(.screen(42))
        router.overlayEditorDisplayID = 7
        router.screensRefreshed(availableDisplayIDs: [42])
        #expect(router.detailDisplayID == 42)
        #expect(router.overlayEditorDisplayID == nil)

        router.overlayEditorDisplayID = 7
        router.screensRefreshed(availableDisplayIDs: [7])
        #expect(router.detailDisplayID == nil)
        #expect(router.overlayEditorDisplayID == 7)
        router.screensRefreshed(availableDisplayIDs: [])
        #expect(router.overlayEditorDisplayID == nil)
    }

    @Test("Settings back preserves the origin across settings destinations and defaults to home")
    func backFromSettings() {
        let router = makeRouter(.bookmarks)
        router.openSettings(.general)
        #expect(router.previousPage == .library)
        router.openSettings(.displayDefaults, anchor: .displayDefaultsVideo)
        #expect(router.previousPage == .library)
        #expect(router.pendingSettingsSearchAnchor == .displayDefaultsVideo)
        router.backFromSettings()
        #expect(router.page == .library)

        let initialSettings = makeRouter(.general)
        initialSettings.backFromSettings()
        #expect(initialSettings.page == .home)
    }

    @Test("Detail commands return home and close the display detail")
    func detailCommands() {
        let router = makeRouter(.bookmarks)
        router.showDetail(42)
        #expect(router.page == .home)
        #expect(router.detailDisplayID == 42)
        router.closeDetail()
        #expect(router.detailDisplayID == nil)
    }

    @Test("Unknown notifications leave navigation unchanged")
    func unknownNotification() {
        let router = makeRouter(.bookmarks)
        router.handle(Notification(name: Notification.Name("EditDeskRouterTests.unknown")))
        #expect(router.page == .library)
        #expect(router.previousPage == nil)
        #expect(router.pendingAddWallpaperKind == nil)
        #expect(!router.onboardingRequested)
    }

    private func makeRouter(_ navigation: Navigation? = nil) -> EditDeskRouter {
        EditDeskRouter(
            initialNavigation: navigation, initialAddWallpaperPromptKind: nil, isWorkshopAvailable: { true }
        )
    }
}
