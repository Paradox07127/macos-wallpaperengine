import SwiftUI
import Combine
import LiveWallpaperCore
import Observation

#if !LITE_BUILD
import LiveWallpaperProWPE
#endif

extension ScreenManager {
    /// Replaces the primary video while preserving per-screen settings.
    func setVideo(url: URL, bookmarkData: Data, packageEntryName: String? = nil, for screen: Screen) {
        guard !isTerminating else { return }
        beginExplicitWallpaperSelection(for: screen)
        recordBookmarkDisplayName(bookmarkData, name: url.lastPathComponent)
        playbackCoordinator.setVideo(
            url: url,
            bookmarkData: bookmarkData,
            packageEntryName: packageEntryName,
            for: screen
        )
    }

    @discardableResult
    func bumpTransition(for screenID: CGDirectDisplayID) -> Int {
        advanceScenePropertyMutationIntent(for: screenID)
        return transitionRegistry.bumpTransition(for: screenID)
    }

    func isCurrentTransition(_ generation: Int, for screenID: CGDirectDisplayID) -> Bool {
        transitionRegistry.isCurrentTransition(generation, for: screenID)
    }

    /// Bump latest-intent even for no-op selects (cancel older prepared candidates).
    @discardableResult
    func beginExplicitWallpaperSelection(for screen: Screen) -> Int {
        #if !LITE_BUILD
        // Retire any older WPE import so a late proposal cannot re-win latest.
        _ = wpeImportTracker.bumpGeneration(for: screen.id)
        #endif
        return bumpTransition(for: screen.id)
    }

    func applyConfiguration(
        _ configuration: ScreenConfiguration,
        to screen: Screen,
        preservingState: Bool = false,
        forceReplacement: Bool = false,
        intent: WallpaperSessionRestoreIntent = .persistedConfiguration,
        beforeCommit: @MainActor @escaping () -> Bool = { true }
    ) {
        guard !isTerminating else { return }
        playbackCoordinator.applyConfiguration(
            configuration,
            to: screen,
            preservingState: preservingState,
            forceReplacement: forceReplacement,
            intent: intent,
            beforeCommit: beforeCommit
        )
    }

    var wallpaperSessionSummaries: [WallpaperSessionSummary] {
        screens.map { wallpaperSummary(for: $0) }
    }

    var wallpaperOverviewStatus: WallpaperOverviewStatus {
        WallpaperStatusAggregator.overview(for: wallpaperSessionSummaries)
    }

    var hasControllableWallpaperSessions: Bool {
        wallpaperSessionSummaries.contains { $0.isConfigured && $0.supportsPlaybackControl }
    }

    func wallpaperSummary(for screen: Screen) -> WallpaperSessionSummary {
        wallpaperSessionSummaryCache.summary(for: screen.id, fallback: effectiveSummary(for: screen))
    }

    /// Per-screen summary that accounts for the master render gate.
    private func effectiveSummary(for screen: Screen) -> WallpaperSessionSummary {
        if screen.runtimeSession != nil {
            return screen.wallpaperSessionSummary
        }
        if !wallpapersGloballyEnabled, let type = persistedWallpaperType(for: screen) {
            return WallpaperSessionSummary(
                wallpaperType: type,
                activity: .off,
                supportsPlaybackControl: false,
                subtitle: nil
            )
        }
        return screen.wallpaperSessionSummary
    }

