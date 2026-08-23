import SwiftUI
import AppKit
import LiveWallpaperCore

struct AppRuntimeOptions: Equatable {
    let isTesting: Bool
    let opensSettingsForUITesting: Bool

    var shouldRestoreSavedWallpapers: Bool { !isTesting }
    var shouldStartAutomation: Bool { !isTesting }
    var shouldShowOnboarding: Bool { !isTesting }
    var shouldOpenSettingsOnLaunch: Bool { opensSettingsForUITesting }

    init(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isXCTestLoaded: Bool = AppRuntimeOptions.isXCTestLoaded()
    ) {
        opensSettingsForUITesting = arguments.contains("--open-settings-for-ui-testing")
            || environment["LIVEWALLPAPER_OPEN_SETTINGS"] == "1"
        isTesting = arguments.contains("--ui-testing")
            || environment["LIVEWALLPAPER_TESTING"] == "1"
            || environment["LIVEWALLPAPER_UI_TESTING"] == "1"
            || environment["XCTestConfigurationFilePath"] != nil
            || environment.keys.contains { $0.localizedCaseInsensitiveContains("XCTest") }
            || isXCTestLoaded
    }

    private static func isXCTestLoaded() -> Bool {
        NSClassFromString("XCTestCase") != nil
            || NSClassFromString("XCTest.XCTestCase") != nil
    }
}

struct AppStartupPlan: Equatable {
    let screenManagerOptions: ScreenManagerStartupOptions
    let showOnboarding: Bool
    let showSettingsOnLaunch: Bool

    init(runtimeOptions: AppRuntimeOptions, onboardingCompleted: Bool) {
        #if LITE_BUILD
        screenManagerOptions = ScreenManagerStartupOptions(
            restoreSavedWallpapers: runtimeOptions.shouldRestoreSavedWallpapers,
            startAutomation: runtimeOptions.shouldStartAutomation,
            memoryPressureWatcher: SystemMemoryPressureWatcher.shared,
            featureCatalog: FeatureCatalog(capabilities: .lite),
            originReconciler: PreservingOriginReconciler()
        )
        #else
        // Build-target-only capabilities are layered on here rather than baked into the shipping Pro catalog because Xcode does not propagate app compilation conditions into local SwiftPM packages.
        let proCapabilities = ProductCapabilities.pro.withWorkshopOnline()
        screenManagerOptions = ScreenManagerStartupOptions(
            restoreSavedWallpapers: runtimeOptions.shouldRestoreSavedWallpapers,
            startAutomation: runtimeOptions.shouldStartAutomation,
            memoryPressureWatcher: SystemMemoryPressureWatcher.shared,
            featureCatalog: FeatureCatalog(capabilities: proCapabilities)
        )
        #endif
        showOnboarding = runtimeOptions.shouldShowOnboarding && !onboardingCompleted
        showSettingsOnLaunch = runtimeOptions.shouldOpenSettingsOnLaunch
    }
}

enum SettingsWindowMetrics {
    static let sidebarColumnWidth = DesignTokens.Sidebar.width
    static let sidebarColumnMaxWidth = DesignTokens.Sidebar.maxWidth
    static let defaultContentSize = CGSize(width: 1180, height: 720)
    // Floor must fit the sidebar plus the shared library-page floor.
    static let minimumContentSize = CGSize(width: 1160, height: DesignTokens.LibraryPage.minHeight)
}

@MainActor
@Observable
final class AppDelegate: NSObject, NSApplicationDelegate {
    var screenManager: ScreenManager?

