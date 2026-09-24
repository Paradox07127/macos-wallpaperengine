import CoreGraphics
import Foundation
import LiveWallpaperCore
import Observation

@MainActor @Observable
final class EditDeskRouter {
    enum Page: Hashable {
        case home, library, schemes, systemWallpaper, workshop, settings
    }

    enum LibraryFocus: Equatable {
        case aerials
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
    /// A request the library page applies once, through `takeLibraryFocus()`; nil when none is pending.
    var libraryFocus: LibraryFocus?
    /// The display the library page is choosing a wallpaper for; nil when none is preselected.
    var libraryTarget: CGDirectDisplayID?
    var settingsSelection: SettingsNavigation?
    var settingsSearchText = ""
    var pendingSettingsSearchAnchor: SettingsSearchAnchor?
    var pendingAddWallpaper: AddWallpaperRequest?
    var pendingFailureID: UUID?
    var pendingDetailSection: DetailSection?
    var pendingOnboardingStep: OnboardingProgress.Page?
    var onboardingRequested = false
    private(set) var previousPage: Page?
    private let isWorkshopAvailable: () -> Bool
    private let systemWallpaperAvailable: Bool

    /// The System Wallpaper page publishes through the macOS 26 wallpaper extension.
    nonisolated static var systemWallpaperSupported: Bool {
        if #available(macOS 26.0, *) {
            true
        } else {
            false
        }
    }

    init(
        initialNavigation: Navigation?,
        initialAddWallpaperRequest: AddWallpaperRequest?,
        initialOnboardingRequested: Bool = false,
        isWorkshopAvailable: @escaping () -> Bool,
        systemWallpaperAvailable: Bool = EditDeskRouter.systemWallpaperSupported
    ) {
        self.isWorkshopAvailable = isWorkshopAvailable
        self.systemWallpaperAvailable = systemWallpaperAvailable
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
            page = systemWallpaperAvailable ? .systemWallpaper : .library
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
            // Only HomePage consumes it, and HomePage is on the tree for the overview and the library alone.
            if page != .home, page != .library {
                select(.home)
            }
        case .selectScreenInSettings:
            guard let screenID = notification.userInfo?["screenID"] as? CGDirectDisplayID else { return }
            showDetail(screenID, failureID: notification.userInfo?["failureID"] as? UUID)
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
        if let libraryTarget, !availableDisplayIDs.contains(libraryTarget) {
            self.libraryTarget = nil
        }
    }

    func select(_ page: Page) {
        let destination: Page = switch page {
        case .workshop where !isWorkshopAvailable(): .home
        case .systemWallpaper where !systemWallpaperAvailable: .library
        default: page
        }
        if destination != .library {
            libraryTarget = nil
        }
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

    /// `failureID` names the failed load attempt the detail should open on; nil opens the display as it is.
    /// `section` is the section it opens on; nil keeps the one showing.
    func showDetail(_ id: CGDirectDisplayID, failureID: UUID? = nil, section: DetailSection? = nil) {
        select(.home)
        detailDisplayID = id
        pendingFailureID = failureID
        pendingDetailSection = section
    }

    func closeDetail() {
        detailDisplayID = nil
    }

    /// `displayID` is the display whose detail opens for the overlay step.
    func showOnboardingStep(_ step: OnboardingProgress.Page, displayID: CGDirectDisplayID) {
        switch step {
        case .home:
            closeDetail()
            select(.home)
        case .library:
            closeDetail()
            select(.library)
        case .workshop:
            closeDetail()
            select(.workshop)
        case .overlay:
            showDetail(displayID, section: .overlay)
        }
        pendingOnboardingStep = step
    }

    func takeLibraryFocus() -> LibraryFocus? {
        let focus = libraryFocus
        libraryFocus = nil
        return focus
    }
}
