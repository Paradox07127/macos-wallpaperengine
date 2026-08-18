import AVFoundation
import Foundation
import LiveWallpaperCore

@MainActor
extension PlaybackCoordinator {
    // MARK: - Video session lifecycle

    func setVideo(url: URL, bookmarkData: Data, packageEntryName: String? = nil, for screen: Screen) {
        guard isRuntimeInstallationAllowed() else { return }
        Logger.info("Setting video for screen \(screen.id): \(url.lastPathComponent)", category: .screenManager)

        let existing = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint)
        // In-flight config writes are newer intent; candidate fails closed at commit.
        let expectedConfigurationRevision = configurationStore.revision(for: screen.id)
        // Identity is (URL, package entry) — same pkg path can host distinct media.
        let isSameURL = bookmarkResolves(to: url, bookmark: existing?.videoBookmarkData)
            && existing?.activeWallpaper.packageVideoEntryName == packageEntryName

        let previousContent = existing?.activeWallpaper
        var configuration: ScreenConfiguration
        if var prior = existing {
            prior.replacePrimaryVideo(bookmarkData: bookmarkData, packageEntryName: packageEntryName)
            configuration = prior
        } else {
            configuration = ScreenConfiguration(screenID: screen.id, videoBookmarkData: bookmarkData)
            // Preserve package entry on active+saved so type-swap restore doesn't downgrade.
            configuration.activeWallpaper = .video(bookmarkData: bookmarkData, packageEntryName: packageEntryName)
            configuration.savedVideoPackageEntryName = packageEntryName
            configuration.resetPlayback(to: SettingsManager.shared.loadDisplayDefaults())
        }
        originReconciler.reconcile(
            &configuration,
            event: .userReplacedActiveWallpaper(previous: previousContent)
        )

        if isSameURL, screen.videoPlayer != nil {
            applyConfiguration(
                configuration,
                to: screen,
                preservingState: true,
                intent: .proposal,
                beforeCommit: { [weak self] in
                    guard let self else { return false }
                    self.save(configuration)
                    return true
                }
            )
            reportRuntimeError(screen.id, nil)
            return
        }