    @ObservationIgnored private let runtimeOptions = AppRuntimeOptions()
    @ObservationIgnored private var settingsWindowController: NSWindowController?
    /// Lifecycle-probe seam for SettingsWindowLifecycleTests; production code
    /// must not present or mutate through this.
    var settingsWindowControllerForTesting: NSWindowController? { settingsWindowController }
    @ObservationIgnored private var settingsOwnsSystemMonitorLease = false
    @ObservationIgnored private var onboardingWindowController: NSWindowController?
    /// See `WeatherReactiveService.preferenceObserver` — same pattern.
    @ObservationIgnored nonisolated(unsafe) private var dockVisibilityObserver: NSObjectProtocol?
    @ObservationIgnored nonisolated(unsafe) private var showOnboardingObserver: NSObjectProtocol?
    @ObservationIgnored private var globalShortcutManager: GlobalShortcutManager?
    @ObservationIgnored private let lifecycle = ApplicationLifecycleController()
    /// Not private: the menu-bar scene lives in the App struct and injects it too.
    @ObservationIgnored let wallpaperExportService = WallpaperExportService()
    #if !LITE_BUILD
    /// Pro only: lives for the lifetime of the app so the Doctor's probe state survives Settings-window close / re-open and the Workshop tab can read it without re-running probes.
    @ObservationIgnored private let workshopDoctorService = SteamCMDDoctorService()
    /// Owns the Keychain, query service, and disk cache used for Workshop browsing.
    @ObservationIgnored private let workshopServices = WorkshopServices()
    #endif
    func applicationDidFinishLaunching(_ notification: Notification) {
        Logger.notice("Application starting", category: .startup)
        if let hint = LogFileSink.shared.tailCommandHint {
            Logger.notice("Tail the runtime log → \(hint)", category: .startup)
        }

        #if !LITE_BUILD
        // Reclaim WPE package staging dirs orphaned by a prior session's abnormal termination (deinit never ran).
        if !runtimeOptions.isTesting {
            WPEPackageSceneAssetProvider.sweepStaleStagingDirectoriesAtLaunch()
        }
        #endif

        let startupPlan = AppStartupPlan(
            runtimeOptions: runtimeOptions,
            onboardingCompleted: UserDefaults.standard.bool(forKey: "Onboarding.Completed")
        )

        #if !LITE_BUILD
        if !runtimeOptions.isTesting {
            lifecycle.schedule { [weak self] in
                guard let self, self.lifecycle.allowsWork else { return }
                self.completeApplicationStartup(startupPlan)
            }
            return
        }
        #endif
        completeApplicationStartup(startupPlan)
    }

