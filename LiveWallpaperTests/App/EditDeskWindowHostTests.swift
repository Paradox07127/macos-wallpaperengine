import AppKit
@testable import LiveWallpaper
import LiveWallpaperCore
import SwiftUI
import Testing

@Suite("Edit Desk window host", .serialized)
@MainActor
struct EditDeskWindowHostTests {
    @Test("First launch on a build opens the main window")
    func firstLaunchOpensMainWindow() {
        let options = AppRuntimeOptions(arguments: [], environment: [:], isXCTestLoaded: false)
        for recordedBuild in [nil, "41"] as [String?] {
            let plan = AppStartupPlan(
                runtimeOptions: options,
                startupWindowBuild: recordedBuild,
                currentBuild: "42"
            )

            #expect(plan.screenManagerOptions.restoreSavedWallpapers)
            #expect(plan.screenManagerOptions.startAutomation)
            #expect(plan.showSettingsOnLaunch)
            #expect(plan.startupWindowBuildToRecord == "42")
        }
    }

    @Test("Testing opens no window on launch")
    func noWindowDuringTests() {
        let options = AppRuntimeOptions(arguments: ["--ui-testing"], environment: [:], isXCTestLoaded: false)
        let plan = AppStartupPlan(
            runtimeOptions: options,
            startupWindowBuild: nil,
            currentBuild: "42"
        )

        #expect(!plan.showSettingsOnLaunch)
        #expect(plan.startupWindowBuildToRecord == nil)
    }

    @Test("Later launches of the same build open no window")
    func laterLaunchesOpenNothing() {
        let plan = AppStartupPlan(
            runtimeOptions: AppRuntimeOptions(arguments: [], environment: [:], isXCTestLoaded: false),
            startupWindowBuild: "42",
            currentBuild: "42"
        )
        #expect(!plan.showSettingsOnLaunch)
        #expect(plan.startupWindowBuildToRecord == nil)
    }

    @Test("The root consumes cold and warm tour requests once", arguments: [false, true])
    func consumesTourOnce(cold: Bool) throws {
        let suite = "EditDeskWindowHostTests.tour.\(UUID())"
        let legacySuite = "EditDeskWindowHostTests.legacy.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let legacy = try #require(UserDefaults(suiteName: legacySuite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            legacy.removePersistentDomain(forName: legacySuite)
        }
        legacy.set(true, forKey: OnboardingProgress.legacyKey)
        let progress = OnboardingProgress(defaults: defaults, legacyDefaults: legacy, workshopAvailable: true)
        let wallpaper: WallpaperContent = .html(source: .inline("before"), config: .default)
        var inputs = OnboardingSignals.Inputs()
        inputs.wallpapers = { [wallpaper] in [1: wallpaper] }
        let signals = OnboardingSignals(progress: progress, inputs: inputs, notificationCenter: NotificationCenter())
        let router = EditDeskRouter(
            initialNavigation: .general, initialAddWallpaperRequest: nil,
            initialOnboardingRequested: cold, isWorkshopAvailable: { true }
        )
        router.detailDisplayID = 1
        if !cold {
            router.handle(Notification(name: EditDeskRoot.restartOnboardingNotification))
        }
        EditDeskRoot.consumeOnboardingRequest(router: router, progress: progress, signals: signals)
        #expect(progress.handled.isEmpty)
        #expect(router.page == .home)
        #expect(router.detailDisplayID == nil)
        #expect(!router.onboardingRequested)
        progress.record(.home)
        EditDeskRoot.consumeOnboardingRequest(router: router, progress: progress, signals: signals)
        #expect(progress.completed == [.home])
    }

    @Test("Settings window hosts the Edit Desk")
    func windowLayout() throws {
        let frameName = "LiveWallpaperEditDeskWindow"
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
            initialNavigation: nil,
            initialAddWallpaperRequest: nil,
            delegate: delegate
        )
        let window = try #require(controller.window)
        defer {
            window.contentView = nil
            window.close()
            manager.tearDownForTermination()
        }

        #expect(window.contentRect(forFrameRect: window.frame).size == CGSize(width: 1280, height: 820))
        #expect(window.contentMinSize == CGSize(width: 1040, height: 700))
        // The Edit Desk follows General → Appearance rather than pinning one.
        #expect(window.appearance == nil)
        #expect(window.frameAutosaveName == frameName)
        let content = try #require(window.contentView)
        let hostType = String(reflecting: type(of: content))
        #expect(hostType.contains("NSHostingView<"))
        #expect(hostType.contains("LiveWallpaper.EditDeskRoot"))
        #expect(window.delegate === delegate)
        #expect(AppDelegate().windowWillReturnUndoManager(window) is EditDeskMenuUndoManager)
        #expect(window.title == L10n.Window.settingsTitle)
        #expect(window.accessibilityIdentifier() == "LiveWallpaperSettingsWindow")
        #expect(window.sharingType == .readOnly)
        #expect(window.titlebarAppearsTransparent)
        #expect(window.titleVisibility == .hidden)
        #expect(!window.isReleasedWhenClosed)
        #expect(!window.isMovableByWindowBackground)
        #expect(window.styleMask == [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView])
    }

    @Test("A window that does not save its frame opens at the default size and leaves the user's saved frame alone")
    func windowsThatDoNotSaveTheirFrameLeaveTheUserKeyAlone() throws {
        let frameKey = "NSWindow Frame LiveWallpaperEditDeskWindow"
        let savedFrame = UserDefaults.standard.string(forKey: frameKey)
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
            initialNavigation: nil, initialAddWallpaperRequest: nil, savesFrame: false, delegate: delegate
        )
        let window = try #require(controller.window)
        defer {
            window.contentView = nil
            window.close()
            manager.tearDownForTermination()
        }

        // require, not expect: an autosaving window has to stop here, before the move writes the parked frame into the user's key.
        try #require(window.frameAutosaveName.isEmpty)
        #expect(window.contentRect(forFrameRect: window.frame).size == CGSize(width: 1280, height: 820))
        window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        window.close()
        #expect(UserDefaults.standard.string(forKey: frameKey) == savedFrame)
    }

    private final class WindowDelegate: NSObject, NSWindowDelegate {}
}