        let screenID = screen.id
        let generation = transition.bumpTransition(for: screenID)
        let videoLoader = playableVideoLoader
        reportRuntimeError(screenID, nil)
        let task = Task {
            do {
                try Task.checkCancellation()
                if let packageEntryName {
                    try await WallpaperVideoPlayer.validatePackagedVideo(
                        packageURL: url,
                        entryName: packageEntryName
                    )
                } else {
                    try await videoLoader.validatePlayableVideo(at: url)
                }
                try Task.checkCancellation()
                await MainActor.run { [weak self] in
                    guard let self,
                          self.isRuntimeInstallationAllowed(),
                          self.transition.isCurrentTransition(generation, for: screenID),
                          self.configurationStore.revision(for: screenID)
                              == expectedConfigurationRevision,
                          let liveScreen = self.screensProvider().first(where: { $0.id == screenID }) else { return }
                    self.reportRuntimeError(screenID, nil)
                    self.beginPreparedVideoSession(
                        url: url,
                        screen: liveScreen,
                        configuration: configuration,
                        transitionGeneration: generation,
                        expectedConfigurationRevision: expectedConfigurationRevision,
                        beforeCommit: {
                            self.save(configuration)
                            guard SettingsManager.shared.validateConfiguration(for: screenID) else {
                                Logger.error("Failed to save video configuration for screen \(screenID)", category: .screenManager)
                                if let existing {
                                    self.save(existing)
                                } else {
                                    self.removeConfiguration(for: screenID)
                                }
                                return false
                            }
                            return true
                        }
                    )
                }
            } catch is CancellationError {
                // Superseded before validate returned — not an error.
                return
            } catch {
                let runtimeError = Self.runtimeError(from: error, url: url)
                let message = error.localizedDescription
                await MainActor.run { [weak self] in
                    guard let self,
                          self.isRuntimeInstallationAllowed(),
                          self.transition.isCurrentTransition(generation, for: screenID),
                          self.configurationStore.revision(for: screenID)
                              == expectedConfigurationRevision else { return }
                    self.reportRuntimeError(screenID, runtimeError)
                    Logger.error("Failed to setup video: \(message)", category: .screenManager)
                }
            }
        }
        transition.setValidationTask(task, for: screenID)
    }

    func applyConfiguration(
        _ configuration: ScreenConfiguration,
        to screen: Screen,
        preservingState: Bool = false,
        forceReplacement: Bool = false,
        intent: WallpaperSessionRestoreIntent = .persistedConfiguration,
        beforeCommit: @MainActor @escaping () -> Bool = { true }
    ) {
        guard isRuntimeInstallationAllowed() else { return }
        let expectedConfigurationRevision = configurationStore.revision(for: screen.id)
        do {
            guard let bookmarkData = configuration.videoBookmarkData else {
                throw NSError(domain: "ScreenManager", code: 400, userInfo: [
                    NSLocalizedDescriptionKey: "No saved video bookmark is available for this screen."
                ])
            }

            let resolved: SecurityScopedBookmarkResolver.Resolved
            switch bookmarkResolver.resolve(bookmarkData, target: .transient) {
            case .success(let value):
                resolved = value
            case .failure(let failure):
                Logger.error(
                    "Failed to apply configuration: \(failure.localizedDescription)",
                    category: .screenManager
                )
                if intent == .persistedConfiguration {
                    Logger.warning(
                        "Clearing unresolvable persisted bookmark for screen \(screen.id); user must re-pick the source.",
                        category: .screenManager
                    )
                    removeConfiguration(for: screen.id)
                    releaseRuntimeSession(screen)
                    notifyWallpaperSessionChanged()
                }
                return
            }

            let url = resolved.url
            let effectiveConfiguration: ScreenConfiguration
            if resolved.didRefresh {
                effectiveConfiguration = configuration.withUpdatedActiveBookmark(resolved.bookmarkData)
            } else {
                effectiveConfiguration = configuration
            }

            guard url.startAccessingSecurityScopedResource() else {
                guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
                    throw NSError(domain: "ScreenManager", code: 403, userInfo: [
                        NSLocalizedDescriptionKey: "Cannot access the video file. Permission denied."
                    ])
                }
                return applyConfigurationForAccessibleURL(
                    url,
                    configuration: effectiveConfiguration,
                    screen: screen,
                    preservingState: preservingState,
                    forceReplacement: forceReplacement,
                    expectedConfigurationRevision: expectedConfigurationRevision,
                    beforeCommit: {
                        guard beforeCommit() else { return false }
                        if resolved.didRefresh {
                            self.save(effectiveConfiguration)
                        }
                        return true
                    }
                )
            }
            defer { url.stopAccessingSecurityScopedResource() }

            applyConfigurationForAccessibleURL(
                url,
                configuration: effectiveConfiguration,
                screen: screen,
                preservingState: preservingState,
                forceReplacement: forceReplacement,
                expectedConfigurationRevision: expectedConfigurationRevision,
                beforeCommit: {
                    guard beforeCommit() else { return false }
                    if resolved.didRefresh {
                        self.save(effectiveConfiguration)
                    }
                    return true
                }
            )
        } catch let error as NSError {
            Logger.error("Failed to apply configuration: \(error.localizedDescription) [domain=\(error.domain) code=\(error.code)]", category: .screenManager)
        } catch {
            Logger.error("Failed to apply configuration: \(error.localizedDescription)", category: .screenManager)
        }
    }

    private func applyConfigurationForAccessibleURL(
        _ url: URL,
        configuration: ScreenConfiguration,
        screen: Screen,
        preservingState: Bool,
        forceReplacement: Bool,
        expectedConfigurationRevision: UInt64,
        beforeCommit: @MainActor @escaping () -> Bool
    ) {
        let existingPlayer = screen.videoPlayer
        let needsNewPlayer = forceReplacement || existingPlayer == nil ||
            Self.videoAudioURLKey(for: existingPlayer?.videoURL) != Self.videoAudioURLKey(for: url) ||
            existingPlayer?.packageEntryName != configuration.activeWallpaper.packageVideoEntryName

        if !needsNewPlayer, let player = existingPlayer {
            guard beforeCommit() else { return }
            let currentTime = preservingState ? player.player?.currentTime() : .zero

            player.setVideoFitMode(configuration.fitMode)

            let currentSpeed = player.player?.defaultRate ?? 1.0
            if abs(Float(configuration.playbackSpeed) - currentSpeed) > 0.01 {
                player.setPlaybackSpeed(configuration.playbackSpeed)
            }

            if player.videoFrameRate > 0 {
                if configuration.effectConfig.hasActiveEffect {
                    applyVideoEffects(screen, configuration)
                } else {
                    applyFrameRateLimit(configuration.frameRateLimit, to: screen)
                }
            }

            if let currentTime {
                player.player?.seek(to: currentTime)
            }
            // Trailing applyPolicy owns play/pause so re-apply never unpauses the user.
        } else {
            let generation = transition.bumpTransition(for: screen.id)
            beginPreparedVideoSession(
                url: url,
                screen: screen,
                configuration: configuration,
                transitionGeneration: generation,
                expectedConfigurationRevision: expectedConfigurationRevision,
                beforeCommit: beforeCommit
            )
            return
        }

        reportRuntimeError(screen.id, nil)
        syncVideoAudioLeadership()
        applyVideoSpanLayout()
        // Fresh session defaults intent=true; profile decides actual play.
        applyPolicy(screen)
    }

    /// Automation-validated URL; keep proposed cursor/schedule private until CAS wins.
    func setupVideoPlayback(
        url: URL,
        screen: Screen,
        proposedConfiguration: ScreenConfiguration,
        beforeCommit: @MainActor @escaping () -> Bool = { true }
    ) {
        let generation = transition.bumpTransition(for: screen.id)
        let expectedConfigurationRevision = configurationStore.revision(for: screen.id)
        guard isRuntimeInstallationAllowed() else { return }
        guard isGloballyEnabled() else {
            guard beforeCommit() else { return }
            save(proposedConfiguration)
            releaseRuntimeSession(screen)
            notifyWallpaperSessionChanged()
            return
        }
        beginPreparedVideoSession(
            url: url,
            screen: screen,
            configuration: proposedConfiguration,
            transitionGeneration: generation,
            expectedConfigurationRevision: expectedConfigurationRevision,
            beforeCommit: { [weak self] in
                guard let self else { return false }
                guard beforeCommit() else { return false }
                self.save(proposedConfiguration)
                return true
            }
        )
    }

    private func beginPreparedVideoSession(
        url: URL,
        screen: Screen,
        configuration: ScreenConfiguration?,
        transitionGeneration: Int,
        expectedConfigurationRevision: UInt64,
        beforeCommit: @MainActor @escaping () -> Bool = { true }
    ) {
        guard let liveScreen = screensProvider().first(where: { $0.id == screen.id }) else {
            Logger.warning("Screen with ID \(screen.id) not found in screens array", category: .screenManager)
            return
        }

        let player = WallpaperVideoPlayer(
            url: url,
            frame: liveScreen.frame,
            fitMode: configuration?.fitMode ?? .aspectFill,
            packageEntryName: configuration?.activeWallpaper.packageVideoEntryName,
            startsHidden: true
        )

        if let configuration {
            player.setVolume(configuration.videoVolume)
            player.setVideoColorSpace(configuration.videoColorSpace)
            player.setPlaybackSpeed(configuration.playbackSpeed)
            if configuration.particleEffect != .none {
                player.setParticleEffect(
                    configuration.particleEffect,
                    density: configuration.effectConfig.particleDensity
                )
            }
        }
        // Candidate stays silent; leadership restores mute only after commit.
        player.setMuted(true)

        let expected = liveScreen.runtimeSession
        let screenID = liveScreen.id
        var outgoingVideoPlayerAtCommit: WallpaperVideoPlayer?
        let session = VideoWallpaperSession(
            player: player,
            effectsWorkRevisionProvider: { [weak self] player in
                self?.effectsWorkRevision(screenID, player)
            },
            effectsWorkIsActiveProvider: { [weak self] player in
                self?.effectsWorkIsActive(screenID, player) ?? false
            },
            retireEffectsWork: { [weak self] player in
                self?.retireVideoEffectsWork(screenID, player)
            }
        )
        let work = RuntimePreparationWork()
        let task = Task { @MainActor [weak self, weak liveScreen, weak work] in
            guard let self, let liveScreen else {
                session.cleanup()
                return
            }
            let isCandidateStillCurrent: @MainActor () -> Bool = {
                [weak self, weak liveScreen] in
                guard let self, let liveScreen else { return false }
                return self.isRuntimeInstallationAllowed()
                    && self.isGloballyEnabled()
                    && self.screensProvider().first(where: { $0.id == screenID }) === liveScreen
                    && self.transition.isCurrentTransition(
                        transitionGeneration,
                        for: screenID
                    )
                    && self.configurationStore.revision(for: screenID)
                        == expectedConfigurationRevision
            }
            let result = await WallpaperSessionTransaction.prepareAndCommit(
                session,
                to: liveScreen,
                replacing: expected,
                timeout: .seconds(5),
                isStillCurrent: isCandidateStillCurrent,
                prepare: { [weak self, weak liveScreen] session, timeout in
                    let base = await session.prepareForDisplay(timeout: timeout)
                    guard base == .ready,
                          let self,
                          let liveScreen else { return base }
                    guard let configuration else {
                        return .ready
                    }
                    if configuration.effectConfig.hasActiveEffect {
                        let effectsPrepared = await self.prepareVideoEffects(
                            player,
                            liveScreen,
                            configuration
                        )
                        guard effectsPrepared else { return .failed }
                        return await player.prepareForCurrentComposition(
                            after: .ready,
                            timeout: timeout
                        )
                    }

                    let compositionLimit = PlainVideoFrameRateCompositionPolicy.compositionLimit(
                        frameRateLimit: configuration.frameRateLimit,
                        videoFrameRate: player.videoFrameRate,
                        screenRefreshRate: Double(self.refreshRateLookup(screenID))
                    )
                    guard let compositionLimit else {
                        // Force SDR composition may already be live post-load — consult it now.
                        return await player.prepareForCurrentComposition(
                            after: .ready,
                            timeout: timeout
                        )
                    }
                    let compositionPrepared = await player.prepareFrameRateLimit(
                        compositionLimit,
                        timeout: timeout
                    )
                    guard compositionPrepared == .ready else {
                        return compositionPrepared
                    }
                    return await player.prepareForCurrentComposition(
                        after: .ready,
                        timeout: timeout
                    )
                },
                beforeCommit: {
                    guard beforeCommit() else { return false }
                    // Capture inside install CAS: in-session retry can replace the player mid-warm.
                    outgoingVideoPlayerAtCommit = expected?.videoPlayer
                    return true
                },
                afterCommit: { [weak self, weak liveScreen] in
                    guard let self, let liveScreen else { return }
                    if let outgoingVideoPlayerAtCommit {
                        self.retireVideoEffectsWork(
                            screenID,
                            outgoingVideoPlayerAtCommit
                        )
                    }
                    session.onRuntimeErrorChange = {
                        [markSessionStateChanged = self.markSessionStateChanged] in
                        markSessionStateChanged()
                    }
                    if let configuration {
                        player.setMuted(configuration.muted)
                        self.applyConfigurationWhenAssetReady(
                            player: player,
                            screen: liveScreen
                        )
                    }
                    self.reportRuntimeError(screenID, nil)
                    self.resetPlaybackStateMachine(liveScreen)
                    self.applyPolicy(liveScreen)
                    self.syncVideoAudioLeadership()
                    self.refreshOtherAudioLeadership()
                    self.applyVideoSpanLayout()
                    Logger.info(
                        "Video player committed after first-frame readiness for screen \(screenID)",
                        category: .screenManager
                    )
                    self.notifyWallpaperSessionChanged()
                }
            )

            if WallpaperCandidateErrorPolicy.shouldPublish(
                result,
                isStillCurrent: isCandidateStillCurrent()
            ) {
                let error = session.runtimeError ?? .mediaNotPlayable(url, code: nil)
                self.reportRuntimeError(screenID, error)
                Logger.warning(
                    "Video candidate was not committed (\(String(describing: result))) for screen \(screenID); keeping prior session",
                    category: .screenManager
                )
            }
            if let work {
                self.transition.clearRuntimePreparationIfMatch(work, for: screenID)
            }
        }
        work.task = task
        transition.setRuntimePreparation(work, for: screenID)
    }
}
