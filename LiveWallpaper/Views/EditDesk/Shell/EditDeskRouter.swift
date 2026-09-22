import CoreGraphics
import Foundation
import LiveWallpaperCore
import Observation

@MainActor @Observable
final class EditDeskRouter {
    enum Page: Hashable {
        case home, library, workshop, settings
    }

    enum LibraryFocus: Equatable {
        case wallpapers, schemes, systemWallpaper, aerials
    }

    /// What to import and which display it lands on, in one value: as two notifications the target
    /// could arrive after the prompt had already picked a display.
    struct AddWallpaperRequest: Hashable {
        let kind: String
        let targetDisplayID: CGDirectDisplayID?
    }

    var page: Page = .home
    var detailDisplayID: CGDirectDisplayID?
    var overlayEditorDisplayID: CGDirectDisplayID?
    var libraryFocus: LibraryFocus = .wallpapers
    var settingsSelection: SettingsNavigation?
    var settingsSearchText = ""
    var pendingSettingsSearchAnchor: SettingsSearchAnchor?
    var pendingAddWallpaper: AddWallpaperRequest?
    var pendingFailureID: UUID?
    var onboardingRequested = false
    private(set) var previousPage: Page?
    private let isWorkshopAvailable: () -> Bool

    init(
        initialNavigation: Navigation?,
        initialAddWallpaperRequest: AddWallpaperRequest?,
        initialOnboardingRequested: Bool = false,
        isWorkshopAvailable: @escaping () -> Bool
    ) {
        self.isWorkshopAvailable = isWorkshopAvailable
        pendingAddWallpaper = initialAddWallpaperRequest
        onboardingRequested = initialOnboardingRequested
        switch initialNavigation {
        case .general:
            page = .settings
            settingsSelection = .general
        case let .screen(id):
            detailDisplayID = id
        case .appleAerials:
            page = .library
            libraryFocus = .aerials
        case .bookmarks:
            page = .library
        case .systemWallpaper:
            page = .library
            libraryFocus = .systemWallpaper
        case .workshop:
            page = isWorkshopAvailable() ? .workshop : .home
        case nil:
            break
        }
    }

    func handle(_ notification: Notification) {
        switch notification.name {
        case .openGeneralSettings:
            openSettings(.general)
        case .openSettingsSection:
            guard let raw = notification.userInfo?["destination"] as? String,
                  let destination = SettingsNavigation(rawValue: raw) else { return }
            let anchor = (notification.userInfo?["anchor"] as? String)
                .flatMap(SettingsSearchAnchor.init(rawValue:))
            openSettings(destination, anchor: anchor)
        case .openWorkshopPane:
            select(.workshop)
        case .openAppleAerials:
            select(.library)
            libraryFocus = .aerials
        case .promptAddWallpaper:
            guard let kind = notification.userInfo?["kind"] as? String else { return }
            pendingAddWallpaper = AddWallpaperRequest(
                kind: kind, targetDisplayID: notification.userInfo?["screenID"] as? CGDirectDisplayID
            )
            // Only HomePage consumes it, and HomePage is off the tree on these two pages.
            if page == .workshop || page == .settings {
                select(.home)
            }
        case .selectScreenInSettings:
            guard let screenID = notification.userInfo?["screenID"] as? CGDirectDisplayID else { return }
            showDetail(screenID)
            pendingFailureID = notification.userInfo?["failureID"] as? UUID
        case .showOnboarding, EditDeskRoot.restartOnboardingNotification:
            onboardingRequested = true
        default:
            break
        }
    }

    func screensRefreshed(availableDisplayIDs: [CGDirectDisplayID]) {
        if let detailDisplayID, !availableDisplayIDs.contains(detailDisplayID) {
            self.detailDisplayID = nil
        }
        if let overlayEditorDisplayID, !availableDisplayIDs.contains(overlayEditorDisplayID) {
            self.overlayEditorDisplayID = nil
        }
    }

    func select(_ page: Page) {
        let destination = page == .workshop && !isWorkshopAvailable() ? .home : page
        guard destination != self.page else { return }
        previousPage = self.page
        self.page = destination
    }

    func openSettings(_ destination: SettingsNavigation, anchor: SettingsSearchAnchor? = nil) {
        select(.settings)
        settingsSelection = destination
        settingsSearchText = ""
        pendingSettingsSearchAnchor = anchor
    }

    func backFromSettings() {
        select(previousPage ?? .home)
    }

    func showDetail(_ id: CGDirectDisplayID) {
        select(.home)
        detailDisplayID = id
    }

    func closeDetail() {
        detailDisplayID = nil
    }
}