    private func completeApplicationStartup(_ startupPlan: AppStartupPlan) {
        guard lifecycle.allowsWork, screenManager == nil else { return }
        // Wallpaper windows read this in their initializer, so it has to be set
        // before ScreenManager restores the saved wallpapers.
        WallpaperCapturePolicy.allowsScreenCapture =
            SettingsManager.shared.loadGlobalSettings().wallpaperVisibleInScreenCapture
        let manager = ScreenManager(startupOptions: startupPlan.screenManagerOptions)
        screenManager = manager

        if manager.featureCatalog.isEnabled(.html) {
            HTMLWallpaperView.precompileTrackerRules()
        }

        if startupPlan.screenManagerOptions.restoreSavedWallpapers {
            lifecycle.schedule(after: .seconds(1)) { [weak manager] in
                manager?.pruneInvalidConfigurationsIfNeeded()
            }
        }

        #if !LITE_BUILD
        if !runtimeOptions.isTesting, manager.featureCatalog.isEnabled(.wpeImport) {
            lifecycle.schedule(after: .seconds(2)) {
                // Wallpapers are read in place from the Steam library now, so the
                // only disk cache left to sweep is the decoded-video one.
                let keepIDs = WPESceneReachability.referencedWorkshopIDs()
                await WPEVideoTextureDiskCache.shared.collectOrphans(referencedWorkshopIDs: keepIDs)
            }
        }
        #endif

        applyDockVisibility()
        observeDockVisibilityChanges()
        observeShowOnboardingRequests()

        if !runtimeOptions.isTesting,
           manager.featureCatalog.isEnabled(.globalShortcuts) {
            globalShortcutManager = GlobalShortcutManager(screenManager: manager)
            globalShortcutManager?.start()
        }

        if !runtimeOptions.isTesting {
            manager.reconcileMonitorOverlays()
        }

        Logger.notice("Application startup complete", category: .startup)

        if startupPlan.showSettingsOnLaunch {
            Logger.info("Scheduling settings window on launch", category: .startup)
            lifecycle.schedule(after: .milliseconds(150)) { [weak self] in
                self?.showSettings()
            }
        } else if startupPlan.showOnboarding {
            lifecycle.schedule { [weak self] in
                self?.showOnboarding()
            }
        }

        #if !LITE_BUILD
        if !runtimeOptions.isTesting {
            let audioResponseEnabled = SettingsManager.shared.loadGlobalSettings().audioResponseEnabled
            SystemAudioCaptureManager.shared.setEnabled(audioResponseEnabled)
        }

        #endif

        #if !LITE_BUILD
        if !runtimeOptions.isTesting,
           workshopDoctorService.hasBoundBinary,
           workshopDoctorService.workdirBookmarkData != nil {
            lifecycle.schedule(after: .seconds(3)) { [workshopDoctorService] in
                await workshopDoctorService.prepareAtLaunch()
                guard workshopDoctorService.workdirBookmarkData != nil else { return }
                // Opt-in, and only a version read — nothing downloads until the
                // user acts on the result.
                guard UserDefaults.standard.bool(forKey: "loomscreen.workshop.checkAssetsUpdateAtLaunch.v1"),
                      WPEEngineAssetsInstaller.shared.hasManagedInstall else { return }
                WPEEngineAssetsInstaller.shared.checkForUpdate(using: workshopDoctorService)
            }
        }
        #endif

        // Sparkle owns update checking. It runs its own scheduled checks; the
        // gentle-reminder delegate keeps a finding off-screen and lights up the
        // menu bar button instead.
        //
        // Started unconditionally rather than skipped during onboarding: this is
        // the only call site, so skipping it left a first-run session — possibly
        // weeks long — with no checks at all and a disabled manual-check button.
        // Sparkle's own first-launch prompt is pre-answered by
        // SUEnableAutomaticChecks, so there is nothing to collide with.
        if !runtimeOptions.isTesting {
            SparkleUpdaterController.shared.start()
        }
    }

    deinit {
        if let observer = dockVisibilityObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = showOnboardingObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Dock Visibility

    private func applyDockVisibility() {
        guard lifecycle.allowsWork else { return }
        let showInDock = SettingsManager.shared.loadGlobalSettings().showInDock
        let policy: NSApplication.ActivationPolicy = showInDock ? .regular : .accessory
        NSApp.setActivationPolicy(policy)
    }

    private func observeDockVisibilityChanges() {
        guard lifecycle.allowsWork else { return }
        dockVisibilityObserver = NotificationCenter.default.addObserver(
            forName: .dockVisibilityDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.lifecycle.allowsWork else { return }
                self.applyDockVisibility()
            }
        }
    }

