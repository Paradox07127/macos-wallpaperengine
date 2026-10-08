import AppKit
import LiveWallpaperCore

extension ScreenManager {
    func reconcileMonitorOverlays() {
        guard !isTerminating, wallpapersGloballyEnabled else {
            OverlayController.shared.teardownAll()
            updateFullScreenFallbackPolling()
            return
        }
        if hasEnabledDesktopMonitorOverlay {
            fullScreenDetector.checkNow()
        }
        // Suspend before host create so occluded overlays never get a prime snapshot.
        refreshMonitorOverlayVisibility()
        // Reading `weatherService` builds the effects coordinator, so only a board
        // that draws the sky pays for it.
        OverlayController.shared.updateWeatherService(hasEnabledWeatherWidget ? weatherService : nil)
        OverlayController.shared.onOverlayEdited = { [weak self] screenID, board in
            self?.persistMonitorOverlayBoard(board, screenID: screenID)
        }
        OverlayController.shared.retainOnly(Set(screens.map(\.id)))
        for screen in screens {
            let frame = displayRegistry.findNSScreen(for: screen.id)?.frame ?? screen.frame
            OverlayController.shared.apply(
                overlay: monitorOverlays[screen.displayFingerprint],
                screenID: screen.id,
                screenFrame: frame
            )
        }
        refreshMonitorOverlayVisibility()
        updateFullScreenFallbackPolling()
    }

    func refreshMonitorOverlayVisibility() {
        let occludedScreenIDs = Set(screens.compactMap { screen in
            fullScreenDetector.isDesktopOccluded(for: screen.id) ? screen.id : nil
        })
        OverlayController.shared.updateVisibility(
            isUserAbsent: isUserAbsent,
            occludedScreenIDs: occludedScreenIDs
        )
    }

    private func scheduleMonitorOverlayReconcile() {
        Task { @MainActor [weak self] in
            guard let self, !self.isTerminating else { return }
            self.reconcileMonitorOverlays()
        }
    }

    /// Persist a board edit made ON the floating overlay. Skips the reconcile —
    /// re-applying the config would echo the edit back onto the board mid-drag.
    private func persistMonitorOverlayBoard(_ board: MonitorBoardConfiguration, screenID: CGDirectDisplayID) {
        guard let screen = screens.first(where: { $0.id == screenID }) else { return }
        mutateMonitorOverlays(of: [screen], reconcile: false) { $0.board = board }
    }

    /// This display's overlay config; absent = never configured, i.e. off.
    func monitorOverlay(for screen: Screen) -> MonitorOverlayConfiguration {
        monitorOverlays[screen.displayFingerprint] ?? .default
    }

    /// This display's weather layer; absent = never configured, i.e. off.
    func weatherOverlay(for screen: Screen) -> WeatherOverlayConfiguration {
        weatherOverlays[screen.displayFingerprint] ?? .default
    }

    /// Persists only; callers bring the particle layer up to date.
    func storeWeatherOverlay(_ overlay: WeatherOverlayConfiguration, for targets: [Screen]) {
        var next = weatherOverlays
        for screen in targets {
            next[screen.displayFingerprint] = overlay
        }
        guard next != weatherOverlays else { return }
        weatherOverlays = next
        SettingsManager.shared.saveWeatherOverlays(next)
    }

    var hasEnabledWeatherWidget: Bool {
        wallpapersGloballyEnabled && screens.contains { screen in
            let overlay = monitorOverlay(for: screen)
            return overlay.enabled && overlay.board.widgets.contains { $0.kind == .weather && !$0.isHidden }
        }
    }

    func setMonitorOverlayEnabled(_ enabled: Bool, for screen: Screen) {
        mutateMonitorOverlays(of: [screen]) { $0.enabled = enabled }
    }

    func setMonitorOverlayLevel(_ level: MonitorOverlayLevel, for screen: Screen) {
        mutateMonitorOverlays(of: [screen]) { $0.level = level }
    }

    func setMonitorOverlayBoard(_ board: MonitorBoardConfiguration, for screen: Screen) {
        mutateMonitorOverlays(of: [screen]) { $0.board = board }
    }

    func setMusicOverlayEnabled(_ enabled: Bool, for screen: Screen) {
        mutateMonitorOverlays(of: [screen]) { $0.music.enabled = enabled }
    }

    func setMusicOverlayLevel(_ level: MonitorOverlayLevel, for screen: Screen) {
        mutateMonitorOverlays(of: [screen]) { $0.music.level = level }
    }

    func setMusicOverlay(_ music: MusicOverlayConfiguration, for screen: Screen) {
        mutateMonitorOverlays(of: [screen]) { $0.music = music }
    }

    func setClockOverlay(_ clock: ClockOverlayConfiguration, for screen: Screen) {
        mutateMonitorOverlays(of: [screen]) { $0.clock = clock.normalized }
    }

    /// Whole-struct overwrite so a field added to MonitorOverlayConfiguration later cannot be silently dropped on apply.
    func setMonitorOverlay(_ overlay: MonitorOverlayConfiguration, for screen: Screen) {
        mutateMonitorOverlays(of: [screen]) { $0 = overlay }
    }

    func applyOverlayToAllDisplays(_ kind: OverlayKind, from source: Screen) {
        guard !isTerminating, screens.count > 1 else { return }
        let targets = screens.filter { $0.id != source.id }
        guard !targets.isEmpty else { return }

        switch kind {
        case .monitor:
            let template = monitorOverlay(for: source)
            mutateMonitorOverlays(of: targets) {
                $0.enabled = template.enabled
                $0.level = template.level
                $0.board = template.board
            }
        case .music:
            let template = monitorOverlay(for: source).music
            mutateMonitorOverlays(of: targets) { $0.music = template }
        case .clock:
            let template = monitorOverlay(for: source).clock
            mutateMonitorOverlays(of: targets) { $0.clock = template }
        case .weather:
            storeWeatherOverlay(weatherOverlay(for: source), for: targets)
            effectsCoordinator.weatherOverlaysDidChange()
        }
        Logger.info(
            "Applied \(kind) overlay from screen \(source.id) to \(targets.count) other displays",
            category: .screenManager
        )
    }

    var hasEnabledDesktopMonitorOverlay: Bool {
        screens.contains {
            let overlay = monitorOverlay(for: $0)
            return (overlay.enabled && overlay.level == .desktop)
                || (overlay.music.enabled && overlay.music.level == .desktop)
                || (overlay.clock.enabled && overlay.clock.level == .desktop)
        }
    }

    private func mutateMonitorOverlays(
        of targets: [Screen],
        reconcile: Bool = true,
        _ mutate: (inout MonitorOverlayConfiguration) -> Void
    ) {
        var next = monitorOverlays
        for screen in targets {
            var overlay = next[screen.displayFingerprint] ?? .default
            mutate(&overlay)
            next[screen.displayFingerprint] = overlay
        }
        guard next != monitorOverlays else { return }
        monitorOverlays = next
        SettingsManager.shared.saveMonitorOverlays(next)
        // A Weather tile dropped on the desktop arrives with reconcile: false, so this is where a board already built gets the sky.
        OverlayController.shared.updateWeatherService(hasEnabledWeatherWidget ? weatherService : nil)
        if effectsCoordinatorWasInitialized {
            effectsCoordinator.monitorBoardsDidChange()
        }
        if reconcile { scheduleMonitorOverlayReconcile() }
    }
}
