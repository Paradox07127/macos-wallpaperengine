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
    func setUserAbsence(_ reason: UserAbsenceReason, present: Bool) {
        guard applyUserAbsenceChange(reason, present: present) else { return }
        refreshPerformancePolicyForAllScreens()
        reconcileAbsenceRevalidationTimer()
    }

    /// `revalidateUserAbsence` only runs inside a policy refresh, and every refresh is event-driven
    /// — so a lost wake/unlock notification with no later events pins every wallpaper suspended
    /// forever (the exact hole revalidation was built to close). While absent, poll it on a slow
    /// clock; the wallpapers are suspended then, so this is nearly free.
    private func reconcileAbsenceRevalidationTimer() {
        if isUserAbsent {
            guard absenceRevalidationTimer == nil else { return }
            let interval = absenceRevalidationPollInterval
            absenceRevalidationTimer = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: interval)
                    guard let self, !Task.isCancelled, !self.isTerminating else { return }
                    // Revalidation can clear the absence from inside the
                    // refresh (it bypasses `setUserAbsence`), so the timer must
                    // clean up after itself or it can never restart.
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

    /// Everything `setUserAbsence` does except the policy refresh, so the
    /// revalidation below can clear a reason from *inside* a refresh without
    /// recursing back into it. Returns whether the reason set actually changed.
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

    /// Absence is driven only by OS notifications, with no redundancy: one dropped unlock or display
    /// wake pins every wallpaper suspended forever, unreachable by settings or the play button. This
    /// asks an independent truth source whether the user is in fact back, and only ever *clears*
    /// reasons — it can never invent an absence. Deliberately unequal trust: `CGDisplayIsAsleep` is
    /// an unambiguous boolean, while a missing `CGSSessionScreenIsLocked` key can't be told apart
    /// from a failed read (probe 2026-08-18), so unlocking demands corroboration from an active
    /// display. System sleep is not revalidated at all — the process is suspended through it and
    /// always gets its wake.
    func revalidateUserAbsence() {
        guard !userAbsenceReasons.isEmpty else { return }

        // A reason recorded moments ago is trusted as-is: `setUserAbsence` refreshes policy
        // synchronously, so without this the sleep/lock notification's own refresh would revalidate
        // the absence it just recorded — and CoreGraphics often has not caught up yet, which would
        // clear it instantly on every single sleep.
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
        let decision = WallpaperPolicyEngine.decision(
            inputs: policyInputs(
                for: screen,
                applicationRuleActive: applicationRuleActive,
                frontmostExcluded: frontmostExcluded
            ),
            settings: settings
        )
        let profile = decision.profile
        // Feed the screen's machine — the same instance the installed session
        // adopted as its intent source — and take the reasons from its outputs,
        // so the UI's explanation can never drift from what sessions act on.
        suspendReasonsByScreen[screen.id] = playbackStateMachine(for: screen.id)
            .policyChanged(decision)
            .suspendReasons
        screen.runtimeSession?.applyPerformanceProfile(profile)
        if effectsCoordinatorWasInitialized {
            effectsCoordinator.setEnvironmentOverlaySuspended(profile == .suspended, for: screen)
        }
        if profile == .suspended {
            suspendedScreenIDs.insert(screen.id)
        } else {
            suspendedScreenIDs.remove(screen.id)
        }
        applyAdaptiveFrameRate(to: screen, settings: settings, throttleReasons: decision.throttleReasons)
        // Deep hibernate is reserved for absence-like suspensions (lock, sleep, full-screen
        // cover/occlusion) — an app-rule or battery pause stays a warm suspend for fast resume, and the
        // session owns the dwell countdown. Coverage inputs are only usable while the detector is
        // actually rescanning: with fallback polling off, its space/app-activation rescans are demand-
        // gated too, so hidden/occluded would be frozen at whatever the last scan saw. Absence stays
        // authoritative either way — it is tracked independently of the detector.
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
        // Read from the watcher's live level on every refresh, not only on a
        // level change: a session installed (restore-at-launch, swap-in) while
        // pressure is ALREADY critical would otherwise never hear about it and
        // stay fully resident for the whole emergency.
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
        // Heat and memory pressure are safety signals, not preferences: they
        // throttle even with adaptive FPS switched off. Otherwise turning that
        // setting off would disable thermal protection along with it, which is
        // exactly what suspending on `.serious` used to hide.
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
        applyWallpaperCapturePolicy()
    }

    /// Loads the capture setting and pushes it onto every window that already
    /// exists. Windows built later read the policy in their own initializer.
    func applyWallpaperCapturePolicy() {
        WallpaperCapturePolicy.allowsScreenCapture =
            SettingsManager.shared.loadGlobalSettings().wallpaperVisibleInScreenCapture
        let sharing = WallpaperCapturePolicy.windowSharingType
        for screen in screens {
            screen.activeWallpaperWindow?.sharingType = sharing
        }
        OverlayController.shared.applyCapturePolicyToLiveOverlays()
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