    /// The wallpaper type a screen would render from its persisted configuration, or `nil` when nothing valid is assigned.
    private func persistedWallpaperType(for screen: Screen) -> WallpaperType? {
        guard let config = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint),
              WallpaperSessionDefinition(configuration: config) != nil else { return nil }
        return config.activeWallpaper.wallpaperType
    }

    func runtimeError(for screen: Screen) -> WallpaperRuntimeError? {
        _ = wallpaperSessionStateVersion
        return transientRuntimeErrors[screen.id] ?? screen.runtimeSession?.runtimeError
    }

    func setTransientRuntimeError(_ error: WallpaperRuntimeError?, for screenID: CGDirectDisplayID) {
        let didChange: Bool
        if let error {
            didChange = transientRuntimeErrors[screenID] != error
            transientRuntimeErrors[screenID] = error
        } else {
            didChange = transientRuntimeErrors.removeValue(forKey: screenID) != nil
        }
        guard didChange else { return }

        var next = wallpaperSessionState
        next.version &+= 1
        wallpaperSessionState = next
    }

    func retryRuntimeSession(for screen: Screen) {
        Task { @MainActor [weak self, weak screen] in
            guard let self, let screen, !self.isTerminating else { return }
            // Transactional scene rebuild so a failed reload keeps the last frame.
            if screen.runtimeSession?.wallpaperType == .scene,
               let configuration = self.configurationStore.get(
                   for: screen.id,
                   fingerprint: screen.displayFingerprint
               ) {
                self.restoreWallpaperSession(
                    for: screen,
                    configuration: configuration,
                    preservingState: false
                )
                return
            }
            await screen.runtimeSession?.retry()
            guard !self.isTerminating else { return }
            self.markWallpaperSessionStateChanged()
        }
    }

    /// Subscribes the manager to a session's error changes so the SwiftUI banner refreshes when a player or web view starts / clears a failure.
    func observeRuntimeErrors(for session: any WallpaperRuntimeSession) {
        let notify: @MainActor () -> Void = { [weak self] in
            self?.markWallpaperSessionStateChanged()
        }
        if let session = session as? VideoWallpaperSession {
            session.onRuntimeErrorChange = notify
        } else if let session = session as? AmbientWallpaperSession {
            session.onRuntimeErrorChange = notify
        }
        #if !LITE_BUILD
        if let session = session as? SceneWallpaperSession {
            session.onRuntimeErrorChange = notify
        }
        #endif
    }

    func wallpaperDisplayName(for screen: Screen) -> String? {
        guard let configuration = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint),
              let definition = WallpaperSessionDefinition(configuration: configuration) else { return nil }

        return definition.displayName(using: { bookmarkDisplayName(for: $0) })
    }

    func bookmarkDisplayName(for bookmarkData: Data) -> String? {
        bookmarkDisplayNameCache.name(for: bookmarkData)
    }

    func currentVideoDisplayName(for screen: Screen) -> String? {
        guard let config = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint) else { return nil }
        let cursor = config.playlistCursorIndex ?? 0
        let combined = [config.savedVideoBookmarkData].compactMap { $0 } + (config.playlistBookmarks ?? [])
        guard cursor < combined.count else {
            return config.savedVideoBookmarkData.flatMap { bookmarkDisplayName(for: $0) }
        }
        return bookmarkDisplayName(for: combined[cursor])
    }

    func recordBookmarkDisplayName(_ bookmarkData: Data, name: String?) {
        bookmarkDisplayNameCache.record(bookmarkData, name: name)
    }

    func primeBookmarkDisplayNames(from configuration: ScreenConfiguration) {
        persistence.primeDisplayNames(from: configuration)
    }

    /// Builds the next session-state snapshot and commits it iff something actually changed.
    func commitWallpaperSessionState(includePollingRefresh: Bool = false) {
        var next = wallpaperSessionState
        next.summaryCache = WallpaperSessionSummaryCache(
            entries: screens.map { ($0.id, effectiveSummary(for: $0)) }
        )
        next.isAnyPlaying = screens.contains { $0.playbackController?.isPlaying ?? false }

        let derivedChanged = next.summaryCache != wallpaperSessionState.summaryCache
            || next.isAnyPlaying != wallpaperSessionState.isAnyPlaying
        if derivedChanged {
            next.version &+= 1
            wallpaperSessionState = next
            if playbackStateSubject.value != next.isAnyPlaying {
                playbackStateSubject.send(next.isAnyPlaying)
            }
        }

        if includePollingRefresh {
            updateFullScreenFallbackPolling()
        }
    }

    func markWallpaperSessionStateChanged() {
        commitWallpaperSessionState()
    }

    func notifyWallpaperSessionChanged() {
        commitWallpaperSessionState(includePollingRefresh: true)
        if effectsCoordinatorWasInitialized {
            effectsCoordinator.reconcileEnvironmentOverlays()
        }
    }

    func togglePlayback() {
        guard hasControllableWallpaperSessions else { return }

        // Decide from user INTENT, not actual playback: a policy-suspended video reads `isPlaying == false` but the user still "intends" to play, so toggling must flip intent, not chase the suppressed state.
        let anyIntendsToPlay = screens.contains { $0.playbackController?.userIntendsToPlay ?? false }

        Logger.info("Toggling global playback: \(anyIntendsToPlay ? "pausing" : "playing") all videos", category: .videoPlayer)

        for screen in screens {
            guard let playback = screen.playbackController else { continue }
            if anyIntendsToPlay {
                playback.pause()
            } else {
                playback.play()
            }
        }

        markWallpaperSessionStateChanged()
    }

    /// Per-screen play/pause toggle.
    func togglePlayback(for screen: Screen) {
        guard let playback = screen.playbackController else { return }
        if playback.userIntendsToPlay {
            playback.pause()
        } else {
            playback.play()
        }
        markWallpaperSessionStateChanged()
        refreshAppNapAssertion()
    }

    /// Master render gate.
    func setWallpapersEnabled(_ enabled: Bool) {
        guard !isTerminating else { return }
        wallpapersGloballyEnabled = enabled
        UserDefaults.appScoped().set(enabled, forKey: Self.globallyEnabledDefaultsKey)
        Logger.info("\(enabled ? "Enabling" : "Disabling") all wallpaper rendering (master gate)", category: .screenManager)

        applyGlobalRenderGate()
        markWallpaperSessionStateChanged()
    }

    /// Apply the master gate to every screen.
    func applyGlobalRenderGate() {
        guard !isTerminating else { return }
        for screen in screens {
            if wallpapersGloballyEnabled {
                if screen.runtimeSession == nil {
                    loadConfigurationForScreen(screen)
                } else {
                    // Idempotent re-enable: just show the live window.
                    screen.runtimeSession?.show()
                }
            } else if screen.runtimeSession != nil {
                releaseRuntimeSession(screen)
            }
        }

        if wallpapersGloballyEnabled {
            refreshPerformancePolicyForAllScreens()
            if effectsCoordinatorWasInitialized {
                effectsCoordinator.reconcileEnvironmentOverlays()
            }
        }
    }
    
    // MARK: - On-lock Desktop Picture Capture

    func updateSetAsDesktopPicture(_ enabled: Bool, for screen: Screen) {
        guard !isTerminating else { return }
        guard var config = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint),
              config.setAsLockScreen != enabled else { return }
        config.setAsLockScreen = enabled
        saveConfiguration(config)
    }

    /// Returns `true` when a frame extraction request was actually issued (player exists with a `currentItem`).
    @discardableResult
    func extractLockScreenFrame(for screen: Screen) -> Bool {
        guard !isTerminating else { return false }
        guard let player = screen.videoPlayer?.player else { return false }

        return DesktopPictureFrameExtractor.applyCurrentFrame(
            from: player,
            screenID: screen.id,
            nsScreen: displayRegistry.findNSScreen(for: screen.id)
        )
    }

    // MARK: - Wallpaper Type Switching

    func switchToVideoWallpaper(for screen: Screen) {
        guard !isTerminating else { return }
        beginExplicitWallpaperSelection(for: screen)
        guard var config = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint) else { return }
        let previousWallpaper = config.activeWallpaper
        guard config.activateSavedVideoWallpaper() else { return }

        if previousWallpaper == config.activeWallpaper,
           screen.runtimeSession?.wallpaperType == .video {
            Logger.info("Video wallpaper already active for screen \(screen.id); keeping existing player session", category: .screenManager)
            return
        }

        restoreProposedWallpaperSession(for: screen, configuration: config)
    }

    /// Restore previously-applied HTML source after the user toggles the type picker back to HTML.
    func switchToHTMLWallpaper(for screen: Screen) {
        guard !isTerminating else { return }
        beginExplicitWallpaperSelection(for: screen)
        guard var config = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint) else { return }
        let previousWallpaper = config.activeWallpaper
        guard config.activateSavedHTMLWallpaper() else { return }

        if previousWallpaper == config.activeWallpaper,
           screen.runtimeSession?.wallpaperType == .html {
            Logger.info("HTML wallpaper already active for screen \(screen.id); keeping existing WKWebView session", category: .screenManager)
            return
        }

        restoreProposedWallpaperSession(for: screen, configuration: config)
    }

    // MARK: - HTML Wallpaper (delegates to HTMLWallpaperCoordinator)

    func setHTMLWallpaper(
        source: HTMLSource,
        config: HTMLConfig = .default,
        forceReload: Bool = false,
        bookmarkID: UUID? = nil,
        wpeOrigin: WPEOrigin? = nil,
        for screen: Screen
    ) {
        guard !isTerminating else { return }
        beginExplicitWallpaperSelection(for: screen)
        htmlCoordinator.setWallpaper(
            source: source,
            config: config,
            forceReload: forceReload,
            bookmarkID: bookmarkID,
            wpeOrigin: wpeOrigin,
            for: screen
        )
    }

    func setHTMLWallpaperPreservingConfig(source: HTMLSource, for screen: Screen) {
        guard !isTerminating else { return }
        beginExplicitWallpaperSelection(for: screen)
        htmlCoordinator.setWallpaperPreservingConfig(source: source, for: screen)
    }

    func setHTMLWallpaper(url: String, for screen: Screen) {
        guard !isTerminating else { return }
        beginExplicitWallpaperSelection(for: screen)
        htmlCoordinator.setWallpaper(url: url, for: screen)
    }

    func updateHTMLConfig(_ config: HTMLConfig, for screen: Screen) {
        guard !isTerminating else { return }
        htmlCoordinator.updateConfig(config, for: screen)
    }
}
