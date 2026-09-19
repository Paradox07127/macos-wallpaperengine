import AppKit
@testable import LiveWallpaper
import LiveWallpaperCore
import SwiftUI
import Testing

@Suite("Edit Desk window host", .serialized)
@MainActor
struct EditDeskWindowHostTests {
    @Test("Edit Desk suppresses startup onboarding", arguments: [false, true], [false, true])
    func startupOnboarding(editDeskEnabled: Bool, onboardingCompleted: Bool) {
        let options = AppRuntimeOptions(arguments: [], environment: [:], isXCTestLoaded: false)
        let plan = AppStartupPlan(
            runtimeOptions: options,
            onboardingCompleted: onboardingCompleted,
            editDeskEnabled: editDeskEnabled
        )

        #expect(plan.showOnboarding == (!editDeskEnabled && !onboardingCompleted))
        #expect(plan.screenManagerOptions.restoreSavedWallpapers)
        #expect(plan.screenManagerOptions.startAutomation)
        #expect(!plan.showSettingsOnLaunch)
    }

    @Test("Testing still suppresses onboarding", arguments: [false, true])
    func onboardingDuringTests(editDeskEnabled: Bool) {
        let options = AppRuntimeOptions(arguments: ["--ui-testing"], environment: [:], isXCTestLoaded: false)
        let plan = AppStartupPlan(
            runtimeOptions: options,
            onboardingCompleted: false,
            editDeskEnabled: editDeskEnabled
        )

        #expect(!plan.showOnboarding)
    }

    @Test("Edit Desk flag defaults off and reads app-scoped defaults")
    func flagUsesAppScopedDefaults() {
        let defaults = UserDefaults.appScoped()
        let previousValue = defaults.object(forKey: EditDeskFlag.key)
        defer { defaults.set(previousValue, forKey: EditDeskFlag.key) }

        #expect(EditDeskFlag.key == "loomscreen.ui.editDesk.v1")
        defaults.removeObject(forKey: EditDeskFlag.key)
        #expect(!EditDeskFlag.isEnabled)
        defaults.set(true, forKey: EditDeskFlag.key)
        #expect(EditDeskFlag.isEnabled)
        defaults.set(false, forKey: EditDeskFlag.key)
        #expect(!EditDeskFlag.isEnabled)
    }

    @Test("Settings window uses the selected layout", arguments: [false, true])
    func windowLayout(editDeskEnabled: Bool) throws {
        let frameName = editDeskEnabled ? "LiveWallpaperEditDeskWindow" : "LiveWallpaperSettingsWindow"
        let frameKey = "NSWindow Frame \(frameName)"
        let defaults = UserDefaults.standard
        let previousFrame = defaults.object(forKey: frameKey)
        defaults.removeObject(forKey: frameKey)
        defer { defaults.set(previousFrame, forKey: frameKey) }

        let manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false,
            startAutomation: false,
            powerMonitor: FakePowerMonitor(),
            fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(),
            displayRegistry: FakeDisplayRegistry(),
            featureCatalog: .unconfigured
        ))
        #if !LITE_BUILD
        let doctor = SteamCMDDoctorService()
        let host = SettingsWindowHost(
            manager: manager,
            wallpaperExportService: WallpaperExportService(),
            workshopDoctorService: doctor,
            workshopServices: WorkshopServices(),
            workshopSetupController: WorkshopSetupController(doctor: doctor)
        )
        #else
        let host = SettingsWindowHost(manager: manager, wallpaperExportService: WallpaperExportService())
        #endif
        let delegate = WindowDelegate()
        let controller = host.makeWindowController(
            editDeskEnabled: editDeskEnabled,
            initialNavigation: nil,
            initialAddWallpaperPromptKind: nil,
            delegate: delegate
        )
        let window = try #require(controller.window)
        defer {
            window.contentView = nil
            window.close()
            manager.tearDownForTermination()
        }

        let expectedSize = editDeskEnabled ? CGSize(width: 1280, height: 820) : CGSize(width: 1180, height: 720)
        let expectedMinimum = editDeskEnabled ? CGSize(width: 1040, height: 700) : SettingsWindowMetrics.minimumContentSize
        #expect(window.contentRect(forFrameRect: window.frame).size == expectedSize)
        #expect(window.contentMinSize == expectedMinimum)
        // Neither host pins an appearance any more: the Edit Desk follows General → Appearance.
        #expect(window.appearance == nil)
        #expect(window.frameAutosaveName == frameName)
        let content = try #require(window.contentView)
        let hostType = String(reflecting: type(of: content))
        #expect(hostType.contains("NSHostingView<"))
        #expect(hostType.contains(editDeskEnabled ? "LiveWallpaper.EditDeskRoot" : "LiveWallpaper.ContentView"))
        #expect(!hostType.contains(editDeskEnabled ? "LiveWallpaper.ContentView" : "LiveWallpaper.EditDeskRoot"))
        #expect(window.delegate === delegate)
        #expect(window.title == L10n.Window.settingsTitle)
        #expect(window.accessibilityIdentifier() == "LiveWallpaperSettingsWindow")
        #expect(window.sharingType == .readOnly)
        #expect(window.titlebarAppearsTransparent)
        #expect(window.titleVisibility == .hidden)
        #expect(!window.isReleasedWhenClosed)
        #expect(!window.isMovableByWindowBackground)
        #expect(window.styleMask == [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView])
    }

    private final class WindowDelegate: NSObject, NSWindowDelegate {}
}
