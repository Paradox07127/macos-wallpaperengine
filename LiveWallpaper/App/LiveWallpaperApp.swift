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
    /// CFBundleVersion of the last launch that opened a window on its own; absent until the first launch.
    static let startupWindowBuildKey = "loomscreen.startupWindowBuild.v1"

    let screenManagerOptions: ScreenManagerStartupOptions
    let showOnboarding: Bool
    let showSettingsOnLaunch: Bool
    let startupWindowBuildToRecord: String?

    init(
        runtimeOptions: AppRuntimeOptions,
        onboardingCompleted: Bool,
        startupWindowBuild: String? = nil,
        currentBuild: String? = nil,
        editDeskEnabled: Bool = false
    ) {
        #if LITE_BUILD
        screenManagerOptions = ScreenManagerStartupOptions(
            restoreSavedWallpapers: runtimeOptions.shouldRestoreSavedWallpapers,
            startAutomation: runtimeOptions.shouldStartAutomation,
            memoryPressureWatcher: SystemMemoryPressureWatcher.shared,
            featureCatalog: FeatureCatalog(capabilities: .lite),
            originReconciler: PreservingOriginReconciler()
        )
        #else
        let proCapabilities = ProductCapabilities.pro.withWorkshopOnline()
        screenManagerOptions = ScreenManagerStartupOptions(
            restoreSavedWallpapers: runtimeOptions.shouldRestoreSavedWallpapers,
            startAutomation: runtimeOptions.shouldStartAutomation,
            memoryPressureWatcher: SystemMemoryPressureWatcher.shared,
            featureCatalog: FeatureCatalog(capabilities: proCapabilities)
        )
        #endif
        let opensStartupWindow = runtimeOptions.shouldShowOnboarding && startupWindowBuild != currentBuild
        showOnboarding = opensStartupWindow && !onboardingCompleted && !editDeskEnabled
        showSettingsOnLaunch = runtimeOptions.shouldOpenSettingsOnLaunch
            || (opensStartupWindow && (editDeskEnabled || onboardingCompleted))
        startupWindowBuildToRecord = opensStartupWindow ? currentBuild : nil
    }
}

enum SettingsWindowMetrics {
    static let sidebarColumnWidth = DesignTokens.Sidebar.width
    static let sidebarColumnMaxWidth = DesignTokens.Sidebar.maxWidth
    static let defaultContentSize = CGSize(width: 1180, height: 720)
    static let editDeskDefaultContentSize = CGSize(width: 1280, height: 820)
    static let editDeskMinimumContentSize = CGSize(width: 1040, height: 700)
    // Floor must fit the sidebar plus the shared library-page floor.
    static let minimumContentSize = CGSize(width: 1160, height: DesignTokens.LibraryPage.minHeight)
}

@MainActor
struct SettingsWindowHost {
    let manager: ScreenManager
    let wallpaperExportService: WallpaperExportService
    #if !LITE_BUILD
    let workshopDoctorService: SteamCMDDoctorService
    let workshopServices: WorkshopServices
    let workshopSetupController: WorkshopSetupController
    #endif

