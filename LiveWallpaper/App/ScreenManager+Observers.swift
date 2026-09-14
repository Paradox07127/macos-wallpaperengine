import SwiftUI
import Combine
import LiveWallpaperCore
import Observation

extension ScreenManager {
    func setupPowerMonitoring() {
        powerMonitor.powerSourcePublisher
            .sink { [weak self] _ in
                self?.handlePowerStateChange()
            }
            .store(in: &cleanupTasks)
        
        _ = powerMonitor.currentPowerSource
        handlePowerStateChange()
    }
    
    func setupScreenObservers() {
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .debounce(for: .seconds(0.5), scheduler: DispatchQueue.main)
            .throttle(for: .seconds(1.0), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in
                self?.handleScreenParameterChange()
            }
            .store(in: &cleanupTasks)

        NotificationCenter.default.publisher(for: .scenePresetLibraryDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleScenePresetLibraryChange()
            }
            .store(in: &cleanupTasks)

        NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                Logger.info(
                    "Thermal state changed to \(ProcessInfo.processInfo.thermalState); refreshing wallpaper performance policy",
                    category: .powerMonitor
                )
                self.refreshPerformancePolicyForAllScreens()
            }
            .store(in: &cleanupTasks)

        NotificationCenter.default.publisher(for: Notification.Name.NSProcessInfoPowerStateDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                Logger.info(
                    "Power state changed (Low Power Mode: \(ProcessInfo.processInfo.isLowPowerModeEnabled)); refreshing wallpaper performance policy",
                    category: .powerMonitor
                )
                self.refreshPerformancePolicyForAllScreens()
            }
            .store(in: &cleanupTasks)

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.refreshPerformancePolicyForAllScreens()
            }
            .store(in: &cleanupTasks)

        Publishers.Merge(
            NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification),
            NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            guard let self else { return }
            guard SettingsManager.shared.loadGlobalSettings()
                .applicationPerformanceRules.contains(where: { $0.trigger == .running }) else { return }
            self.refreshPerformancePolicyForAllScreens()
        }
        .store(in: &cleanupTasks)

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)
            .sink { [weak self] _ in
                self?.handleSystemSleep()
            }
            .store(in: &cleanupTasks)

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in
                self?.handleSystemWake()
            }
            .store(in: &cleanupTasks)

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.screensDidSleepNotification)
            .sink { [weak self] _ in
                self?.handleDisplaySleep()
            }
            .store(in: &cleanupTasks)

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.screensDidWakeNotification)
            .sink { [weak self] _ in
                self?.handleDisplayWake()
            }
            .store(in: &cleanupTasks)

        DistributedNotificationCenter.default().publisher(for: Notification.Name("com.apple.screenIsLocked"))
            .sink { [weak self] _ in
                self?.handleScreenLocked()
            }
            .store(in: &cleanupTasks)

        DistributedNotificationCenter.default().publisher(for: Notification.Name("com.apple.screenIsUnlocked"))
            .sink { [weak self] _ in
                self?.handleScreenUnlocked()
            }
            .store(in: &cleanupTasks)

        // Global play/pause flips every session's intent without a policy refresh; the session-state commit's isAnyPlaying edge is the signal that reaches this file.
        playbackStateSubject
            .sink { [weak self] _ in
                self?.refreshAppNapAssertion()
            }
            .store(in: &cleanupTasks)
    }

    private func handleScreenLocked() {
        Logger.info("Screen locked — suspending wallpaper sessions", category: .lifecycle)
        setUserAbsence(.screenLocked, present: true)
    }

    private func handleDisplaySleep() {
        Logger.info("Display asleep — suspending wallpaper sessions", category: .lifecycle)
        setUserAbsence(.displaySleep, present: true)
    }

    private func handleDisplayWake() {
        Logger.info("Display awake — restoring wallpaper sessions", category: .lifecycle)
        setUserAbsence(.displaySleep, present: false)
    }

    private func handleScreenUnlocked() {
        Logger.info("Screen unlocked — restoring wallpaper sessions", category: .lifecycle)
        setUserAbsence(.screenLocked, present: false)
    }

    /// Lock screen and display sleep both mean "user is not watching".
    func setUserAbsence(_ reason: UserAbsenceReason, present: Bool) {
        guard applyUserAbsenceChange(reason, present: present) else { return }
        refreshPerformancePolicyForAllScreens()
        reconcileAbsenceRevalidationTimer()
    }

    private func reconcileAbsenceRevalidationTimer() {
        if isUserAbsent {
            guard absenceRevalidationTimer == nil else { return }
            let interval = absenceRevalidationPollInterval
            absenceRevalidationTimer = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: interval)
                    guard let self, !Task.isCancelled, !self.isTerminating else { return }
                    // Revalidation can clear the absence from inside the refresh (it bypasses setUserAbsence), so the timer must clean up after itself or it can never restart.
                    guard self.isUserAbsent else {
                        self.absenceRevalidationTimer = nil
                        return
                    }
                    self.refreshPerformancePolicyForAllScreens()
                    if !self.isUserAbsent {
                        self.absenceRevalidationTimer = nil
                        return
                    }
                }
            }
        } else {
            absenceRevalidationTimer?.cancel()
            absenceRevalidationTimer = nil
        }
    }

    /// Everything setUserAbsence does except the policy refresh, so revalidation can clear a reason from inside a refresh without recursing.
    @discardableResult
    private func applyUserAbsenceChange(_ reason: UserAbsenceReason, present: Bool) -> Bool {
        let wasAbsent = isUserAbsent
        let changed = present
            ? userAbsenceReasons.insert(reason).inserted
            : (userAbsenceReasons.remove(reason) != nil)
        guard changed else { return false }
        if present {
            absenceMarkedAt[reason] = ContinuousClock.now
        } else {
            absenceMarkedAt[reason] = nil
        }
        if !wasAbsent, isUserAbsent {
            automationOrchestrator.suspendForUserAbsence()
        } else if wasAbsent, !isUserAbsent {
            automationOrchestrator.resumeAfterUserAbsence()
        }
        refreshMonitorOverlayVisibility()
        return true
    }

    /// Asks an independent truth source whether the user is in fact back, and only ever clears reasons — it can never invent an absence.
    /// CGDisplayIsAsleep is an unambiguous boolean, while a missing CGSSessionScreenIsLocked key cannot be told apart from a failed read, so unlocking demands corroboration from an active display.
    func revalidateUserAbsence() {
        guard !userAbsenceReasons.isEmpty else { return }

        // A reason recorded moments ago is trusted as-is: without this the sleep/lock notification's own refresh would revalidate the absence it just recorded — and CoreGraphics often has not caught up yet.
        func isSettled(_ reason: UserAbsenceReason) -> Bool {
            guard let marked = absenceMarkedAt[reason] else { return true }
            return ContinuousClock.now - marked >= absenceRevalidationGrace
        }

        if userAbsenceReasons.contains(.displaySleep), isSettled(.displaySleep),
           !userPresenceProbe.areAllDisplaysAsleep() {
            Logger.notice("A display is awake but absence persisted — clearing stale display-sleep absence", category: .lifecycle)
            applyUserAbsenceChange(.displaySleep, present: false)
        }

        if userAbsenceReasons.contains(.screenLocked), isSettled(.screenLocked),
           userPresenceProbe.screenLockState() == .unlocked,
           userPresenceProbe.isMainDisplayActive() {
            Logger.notice("Session reports unlocked but absence persisted — clearing stale lock absence", category: .lifecycle)
            applyUserAbsenceChange(.screenLocked, present: false)
        }
    }

    private func handleScreenParameterChange() {
        guard !isTerminating else { return }
        let current = ScreenConfigurationSignature.currentLayout()
        if current == lastScreenSignatures && !screens.isEmpty {
            Logger.debug("Screen parameters unchanged — skipping refresh", category: .screenManager)
            return
        }
        let rateChanged = current.filter { id, signature in
            guard let previous = lastScreenSignatures[id] else { return false }
            return previous.maximumFramesPerSecond != signature.maximumFramesPerSecond
        }
        lastScreenSignatures = current

        refreshRateCache.removeAll()
        refreshScreens(preserveRuntimeSessions: true)
        // Preserved sessions are still running the ceiling resolved against the
        // old refresh rate, and the cap is a divisor of it.
        for screen in screens where rateChanged[screen.id] != nil {
            guard let configuration = getConfiguration(for: screen) else { continue }
            applyFrameRateLimit(configuration.frameRateLimit, to: screen)
        }

        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard let self, !self.isTerminating else { return }
            self.updateAllWindowFrames()
            try? await Task.sleep(for: .milliseconds(500))
            guard !self.isTerminating else { return }
            self.updateAllWindowFrames()
        }

    }

    func updateAllWindowFrames() {
        guard !isTerminating else { return }
        for screen in screens {
            if let nsScreen = displayRegistry.findNSScreen(for: screen.id) {
                screen.updateRuntimeFrame(to: nsScreen.frame)
                if effectsCoordinatorWasInitialized {
                    effectsCoordinator.updateEnvironmentOverlayFrame(for: screen, frame: nsScreen.frame)
                }
            } else {
                Logger.warning("Could not find NSScreen for screen ID \(screen.id), using stored frame", category: .screenManager)
                screen.updateRuntimeFrame(to: screen.frame)
            }
        }
        playbackCoordinator.refreshVideoAudioLeadership()
        reconcileMonitorOverlays()
    }
    
    func setupFullScreenDetection() {
        observeFullScreenChanges()
        fullScreenDetector.checkNow()
        handleFullScreenChange()
    }

    private func observeFullScreenChanges() {
        fullScreenTrackingGeneration &+= 1
        let generation = fullScreenTrackingGeneration
        withObservationTracking {
            _ = fullScreenDetector.hiddenScreens
            _ = fullScreenDetector.occludedScreens
            // Adaptive throttle reacts to partial coverage below the 0.85
            // pause cutoff, so track the (quantized) fraction too.
            _ = fullScreenDetector.occlusionFractions
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self,
                      !self.isTerminating,
                      self.fullScreenTrackingGeneration == generation else { return }
                self.handleFullScreenChange()
                self.observeFullScreenChanges()
            }
        }
    }

    private func handleFullScreenChange() {
        refreshMonitorOverlayVisibility()
        refreshPerformancePolicyForAllScreens()
    }

    private func handlePowerStateChange() {
        refreshPerformancePolicyForAllScreens()
    }

    @discardableResult
    func applyPerformancePolicy(to screen: Screen) -> WallpaperPerformanceProfile {
        let settings = SettingsManager.shared.loadGlobalSettings()
        let profile = resolveAndApplyPerformanceState(
            to: screen,
            settings: settings,
            applicationRuleActive: currentApplicationRuleActive(settings),
            frontmostExcluded: ApplicationPerformanceRuleEngine.isFrontmostExcluded(for: settings)
        )
        refreshAppNapAssertion()
        return profile
    }

    @discardableResult
    private func resolveAndApplyPerformanceState(
        to screen: Screen,
        settings: GlobalSettings,
        applicationRuleActive: Bool,
        frontmostExcluded: Bool
    ) -> WallpaperPerformanceProfile {
        let decision = WallpaperPolicyEngine.decision(
            inputs: policyInputs(
                for: screen,
                applicationRuleActive: applicationRuleActive,
                frontmostExcluded: frontmostExcluded
            ),
            settings: settings
        )
        let profile = decision.profile
        // Feed the screen's machine — the same instance the installed session adopted as its intent source — and take the reasons from its outputs, so the UI's explanation cannot drift from what sessions act on.
        suspendReasonsByScreen[screen.id] = playbackStateMachine(for: screen.id)
            .policyChanged(decision)
            .suspendReasons
        screen.runtimeSession?.applyPerformanceProfile(profile)
        if effectsCoordinatorWasInitialized {
            effectsCoordinator.setEnvironmentOverlaySuspended(profile == .suspended, for: screen)
        }
        applyAdaptiveFrameRate(to: screen, settings: settings, throttleReasons: decision.throttleReasons)
        // Deep hibernate is reserved for absence-like suspensions; an app-rule or battery pause stays a warm suspend for fast resume.
        // Coverage inputs are only usable while the detector is actually rescanning.
        let coverageIsLive = fullScreenDetector.isFallbackPollingEnabled
        let isAbsenceLikeSuspension = profile == .suspended
            && (isUserAbsent
                || (coverageIsLive
                    && (fullScreenDetector.isDesktopHidden(for: screen.id)
                        || fullScreenDetector.isDesktopOccluded(for: screen.id))))
        // Video and HTML ship in both SKUs, so their dwell wiring stays outside
        // the Pro-only block below.
        (screen.runtimeSession as? VideoWallpaperSession)?
            .setHibernationEligible(isAbsenceLikeSuspension)
        (screen.runtimeSession as? AmbientWallpaperSession)?
            .setHibernationEligible(isAbsenceLikeSuspension)
        #if !LITE_BUILD
        (screen.runtimeSession as? SceneWallpaperSession)?
            .setHibernationEligible(isAbsenceLikeSuspension)
        #endif
        // Read from the watcher's live level on every refresh, not only on a level change: a session installed while pressure is already critical would otherwise never hear about it.
        (screen.runtimeSession as? WallpaperCriticalMemoryPressureResponding)?
            .setCriticalMemoryPressureActive(
                memoryPressureWatcher.currentLevel() == .critical
            )
        return profile
    }

    /// Layers the adaptive background frame-rate throttle on top of the binary play/pause profile.
    private func applyAdaptiveFrameRate(
        to screen: Screen,
        settings: GlobalSettings,
        throttleReasons: Set<WallpaperSuspendReason> = []
    ) {
        #if !LITE_BUILD
        guard let scene = screen.runtimeSession as? SceneWallpaperSession,
              let controller = scene.frameRateController else {
            adaptiveFrameRateOcclusionThrottled[screen.id] = nil
            return
        }
        // Heat and memory pressure are safety signals, not preferences: they throttle even with adaptive FPS switched off. Otherwise turning that setting off would disable thermal protection along with it.
        let safetyThrottle = !throttleReasons.isEmpty
        // Setting off must release any live throttle, not only stop computing.
        guard settings.adaptiveFrameRateEnabled else {
            adaptiveFrameRateOcclusionThrottled[screen.id] = nil
            controller.setAdaptiveFrameRateThrottle(safetyThrottle)
            return
        }
        let occlusionThrottled = AdaptiveFrameRatePolicy.shouldThrottleForOcclusion(
            occlusionFraction: fullScreenDetector.occlusionFraction(for: screen.id),
            currentlyThrottled: adaptiveFrameRateOcclusionThrottled[screen.id] ?? false
        )
        adaptiveFrameRateOcclusionThrottled[screen.id] = occlusionThrottled
        let shouldThrottle = AdaptiveFrameRatePolicy.shouldThrottle(
            enabled: true,
            occlusionThrottled: occlusionThrottled,
            onBattery: powerMonitor.currentPowerSource.isOnBattery,
            pausesOnBattery: settings.globalPauseOnBattery
        )
        controller.setAdaptiveFrameRateThrottle(safetyThrottle || shouldThrottle)
        #endif
    }

    /// Snapshots the current *raw* system state for `screen`.
    private func policyInputs(
        for screen: Screen,
        applicationRuleActive: Bool,
        frontmostExcluded: Bool
    ) -> WallpaperPolicyInputs {
        WallpaperPolicyInputs(
            powerSource: powerMonitor.currentPowerSource,
            isHiddenByFullScreen: fullScreenDetector.isDesktopHidden(for: screen.id),
            isWindowOccluding: fullScreenDetector.isDesktopOccluded(for: screen.id),
            isApplicationRuleActive: applicationRuleActive,
            thermalState: ProcessInfo.processInfo.thermalState,
            isUserAbsent: isUserAbsent,
            memoryPressureLevel: memoryPressureLevel,
            isLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            isFrontmostExcludedByRule: frontmostExcluded,
            // Video is the one session type with no load-shedding knob — for it
            // the throttle tier must fall back to the pre-throttle suspend.
            respondsToThermalThrottle: !(screen.runtimeSession is VideoWallpaperSession)
        )
    }

    private func currentApplicationRuleActive(_ globalSettings: GlobalSettings) -> Bool {
        ApplicationPerformanceRuleEngine.isActive(for: globalSettings)
    }

    func refreshPerformancePolicyForAllScreens() {
        revalidateUserAbsence()
        let settings = SettingsManager.shared.loadGlobalSettings()
        let applicationRuleActive = currentApplicationRuleActive(settings)
        let frontmostExcluded = ApplicationPerformanceRuleEngine.isFrontmostExcluded(for: settings)
        for screen in screens {
            resolveAndApplyPerformanceState(
                to: screen,
                settings: settings,
                applicationRuleActive: applicationRuleActive,
                frontmostExcluded: frontmostExcluded
            )
        }
        refreshAppNapAssertion()
        commitWallpaperSessionState()
    }

    func refreshAppNapAssertion() {
        let isRendering = screens.contains { screen in
            guard screen.runtimeSession != nil,
                  (suspendReasonsByScreen[screen.id] ?? []).isEmpty,
                  screen.playbackController?.userIntendsToPlay ?? true else { return false }
            #if !LITE_BUILD
            if let scene = screen.runtimeSession as? SceneWallpaperSession {
                return scene.mayPerformRuntimeWork
            }
            #endif
            return true
        }
        if isRendering {
            guard renderingActivityToken == nil else { return }
            renderingActivityToken = ProcessInfo.processInfo.beginActivity(
                options: WallpaperRenderingActivityPolicy.options,
                reason: "Rendering live wallpaper"
            )
        } else if let token = renderingActivityToken {
            ProcessInfo.processInfo.endActivity(token)
            renderingActivityToken = nil
        }
    }

    func updateFullScreenFallbackPolling() {
        guard !isTerminating else {
            // Bottom-level fail-closed gate: settings/backup callbacks are not
            // owned by `cleanupTasks` and may arrive after termination teardown.
            fullScreenDetector.setFallbackPollingEnabled(false)
            return
        }
        let globalSettings = SettingsManager.shared.loadGlobalSettings()
        let hasConfiguredSessions = wallpaperSessionSummaries.contains { $0.isConfigured }
        let hasConfiguredSceneSessions = wallpaperSessionSummaries.contains {
            $0.isConfigured && $0.wallpaperType == .scene
        }
        let wallpaperPolicyNeedsPolling = WallpaperPolicyEngine.shouldEnableFullScreenFallbackPolling(
            globalSettings: globalSettings,
            hasConfiguredWallpaperSessions: hasConfiguredSessions,
            hasConfiguredSceneSessions: hasConfiguredSceneSessions
        )
        let shouldEnablePolling = wallpaperPolicyNeedsPolling || hasEnabledDesktopMonitorOverlay

        fullScreenDetector.setFallbackPollingEnabled(shouldEnablePolling)
    }

    func handleGlobalSettingsChanged() {
        guard !isTerminating else { return }
        // Both caches live in GlobalSettings, which a .lwconfig import replaces wholesale. Without re-reading them the imported names/overlays stay invisible until relaunch.
        screenNames = SettingsManager.shared.loadScreenNames()
        monitorOverlays = SettingsManager.shared.loadMonitorOverlays()
        updateFullScreenFallbackPolling()
        refreshPerformancePolicyForAllScreens()
        applyWallpaperCapturePolicy()
    }

    /// Windows built later read the policy in their own initializer.
    func applyWallpaperCapturePolicy() {
        WallpaperCapturePolicy.allowsScreenCapture =
            SettingsManager.shared.loadGlobalSettings().wallpaperVisibleInScreenCapture
        let sharing = WallpaperCapturePolicy.windowSharingType
        for screen in screens {
            screen.applyCapturePolicy(sharing)
        }
        OverlayController.shared.applyCapturePolicyToLiveOverlays()
        if effectsCoordinatorWasInitialized {
            effectsCoordinator.applyCapturePolicyToEnvironmentOverlays(sharing)
        }
    }
    
    private func handleSystemSleep() {
        Logger.info("System sleep detected", category: .lifecycle)
        setUserAbsence(.systemSleep, present: true)
    }

    private func handleSystemWake() {
        Logger.info("System wake detected", category: .lifecycle)
        refreshScreens()
        powerMonitor.refreshPowerStatus()
        setUserAbsence(.systemSleep, present: false)
    }

    func captureDesktopSnapshotsForLockIfNeeded() {
        guard !isTerminating else { return }
        let globalSettings = SettingsManager.shared.loadGlobalSettings()
        guard globalSettings.preservePlaybackOnLock else { return }

        for screen in screens {
            guard let config = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint),
                  config.wallpaperType == .video,
                  config.setAsLockScreen else { continue }
            Task { await extractLockScreenFrame(for: screen) }
        }
    }
    
}
