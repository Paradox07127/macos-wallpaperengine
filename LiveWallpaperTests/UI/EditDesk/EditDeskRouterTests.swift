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
        let router = makeRouter(on: .workshop)
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

    @Test("Add wallpaper notification carries the display it targets and is consumed once")
    func promptAddWallpaper() {
        let router = makeRouter(on: .workshop)
        router.handle(Notification(name: .promptAddWallpaper, userInfo: [
            "kind": "html-folder", "screenID": CGDirectDisplayID(42),
        ]))
        #expect(router.pendingAddWallpaper == .init(kind: "html-folder", targetDisplayID: 42))
        #expect(router.page == .home)
        #expect(router.detailDisplayID == nil)

        router.pendingAddWallpaper = nil
        router.handle(Notification(name: .promptAddWallpaper))
        #expect(router.pendingAddWallpaper == nil)

        router.handle(Notification(name: .promptAddWallpaper, userInfo: ["kind": "any"]))
        #expect(router.pendingAddWallpaper == .init(kind: "any", targetDisplayID: nil))

        // HomePage is mounted on the overview and the library only, so the request must bring it back.
        let away = makeRouter(on: .workshop)
        away.handle(Notification(name: .promptAddWallpaper, userInfo: ["kind": "any", "screenID": CGDirectDisplayID(7)]))
        #expect(away.page == .home)
        #expect(away.pendingAddWallpaper == .init(kind: "any", targetDisplayID: 7))
        let settings = makeRouter(.general)
        settings.handle(Notification(name: .promptAddWallpaper, userInfo: ["kind": "any"]))
        #expect(settings.page == .home)
        for page in [EditDeskRouter.Page.schemes, .systemWallpaper] {
            let router = makeRouter()
            router.select(page)
            router.handle(Notification(name: .promptAddWallpaper, userInfo: ["kind": "any"]))
            #expect(router.page == .home, Comment(rawValue: "the request waits on the \(page) page"))
        }
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
        let router = makeRouter(on: .workshop)
        #expect(!router.onboardingRequested)
        router.handle(Notification(name: .showOnboarding))
        #expect(router.onboardingRequested)
        #expect(router.page == .workshop)
    }

    @Test("No initial navigation opens home and stores the initial prompt")
    func initialHome() {
        let router = EditDeskRouter(
            initialNavigation: nil,
            initialAddWallpaperRequest: .init(kind: "any", targetDisplayID: 42),
            isWorkshopAvailable: { true }
        )
        #expect(router.page == .home)
        #expect(router.detailDisplayID == nil)
        #expect(router.overlayEditorDisplayID == nil)
        #expect(router.settingsSelection == nil)
        #expect(router.settingsSearchText.isEmpty)
        #expect(router.pendingSettingsSearchAnchor == nil)
        #expect(router.pendingAddWallpaper == .init(kind: "any", targetDisplayID: 42))
        #expect(router.pendingFailureID == nil)
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

    @Test("Schemes and System Wallpaper are pages of their own, and before macOS 26 System Wallpaper falls back to the library")
    func schemesAndSystemWallpaperArePages() {
        let router = makeRouter()
        router.select(.schemes)
        #expect(router.page == .schemes)
        router.select(.systemWallpaper)
        #expect(router.page == .systemWallpaper)

        let older = makeRouter(systemWallpaperAvailable: false)
        older.select(.systemWallpaper)
        #expect(older.page == .library)
    }

    @Test("Manage Schemes opens the Schemes page")
    func manageSchemesOpensSchemesPage() throws {
        let host = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Detail/DisplayDetailHost.swift")
        #expect(host.contains("router.select(.schemes)"), "Manage Schemes does not open the Schemes page")
    }

    @Test("Unavailable workshop lands on home for notifications and selection")
    func unavailableWorkshop() {
        let router = EditDeskRouter(
            initialNavigation: nil, initialAddWallpaperRequest: nil, isWorkshopAvailable: { false }
        )
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

    @Test("Detail commands return home and close the display detail")
    func detailCommands() {
        let router = makeRouter(on: .workshop)
        router.showDetail(42)
        #expect(router.page == .home)
        #expect(router.detailDisplayID == 42)
        router.closeDetail()
        #expect(router.detailDisplayID == nil)
    }

    @Test("An onboarding step opens the page its card is on and leaves that page a request, from Settings with a detail open")
    func onboardingStepOpensTheCardsPage() {
        let cases: [(OnboardingProgress.Page, EditDeskRouter.Page, CGDirectDisplayID?, OnboardingProgress.Page?, DetailSection?)] = [
            (.home, .home, nil, .home, nil),
            (.library, .library, nil, .library, nil),
            (.workshop, .workshop, nil, .workshop, nil),
            (.configuration, .home, 7, .configuration, .wallpaper),
            (.overlay, .home, 7, .overlay, .overlay),
            (.settings, .settings, nil, .settings, nil),
        ]
        for (step, page, detailDisplayID, pendingStep, pendingSection) in cases {
            let router = makeRouter(.screen(42))
            router.openSettings(.general)
            router.showOnboardingStep(step, displayID: 7)
            let label = Comment(rawValue: "\(step)")
            #expect(router.page == page, label)
            #expect(router.detailDisplayID == detailDisplayID, label)
            #expect(router.pendingOnboardingStep == pendingStep, label)
            #expect(router.pendingDetailSection == pendingSection, label)
        }
    }

    @Test("A library target lasts while the library page shows and drops a display that disconnects")
    func libraryTargetLifetime() {
        let router = makeRouter()
        router.libraryTarget = 7
        router.select(.library)
        router.select(.library)
        #expect(router.libraryTarget == 7)
        router.select(.home)
        #expect(router.libraryTarget == nil)

        router.libraryTarget = 7
        router.select(.library)
        router.showDetail(7)
        #expect(router.libraryTarget == nil)

        router.libraryTarget = 7
        router.select(.library)
        router.screensRefreshed(availableDisplayIDs: [7])
        #expect(router.libraryTarget == 7)
        router.screensRefreshed(availableDisplayIDs: [])
        #expect(router.libraryTarget == nil)
    }

    @Test("Unknown notifications leave navigation unchanged")
    func unknownNotification() {
        let router = makeRouter(on: .workshop)
        router.handle(Notification(name: Notification.Name("EditDeskRouterTests.unknown")))
        #expect(router.page == .workshop)
        #expect(router.pendingAddWallpaper == nil)
        #expect(!router.onboardingRequested)
    }

    private func makeRouter(
        _ navigation: Navigation? = nil, on page: EditDeskRouter.Page? = nil, systemWallpaperAvailable: Bool = true
    ) -> EditDeskRouter {
        let router = EditDeskRouter(
            initialNavigation: navigation, initialAddWallpaperRequest: nil, isWorkshopAvailable: { true },
            systemWallpaperAvailable: systemWallpaperAvailable
        )
        if let page {
            router.select(page)
        }
        return router
    }
}