    private func observeShowOnboardingRequests() {
        guard lifecycle.allowsWork else { return }
        showOnboardingObserver = NotificationCenter.default.addObserver(
            forName: .showOnboarding,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.lifecycle.allowsWork else { return }
                self.showOnboarding()
            }
        }
    }

    private func removeLifecycleObservers() {
        if let observer = dockVisibilityObserver {
            NotificationCenter.default.removeObserver(observer)
            dockVisibilityObserver = nil
        }
        if let observer = showOnboardingObserver {
            NotificationCenter.default.removeObserver(observer)
            showOnboardingObserver = nil
        }
    }

    private func closeApplicationWindowsForTermination() {
        releaseSettingsSystemMonitorLeaseIfNeeded()
        settingsWindowController?.window?.delegate = nil
        settingsWindowController?.close()
        settingsWindowController = nil
        onboardingWindowController?.window?.delegate = nil
        onboardingWindowController?.close()
        onboardingWindowController = nil
    }

    nonisolated func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    /// Stops renderers and monitor producers before flushing cursor and settings persistence.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        switch lifecycle.beginTermination() {
        case .wait:
            return .terminateLater
        case .terminateNow:
            return .terminateNow
        case .begin:
            break
        }

        globalShortcutManager?.stop()
        globalShortcutManager = nil
        removeLifecycleObservers()
        closeApplicationWindowsForTermination()
        SystemMonitor.shared.shutdown()
        screenManager?.tearDownForTermination()
        #if !LITE_BUILD
        SystemAudioCaptureManager.shared.shutdown()
        #endif

        Task { @MainActor [weak self] in
            let reply = { [weak self] in
                guard let self, self.lifecycle.markReplied() else { return }
                sender.reply(toApplicationShouldTerminate: true)
            }
            let watchdog = Task {
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch is CancellationError {
                    return
                } catch {
                    return
                }
                reply()
            }

            await AppTerminationCoordinator.shutdownForApplication()
            watchdog.cancel()
            reply()
        }
        return .terminateLater
    }

    // MARK: - Settings Window

    func showSettings(
        initialScreenID: CGDirectDisplayID? = nil,
        initialAddWallpaperPromptKind: String? = nil,
        opensGeneralSettings: Bool = false
    ) {
        guard lifecycle.allowsWork, let manager = screenManager else { return }
        Logger.info("Settings window requested", category: .ui)

        if let controller = settingsWindowController {
            presentSettingsWindow(controller)
            Logger.info("Settings window reused", category: .ui)
            postSettingsWindowRequest(
                initialScreenID: initialScreenID,
                initialAddWallpaperPromptKind: initialAddWallpaperPromptKind,
                opensGeneralSettings: opensGeneralSettings
            )
            return
        }

        let initialNavigation: Navigation? = opensGeneralSettings ? .general : initialScreenID.map { .screen($0) }
        let controller = makeSettingsWindowController(
            manager: manager,
            initialNavigation: initialNavigation,
            initialAddWallpaperPromptKind: initialAddWallpaperPromptKind
        )
        settingsWindowController = controller
        presentSettingsWindow(controller)
        Logger.info("Settings window shown", category: .ui)
    }

    private func makeSettingsWindowController(
        manager: ScreenManager,
        initialNavigation: Navigation?,
        initialAddWallpaperPromptKind: String?
    ) -> NSWindowController {
        let baseContentView = ContentView(
            initialNavigation: initialNavigation,
            initialAddWallpaperPromptKind: initialAddWallpaperPromptKind
        )
            .environment(manager)
            .environment(\.featureCatalog, manager.featureCatalog)
            .environment(wallpaperExportService)

        #if !LITE_BUILD
        let contentView = baseContentView
            .environment(workshopDoctorService)
            .environment(workshopServices)
            .appLanguageScoped(defaults: .appScoped())
        #else
        let contentView = baseContentView
            .appLanguageScoped(defaults: .appScoped())
        #endif

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: SettingsWindowMetrics.defaultContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentMinSize = SettingsWindowMetrics.minimumContentSize
        window.title = L10n.Window.settingsTitle
        window.setAccessibilityTitle(L10n.Window.settingsTitle)
        window.setAccessibilityIdentifier("LiveWallpaperSettingsWindow")
        window.sharingType = .readOnly
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = .windowBackgroundColor
        window.isMovableByWindowBackground = false
        // ARC owns the window through the controller; `windowWillClose` drops
        // both so closing destroys the whole hierarchy instead of AppKit
        // double-releasing it.
        window.isReleasedWhenClosed = false
        window.delegate = self
        // The saved frame has to land BEFORE the hosting view goes in. With the
        // old order SwiftUI laid the whole tree out at the 1180pt default and
        // then again at the restored width, which the user sees as everything
        // reflowing the moment the window opens. `center()` is only the
        // first-run fallback — a successful restore replaces it.
        window.setFrameAutosaveName("LiveWallpaperSettingsWindow")
        if !window.setFrameUsingName("LiveWallpaperSettingsWindow") {
            window.center()
        }
        window.contentView = NSHostingView(rootView: contentView)

        return NSWindowController(window: window)
    }

    private func presentSettingsWindow(_ controller: NSWindowController) {
        controller.showWindow(nil)
        guard let window = controller.window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        guard window.isVisible else { return }
        acquireSettingsSystemMonitorLeaseIfNeeded()
    }

    private func acquireSettingsSystemMonitorLeaseIfNeeded() {
        guard !settingsOwnsSystemMonitorLease,
              screenManager?.featureCatalog.isEnabled(.systemMonitor) == true else { return }
        settingsOwnsSystemMonitorLease = true
        SystemMonitor.shared.startMonitoring()
    }

    private func releaseSettingsSystemMonitorLeaseIfNeeded() {
        guard settingsOwnsSystemMonitorLease else { return }
        settingsOwnsSystemMonitorLease = false
        SystemMonitor.shared.stopMonitoring()
    }

    private func postSettingsWindowRequest(
        initialScreenID: CGDirectDisplayID?,
        initialAddWallpaperPromptKind: String?,
        opensGeneralSettings: Bool
    ) {
        lifecycle.schedule { [weak self] in
            guard let self, self.lifecycle.allowsWork else { return }
            if opensGeneralSettings {
                NotificationCenter.default.post(name: .openGeneralSettings, object: nil)
            }
            if let id = initialScreenID {
                NotificationCenter.default.post(
                    name: .selectScreenInSettings,
                    object: nil,
                    userInfo: ["screenID": id]
                )
            }
            if let kind = initialAddWallpaperPromptKind {
                NotificationCenter.default.post(
                    name: .promptAddWallpaper,
                    object: nil,
                    userInfo: ["kind": kind]
                )
            }
        }
    }

    // MARK: - Onboarding Window

    /// Shows the first-run onboarding flow. Also used by the General Settings
    /// "Welcome Tour" tile to re-trigger the tour after first-run.
    func showOnboarding() {
        guard lifecycle.allowsWork else { return }
        Logger.info("Onboarding window requested", category: .ui)

        if let controller = onboardingWindowController {
            Logger.info("Onboarding window reused", category: .ui)
            NSApp.activate(ignoringOtherApps: true)
            controller.window?.makeKeyAndOrderFront(nil)
            controller.window?.orderFrontRegardless()
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 540),
            styleMask: [.titled, .fullSizeContentView, .closable],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = .windowBackgroundColor
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.center()

        let controller = NSWindowController(window: window)
        onboardingWindowController = controller

        let flow = Flow(
            onClose: { [weak self] in
                self?.onboardingWindowController?.close()
            },
            onFinish: { [weak self] screenID in
                guard let self, self.lifecycle.allowsWork else { return }
                self.showSettings(initialScreenID: screenID)
            },
            onShowAppleAerials: { [weak self] in
                guard let self, self.lifecycle.allowsWork else { return }
                self.showSettings()
                self.lifecycle.schedule { [weak self] in
                    guard let self, self.lifecycle.allowsWork else { return }
                    NotificationCenter.default.post(name: .openAppleAerials, object: nil)
                }
            },
            onShowSteamWorkshop: { [weak self] in
                guard let self, self.lifecycle.allowsWork else { return }
                self.showSettings()
                self.lifecycle.schedule { [weak self] in
                    guard let self, self.lifecycle.allowsWork else { return }
                    NotificationCenter.default.post(name: .openWorkshopPane, object: nil)
                }
            }
        )

        if let manager = screenManager {
            let base = flow
                .environment(manager)
                .environment(\.featureCatalog, manager.featureCatalog)
                .environment(wallpaperExportService)
            #if !LITE_BUILD
            window.contentView = NSHostingView(
                rootView: base
                    .environment(workshopDoctorService)
                    .environment(workshopServices)
                    .appLanguageScoped(defaults: .appScoped())
            )
            #else
            window.contentView = NSHostingView(rootView: base.appLanguageScoped(defaults: .appScoped()))
            #endif
        } else {
            Logger.warning("Onboarding shown without ScreenManager — Pro picker will fail to render", category: .ui)
            window.contentView = NSHostingView(rootView: flow.appLanguageScoped(defaults: .appScoped()))
        }

        window.delegate = self

        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        Logger.info("Onboarding window shown", category: .ui)
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender == onboardingWindowController?.window {
            // Closing is an intentional skip. Respect it on future launches;
            // the tour remains available from About.
            UserDefaults.standard.set(true, forKey: "Onboarding.Completed")
        }
        return true
    }

    /// Destroys the settings window on close: a background app must not keep
    /// the whole SwiftUI settings tree (previews, Workshop pages, caches)
    /// resident. Long-running work (Workshop downloads, SteamCMD installs)
    /// lives in app-lifetime services and survives; `showSettings` cold-builds
    /// the next window.
    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow else { return }

        if closingWindow == settingsWindowController?.window {
            releaseSettingsSystemMonitorLeaseIfNeeded()
            closingWindow.delegate = nil
            // Detaching the hosting view before dropping the controller is what
            // deterministically fires SwiftUI `onDisappear` (audio consumer
            // release, preview teardown); a plain dealloc is not guaranteed to.
            closingWindow.contentView = nil
            settingsWindowController = nil
            Logger.info("Settings window destroyed on close", category: .ui)
            return
        }

        if closingWindow == onboardingWindowController?.window {
            onboardingWindowController = nil
            return
        }
    }

    func windowDidMiniaturize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window == settingsWindowController?.window else { return }
        releaseSettingsSystemMonitorLeaseIfNeeded()
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        guard lifecycle.allowsWork,
              let window = notification.object as? NSWindow,
              window == settingsWindowController?.window,
              window.isVisible else { return }
        acquireSettingsSystemMonitorLeaseIfNeeded()
    }
}