    func makeWindowController(
        editDeskEnabled: Bool,
        initialNavigation: Navigation?,
        initialAddWallpaperRequest: EditDeskRouter.AddWallpaperRequest?,
        initialOnboardingRequested: Bool = false,
        delegate: any NSWindowDelegate
    ) -> NSWindowController {
        let contentSize = editDeskEnabled
            ? SettingsWindowMetrics.editDeskDefaultContentSize : SettingsWindowMetrics.defaultContentSize
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentMinSize = editDeskEnabled
            ? SettingsWindowMetrics.editDeskMinimumContentSize : SettingsWindowMetrics.minimumContentSize
        window.title = L10n.Window.settingsTitle
        window.setAccessibilityTitle(L10n.Window.settingsTitle)
        window.setAccessibilityIdentifier("LiveWallpaperSettingsWindow")
        window.sharingType = .readOnly
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = editDeskEnabled ? .clear : .windowBackgroundColor
        // Non-opaque unconditionally: the Edit Desk decides per preference whether to paint a flat
        // canvas or let `.behindWindow` blur through, and flipping this on a live window is fiddly.
        window.isOpaque = !editDeskEnabled
        window.isMovableByWindowBackground = false
        if editDeskEnabled {
            let toolbar = NSToolbar(identifier: "LoomscreenEditDeskToolbar")
            toolbar.showsBaselineSeparator = false
            window.toolbar = toolbar
            window.toolbarStyle = .unified
        }
        // ARC owns the window through the controller; windowWillClose drops both so closing destroys the whole hierarchy instead of AppKit double-releasing it.
        window.isReleasedWhenClosed = false
        window.delegate = delegate
        // The saved frame has to land BEFORE the hosting view goes in.
        // center() is only the first-run fallback — a successful restore replaces it.
        let frameName = editDeskEnabled ? "LiveWallpaperEditDeskWindow" : "LiveWallpaperSettingsWindow"
        window.setFrameAutosaveName(frameName)
        if !window.setFrameUsingName(frameName) {
            window.center()
        }
        if editDeskEnabled {
            window.contentView = hostingView(EditDeskRoot(
                initialNavigation: initialNavigation,
                initialAddWallpaperRequest: initialAddWallpaperRequest,
                initialOnboardingRequested: initialOnboardingRequested
            ))
        } else {
            window.contentView = hostingView(ContentView(
                initialNavigation: initialNavigation,
                initialAddWallpaperPromptKind: initialAddWallpaperRequest?.kind
            ))
        }

        return NSWindowController(window: window)
    }

    private func hostingView(_ root: some View) -> NSView {
        let baseContentView = root
            .environment(manager)
            .environment(\.featureCatalog, manager.featureCatalog)
            .environment(wallpaperExportService)

        #if !LITE_BUILD
        let contentView = baseContentView
            .environment(workshopDoctorService)
            .environment(workshopServices)
            .environment(workshopSetupController)
            .appLanguageScoped(defaults: .appScoped())
        #else
        let contentView = baseContentView
            .appLanguageScoped(defaults: .appScoped())
        #endif
        return NSHostingView(rootView: contentView)
    }
}

@MainActor
@Observable
final class AppDelegate: NSObject, NSApplicationDelegate {
    var screenManager: ScreenManager?

