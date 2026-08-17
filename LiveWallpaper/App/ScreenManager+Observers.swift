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

        // Global play/pause (`togglePlayback()` in ScreenManager+Wallpaper.swift)
        // flips every session's intent without a policy refresh, leaving the
        // assertion stale until some unrelated refresh; the session-state
        // commit's isAnyPlaying edge is the signal that reaches this file.
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
    private func setUserAbsence(_ reason: UserAbsenceReason, present: Bool) {
        let wasAbsent = isUserAbsent
        let changed = present
            ? userAbsenceReasons.insert(reason).inserted
            : (userAbsenceReasons.remove(reason) != nil)
        guard changed else { return }
        if !wasAbsent, isUserAbsent {
            automationOrchestrator.suspendForUserAbsence()
        } else if wasAbsent, !isUserAbsent {
            automationOrchestrator.resumeAfterUserAbsence()
        }
        refreshMonitorOverlayVisibility()
        refreshPerformancePolicyForAllScreens()
    }

    private func handleScreenParameterChange() {
        guard !isTerminating else { return }
        let current = ScreenConfigurationSignature.currentLayout()
        if current == lastScreenSignatures && !screens.isEmpty {
            Logger.debug("Screen parameters unchanged — skipping refresh", category: .screenManager)
            return
        }
        lastScreenSignatures = current

        refreshRateCache.removeAll()
        refreshScreens(preserveRuntimeSessions: true)

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

    /// Full-screen / window-occlusion changes fold into the effective profile like every other condition; a single policy refresh applies the unified play/pause decision.
    private func handleFullScreenChange() {
        refreshMonitorOverlayVisibility()
        refreshPerformancePolicyForAllScreens()
    }

    /// Routes power changes through the unified performance policy.
    private func handlePowerStateChange() {
        refreshPerformancePolicyForAllScreens()
    }

    /// Single source of truth for resolving + applying the performance policy to one screen.
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

    /// Applies the unified suspend, quality, and scene frame-rate policy.
    @discardableResult
    private func resolveAndApplyPerformanceState(
        to screen: Screen,
        settings: GlobalSettings,
        applicationRuleActive: Bool,
        frontmostExcluded: Bool
    ) -> WallpaperPerformanceProfile {
        let profile = WallpaperPolicyEngine.performanceProfile(
            inputs: policyInputs(
                for: screen,
                applicationRuleActive: applicationRuleActive,
                frontmostExcluded: frontmostExcluded
            ),
            settings: settings
        )
        screen.runtimeSession?.applyPerformanceProfile(profile)
        if effectsCoordinatorWasInitialized {
            effectsCoordinator.setEnvironmentOverlaySuspended(profile == .suspended, for: screen)
        }
        if profile == .suspended {
            suspendedScreenIDs.insert(screen.id)
        } else {
            suspendedScreenIDs.remove(screen.id)
        }
        applyAdaptiveFrameRate(to: screen, settings: settings)
        #if !LITE_BUILD
        // Deep hibernate is reserved for absence-like suspensions (lock, sleep,
        // full-screen cover/occlusion) — an app-rule or battery pause stays a
        // warm suspend for fast resume. The session owns the dwell countdown.
        if let scene = screen.runtimeSession as? SceneWallpaperSession {
            scene.setHibernationEligible(
                profile == .suspended
                    && (isUserAbsent
                        || fullScreenDetector.isDesktopHidden(for: screen.id)
                        || fullScreenDetector.isDesktopOccluded(for: screen.id))
            )
            // Reconciled from the watcher's live level on every refresh, not only
            // on a level change: a session installed (restore-at-launch, swap-in)
            // while pressure is ALREADY critical would otherwise never hear about
            // it and stay fully resident for the whole emergency.
            scene.setCriticalMemoryPressureActive(
                memoryPressureWatcher.currentLevel() == .critical
            )
        }
        #endif
        return profile
    }

    /// Layers the adaptive background frame-rate throttle on top of the binary play/pause profile.
    private func applyAdaptiveFrameRate(to screen: Screen, settings: GlobalSettings) {
        #if !LITE_BUILD
        guard let scene = screen.runtimeSession as? SceneWallpaperSession,
              let controller = scene.frameRateController else {
            adaptiveFrameRateOcclusionThrottled[screen.id] = nil
            return
        }
        // Setting off must release any live throttle, not only stop computing.
        guard settings.adaptiveFrameRateEnabled else {
            adaptiveFrameRateOcclusionThrottled[screen.id] = nil
            controller.setAdaptiveFrameRateThrottle(false)
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
        controller.setAdaptiveFrameRateThrottle(shouldThrottle)
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
            isUnderMemoryPressure: isUnderMemoryPressure,
            isLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            isFrontmostExcludedByRule: frontmostExcluded
        )
    }

    private func currentApplicationRuleActive(_ globalSettings: GlobalSettings) -> Bool {
        ApplicationPerformanceRuleEngine.isActive(for: globalSettings)
    }

    func refreshPerformancePolicyForAllScreens() {
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

    /// Hold an activity assertion while ≥1 wallpaper session may be doing real work — producing frames, playing audio, or loading — so macOS doesn't App-Nap our background render loop down to ~1fps when the user focuses another window.
    /// The release states: no session, policy-suspended, user-paused, or a scene session whose renderer reported it is provably idle (static scene, no audio) through the session's runtime-activity mirror (`SceneWallpaperSession.mayPerformRuntimeWork`, pushed from the render actor on change). Non-scene sessions and scenes that have not reported yet err on holding.
    func refreshAppNapAssertion() {
        let isRendering = screens.contains { screen in
            guard screen.runtimeSession != nil,
                  !suspendedScreenIDs.contains(screen.id),
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
        // Both caches live in GlobalSettings, which a .lwconfig import replaces
        // wholesale. Without re-reading them the imported names/overlays stay
        // invisible until relaunch, and the next rename writes the pre-import
        // dictionary back over them.
        screenNames = SettingsManager.shared.loadScreenNames()
        monitorOverlays = SettingsManager.shared.loadMonitorOverlays()
        updateFullScreenFallbackPolling()
        refreshPerformancePolicyForAllScreens()
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
            extractLockScreenFrame(for: screen)
        }
    }
    
}