@main
struct LiveWallpaperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            menuBarBody
        } label: {
            Image(systemName: menuBarIconName)
        }
        .menuBarExtraStyle(.window)
    }

    @ViewBuilder
    private var menuBarBody: some View {
        if let screenManager = appDelegate.screenManager {
            MenuBarContent(
                openSettings: { [appDelegate] in
                    appDelegate.showSettings(opensGeneralSettings: true)
                },
                openSettingsForScreen: { [appDelegate] id in
                    appDelegate.showSettings(initialScreenID: id)
                },
                openSettingsAndAddWallpaper: { [appDelegate] screenID in
                    appDelegate.showSettings(
                        initialScreenID: screenID,
                        initialAddWallpaperPromptKind: "video"
                    )
                }
            )
            .environment(screenManager)
            .environment(\.featureCatalog, screenManager.featureCatalog)
            .environment(appDelegate.wallpaperExportService)
            .appLanguageScoped(defaults: .appScoped())
        } else {
            Text("Initializing…")
                .appLanguageScoped(defaults: .appScoped())
        }
    }

    private var menuBarIconName: String {
        guard let manager = appDelegate.screenManager else {
            return "photo.on.rectangle"
        }
        switch manager.wallpaperOverviewStatus {
        case .notConfigured:
            return "photo.on.rectangle"
        case .active:
            return manager.hasControllableWallpaperSessions
                ? "play.rectangle.fill"
                : "display.2"
        case .paused:
            return "pause.rectangle.fill"
        case .off:
            return "rectangle.slash"
        case .error:
            return "exclamationmark.triangle.fill"
        }
    }
}