    @ObservationIgnored private let runtimeOptions = AppRuntimeOptions()
    @ObservationIgnored private var settingsWindowController: NSWindowController?
    var settingsWindowControllerForTesting: NSWindowController? { settingsWindowController }
    @ObservationIgnored private var settingsOwnsSystemMonitorLease = false
    @ObservationIgnored private var onboardingWindowController: NSWindowController?
    @ObservationIgnored private var hasPendingReopen = false
    @ObservationIgnored nonisolated(unsafe) private var dockVisibilityObserver: NSObjectProtocol?
    @ObservationIgnored nonisolated(unsafe) private var showOnboardingObserver: NSObjectProtocol?
    @ObservationIgnored private var globalShortcutManager: GlobalShortcutManager?
    @ObservationIgnored private let lifecycle = ApplicationLifecycleController()
    @ObservationIgnored let wallpaperExportService = WallpaperExportService()
    #if !LITE_BUILD
    @ObservationIgnored private let workshopDoctorService = SteamCMDDoctorService()
    @ObservationIgnored private let workshopServices = WorkshopServices()
    @ObservationIgnored private lazy var workshopSetupController = WorkshopSetupController(doctor: workshopDoctorService)
    #endif
    func applicationDidFinishLaunching(_ notification: Notification) {
        Logger.notice("Application starting — \(SystemSnapshot.launchBanner)", category: .startup)

        AppAppearance.stored(in: .appScoped()).apply()
        if let hint = LogFileSink.shared.tailCommandHint {
            Logger.notice("Tail the runtime log → \(hint)", category: .startup)
        }

        let startupPlan = AppStartupPlan(
            runtimeOptions: runtimeOptions,
            onboardingCompleted: UserDefaults.standard.bool(forKey: "Onboarding.Completed"),
            startupWindowBuild: UserDefaults.appScoped().string(forKey: AppStartupPlan.startupWindowBuildKey),
            currentBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            editDeskEnabled: EditDeskFlag.isEnabled
        )

        if !runtimeOptions.isTesting {
            wallpaperExportService.declareBundledProvider()
            wallpaperExportService.startObservingSharedRoot()
        }

        #if !LITE_BUILD
        if !runtimeOptions.isTesting {
            lifecycle.schedule { [weak self] in
                guard let self, self.lifecycle.allowsWork else { return }
                // Reclaim package staging dirs before ScreenManager can restore
                // a scene and create a live provider with the same prefix.
                await WPEPackageSceneAssetProvider.sweepStaleStagingDirectoriesAtLaunch()
                guard lifecycle.allowsWork else { return }
                completeApplicationStartup(startupPlan)
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
                let keepIDs = WPESceneReachability.referencedWorkshopIDs()
                await WPEVideoTextureDiskCache.shared.collectOrphans(referencedWorkshopIDs: keepIDs)
            }
        }
        #endif

        applyDockVisibility()
        observeDockVisibilityChanges()
        observeShowOnboardingRequests()

        #if DEBUG
        QAControlPlane.startIfEnabled(screenManager: manager)
        #endif

        if !runtimeOptions.isTesting,
           manager.featureCatalog.isEnabled(.globalShortcuts) {
            globalShortcutManager = GlobalShortcutManager(
                screenManager: manager,
                onOpenSettings: { [weak self] in
                    self?.showSettings(opensGeneralSettings: true)
                }
            )
            globalShortcutManager?.start()
        }

        if !runtimeOptions.isTesting {
            manager.reconcileMonitorOverlays()
        }

        Logger.notice("Application startup complete", category: .startup)

        if let build = startupPlan.startupWindowBuildToRecord {
            UserDefaults.appScoped().set(build, forKey: AppStartupPlan.startupWindowBuildKey)
        }
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
        consumePendingReopen(showSettingsOnLaunch: startupPlan.showSettingsOnLaunch, showOnboarding: startupPlan.showOnboarding)

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
                guard UserDefaults.standard.bool(forKey: "loomscreen.workshop.checkAssetsUpdateAtLaunch.v1"),
                      WPEEngineAssetsInstaller.shared.hasManagedInstall else { return }
                WPEEngineAssetsInstaller.shared.checkForUpdate(using: workshopDoctorService)
            }
        }
        #endif

        if !runtimeOptions.isTesting {
            SparkleUpdaterController.shared.start()
        }
        #if DEBUG
        if runtimeOptions.isTesting, ProcessInfo.processInfo.arguments.contains("--nixie-overlay-preview") {
            NixieOverlayPreview.present()
        }
        #endif
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
                if EditDeskFlag.isEnabled {
                    self.showSettings(restartsOnboarding: true)
                } else {
                    self.showOnboarding()
                }
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

    /// Not gated on the visible-windows flag: whether the status item's window counts toward it is undocumented, so gating could swallow every reopen; re-fronting is harmless.
    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows _: Bool) -> Bool {
        if onboardingWindowController != nil {
            showOnboarding()
        } else if screenManager == nil {
            // showSettings() is a silent no-op until startup assigns screenManager, and AppKit won't resend this reopen.
            hasPendingReopen = true
        } else {
            showSettings()
        }
        return false
    }

    func consumePendingReopen(showSettingsOnLaunch: Bool, showOnboarding: Bool) {
        guard hasPendingReopen else { return }
        hasPendingReopen = false
        guard !showSettingsOnLaunch, !showOnboarding else { return }
        showSettings()
    }

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
        #if DEBUG
        QAControlPlane.shutdown()
        #endif
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

            #if !LITE_BUILD
            // A SteamCMD child outlives this process otherwise: it sits in its own process group inside an XPC service launchd reaps with SIGKILL.
            async let steamCMDTerminated: Void = SteamConnectorClient.terminateActiveSteamCMDForHostExit()
            #endif
            await AppTerminationCoordinator.shutdownForApplication()
            #if !LITE_BUILD
            await steamCMDTerminated
            #endif
            watchdog.cancel()
            reply()
        }
        return .terminateLater
    }

    // MARK: - Settings Window

    func showSettings(
        initialScreenID: CGDirectDisplayID? = nil,
        initialAddWallpaperRequest: EditDeskRouter.AddWallpaperRequest? = nil,
        opensGeneralSettings: Bool = false,
        restartsOnboarding: Bool = false
    ) {
        guard lifecycle.allowsWork, let manager = screenManager else { return }
        Logger.info("Settings window requested", category: .ui)

        if let controller = settingsWindowController {
            presentSettingsWindow(controller)
            Logger.info("Settings window reused", category: .ui)
            postSettingsWindowRequest(
                initialScreenID: initialScreenID,
                initialAddWallpaperRequest: initialAddWallpaperRequest,
                opensGeneralSettings: opensGeneralSettings,
                restartsOnboarding: restartsOnboarding
            )
            return
        }

        let initialNavigation: Navigation? = opensGeneralSettings ? .general : initialScreenID.map { .screen($0) }
        let controller = makeSettingsWindowController(
            manager: manager,
            initialNavigation: initialNavigation,
            initialAddWallpaperRequest: initialAddWallpaperRequest,
            initialOnboardingRequested: restartsOnboarding
        )
        settingsWindowController = controller
        presentSettingsWindow(controller)
        Logger.info("Settings window shown", category: .ui)
    }

    private func makeSettingsWindowController(
        manager: ScreenManager,
        initialNavigation: Navigation?,
        initialAddWallpaperRequest: EditDeskRouter.AddWallpaperRequest?,
        initialOnboardingRequested: Bool
    ) -> NSWindowController {
        #if !LITE_BUILD
        let host = SettingsWindowHost(
            manager: manager,
            wallpaperExportService: wallpaperExportService,
            workshopDoctorService: workshopDoctorService,
            workshopServices: workshopServices,
            workshopSetupController: workshopSetupController
        )
        #else
        let host = SettingsWindowHost(manager: manager, wallpaperExportService: wallpaperExportService)
        #endif
        return host.makeWindowController(
            editDeskEnabled: EditDeskFlag.isEnabled,
            initialNavigation: initialNavigation,
            initialAddWallpaperRequest: initialAddWallpaperRequest,
            initialOnboardingRequested: initialOnboardingRequested,
            delegate: self
        )
    }

    private func presentSettingsWindow(_ controller: NSWindowController) {
        controller.showWindow(nil)
        guard let window = controller.window else { return }
        LocalImageCacheReclaimer.shared.windowDidOpen(window)
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
        initialAddWallpaperRequest: EditDeskRouter.AddWallpaperRequest?,
        opensGeneralSettings: Bool,
        restartsOnboarding: Bool
    ) {
        lifecycle.schedule { [weak self] in
            guard let self, self.lifecycle.allowsWork else { return }
            if restartsOnboarding {
                NotificationCenter.default.post(name: EditDeskRoot.restartOnboardingNotification, object: nil)
            }
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
            if let request = initialAddWallpaperRequest {
                var userInfo: [String: Any] = ["kind": request.kind]
                if let targetDisplayID = request.targetDisplayID {
                    userInfo["screenID"] = targetDisplayID
                }
                NotificationCenter.default.post(name: .promptAddWallpaper, object: nil, userInfo: userInfo)
            }
        }
    }

    // MARK: - Onboarding Window

    func showOnboarding() {
        guard lifecycle.allowsWork else { return }
        Logger.info("Onboarding window requested", category: .ui)

        if let controller = onboardingWindowController {
            Logger.info("Onboarding window reused", category: .ui)
            if let window = controller.window {
                LocalImageCacheReclaimer.shared.windowDidOpen(window)
            }
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
                    .environment(workshopSetupController)
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

        LocalImageCacheReclaimer.shared.windowDidOpen(window)
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
            UserDefaults.standard.set(true, forKey: "Onboarding.Completed")
        }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow else { return }
        LocalImageCacheReclaimer.shared.windowWillClose(closingWindow)

        if closingWindow == settingsWindowController?.window {
            releaseSettingsSystemMonitorLeaseIfNeeded()
            closingWindow.delegate = nil
            // Detach the hosting view before dropping the controller so SwiftUI onDisappear fires; a plain dealloc is not guaranteed to.
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
                openHome: { [appDelegate] in
                    appDelegate.showSettings()
                },
                openSettingsAndAddWallpaper: { [appDelegate] screenID in
                    if EditDeskFlag.isEnabled {
                        // The Edit Desk reads the type off the file it is handed; the target rides in
                        // the same request so it cannot land after the picker has already opened.
                        appDelegate.showSettings(
                            initialAddWallpaperRequest: .init(kind: "any", targetDisplayID: screenID)
                        )
                    } else {
                        appDelegate.showSettings(
                            initialScreenID: screenID,
                            initialAddWallpaperRequest: .init(kind: "video", targetDisplayID: nil)
                        )
                    }
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
