import CoreGraphics
import Foundation
import LiveWallpaperCore

extension ScreenManager {
    /// The store still describes the running scene here: proposals persist only in `beforeCommit`.
    private func runningSceneWorkshopID(for screen: Screen) -> String? {
        guard let stored = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint),
              case let .scene(current) = stored.activeWallpaper else { return nil }
        return current.workshopID
    }

    @discardableResult
    func activateAmbientWallpaper(
        _ definition: WallpaperSessionDefinition,
        for screen: Screen,
        configuration: ScreenConfiguration,
        beforeCommit: @MainActor @escaping () -> Bool = { true },
        completion: WallpaperPreparationCompletion? = nil
    ) -> RuntimePreparationWork? {
        guard !isTerminating else {
            completion?(.cancelled, nil)
            return nil
        }
        let generation = bumpTransition(for: screen.id)
        let expected = screen.runtimeSession
        let attemptID: UUID?
        if case .scene(let descriptor) = definition {
            let current = wallpaperLoads.attempt(for: screen)
            // Rebuilding the scene that is already on screen (a property change) must not swap the detail page to the attempt views.
            let rebuildsRunningScene = screen.runtimeSession?.wallpaperType == .scene
                && runningSceneWorkshopID(for: screen) == descriptor.workshopID
            let id = current?.phase == .importing ? current!.id : wallpaperLoads.begin(for: screen, title: configuration.wpeOrigin?.title ?? definition.displayName(using: { bookmarkDisplayName(for: $0) }) ?? String(localized: "Scene wallpaper", bundle: .appLanguage), origin: configuration.wpeOrigin, inspecting: !rebuildsRunningScene)
            wallpaperLoads.update(id, for: screen) {
                $0.configuration = configuration
                $0.origin = configuration.wpeOrigin
                $0.title = configuration.wpeOrigin?.title ?? $0.title
                $0.phase = .preparing
            }
            attemptID = id
        } else {
            attemptID = nil
        }
        let candidate: any WallpaperRuntimeSession
        let timeout: Duration
        var afterCommit: @MainActor () -> Void = {}
        // Keep bookmark-refreshed config for commit (do not write the stale grant).
        var effectiveCommitConfiguration = configuration

        switch definition {
        case .html(let source, let htmlConfig):
            let effectiveSource = ambientSessionBuilder.refreshingHTMLSource(
                source,
                onBookmarkRefresh: { [weak self] original, refreshed in
                    self?.persistRuntimeHTMLBookmarkRefresh(
                        matching: original,
                        with: refreshed
                    )
                }
            )
            let isLeader = htmlCoordinator.isAudioLeader(source: effectiveSource, for: screen.id)
            let effectiveConfig = htmlCoordinator.runtimeConfig(
                source: effectiveSource,
                config: htmlConfig,
                for: screen
            )
            var preparationConfig = effectiveConfig
            preparationConfig.muteAudio = true
            preparationConfig.audioVolume = 0
            var finalEffectiveSource = effectiveSource
            let session = ambientSessionBuilder.makeHTMLSession(
                source: effectiveSource,
                config: preparationConfig,
                frame: screen.frame,
                onBookmarkRefresh: { [weak self] original, refreshed in
                    if let updated = finalEffectiveSource.replacingLocalBookmark(
                        matching: original,
                        with: refreshed
                    ) {
                        finalEffectiveSource = updated
                    }
                    self?.persistRuntimeHTMLBookmarkRefresh(
                        matching: original,
                        with: refreshed
                    )
                }
            )
            if let original = source.localBookmarkData,
               let refreshed = finalEffectiveSource.localBookmarkData,
               original != refreshed {
                if let origin = configuration.wpeOrigin,
                   origin.sourceFolderBookmark == original,
                   let updated = configuration.replacingWPEOriginBookmark(
                    workshopID: origin.workshopID,
                    matching: original,
                    with: refreshed
                ) {
                    effectiveCommitConfiguration = updated
                } else if let updated = configuration.replacingHTMLBookmark(
                    matching: original,
                    with: refreshed
                ) {
                    effectiveCommitConfiguration = updated
                }
            }
            // Seeded here: the coordinator only pushes the limit when the user changes it, so a session rebuilt by a wallpaper switch or a relaunch would otherwise run unthrottled until the next edit.
            session.setFrameRateCeiling(
                configuration.frameRateLimit.frameRate(
                    forRefreshRate: Double(getScreenRefreshRate(for: screen.id))
                )
            )
            candidate = session
            if case .url = effectiveSource {
                timeout = Self.longPreparationTimeout
            } else {
                timeout = .seconds(5)
            }
            afterCommit = {
                _ = session.applyHTMLConfig(effectiveConfig)
            }
            Logger.notice("Preparing HTML wallpaper for screen \(screen.id) — \(LogPrivacyRedactor.sanitizedTitle(effectiveSource.displayName)) [leader=\(isLeader)]", category: .screenManager)
        case .scene(let descriptor):
            #if !LITE_BUILD
            let runtimeOrigin: WPEOrigin? = if !descriptor.dependencyWorkshopIDs.isEmpty,
                                               let origin = configuration.wpeOrigin {
                ambientSessionBuilder.refreshingWPEOrigin(
                    origin,
                    onOriginBookmarkRefresh: { [weak self] origin, refreshed in
                        self?.persistRuntimeWPEBookmarkRefresh(
                            origin: origin,
                            with: refreshed
                        )
                    }
                )?.origin ?? origin
            } else {
                configuration.wpeOrigin
            }
            var finalRuntimeOrigin = runtimeOrigin
            let dependencyMounts = WPEDependencyMountResolver().mounts(
                dependencyWorkshopIDs: descriptor.dependencyWorkshopIDs,
                origin: runtimeOrigin
            )
            let engineRoot = WPEEngineAssetsLibrary.shared.resolveAuthorizedRoot()
            guard let sceneSession = makeSceneRuntimeSession(
                descriptor: descriptor,
                origin: runtimeOrigin,
                screen: screen,
                configuration: configuration,
                dependencyMounts: dependencyMounts,
                engineAssetsRootURL: engineRoot,
                onOriginBookmarkRefresh: { [weak self] origin, refreshed in
                    finalRuntimeOrigin = origin.replacingSourceFolderBookmark(
                        matching: origin.sourceFolderBookmark,
                        with: refreshed
                    ) ?? finalRuntimeOrigin
                    self?.persistRuntimeWPEBookmarkRefresh(
                        origin: origin,
                        with: refreshed
                    )
                }
            ) else {
                if let attemptID {
                    failWallpaperAttempt(attemptID, for: screen, cause: WallpaperFailureCause(code: "scene.source_unavailable", reason: String(localized: "The scene source could not be opened. Check its location and access permission.", bundle: .appLanguage)), stage: .source)
                }
                Logger.warning("Scene wallpaper for screen \(screen.id) (workshop \(descriptor.workshopID)) could not be built — cache missing or descriptor invalid", category: .screenManager)
                completion?(.failed, wallpaperLoads.attempt(for: screen)?.failure)
                return nil
            }
            if let originalOrigin = configuration.wpeOrigin,
               let finalRuntimeOrigin,
               originalOrigin.sourceFolderBookmark != finalRuntimeOrigin.sourceFolderBookmark,
               let updated = configuration.replacingWPEOriginBookmark(
                workshopID: originalOrigin.workshopID,
                matching: originalOrigin.sourceFolderBookmark,
                with: finalRuntimeOrigin.sourceFolderBookmark
            ) {
                effectiveCommitConfiguration = updated
            }
            sceneSession.frameRateController?.setFrameRateCeiling(
                configuration.frameRateLimit.frameRate(
                    forRefreshRate: Double(getScreenRefreshRate(for: screen.id))
                )
            )
            sceneSession.setMouseInteractionEnabled(configuration.sceneMouseInteractionEnabled)
            sceneSession.setClickCaptureEnabled(false)
            // Fit mode is a construction argument now (see `makeSceneSession`);
            // re-submitting it here would just be a second source for the value.
            if let audio = sceneSession.audioController {
                audio.setAudioMuted(true)
                audio.setAudioVolume(configuration.videoVolume)
            }
            candidate = sceneSession
            timeout = Self.longPreparationTimeout
            afterCommit = {
                sceneSession.setClickCaptureEnabled(configuration.sceneClickCaptureEnabled)
                if let audio = sceneSession.audioController {
                    audio.setAudioMuted(configuration.muted)
                    audio.setAudioVolume(configuration.videoVolume)
                }
            }
            Logger.notice("Preparing scene wallpaper (workshop \(descriptor.workshopID))\(LogPrivacyRedactor.titleFragment(configuration.wpeOrigin?.title)) for screen \(screen.id)", category: .screenManager)
            #else
            _ = descriptor
            completion?(.failed, nil)
            return nil
            #endif
        case .video:
            completion?(.failed, nil)
            return nil
        }

        // Fail closed if config revision advances while this candidate prepares.
        let expectedConfigurationRevision = configurationStore.revision(for: screen.id)
        var outgoingVideoPlayerAtCommit: WallpaperVideoPlayer?
        let transactionalBeforeCommit: @MainActor () -> Bool = { [weak self] in
            guard let self,
                  self.commitPreparedAmbientConfiguration(
                proposed: configuration,
                effective: effectiveCommitConfiguration,
                screenID: screen.id,
                ownerCommit: beforeCommit
            ) else {
                return false
            }
            // Capture outgoing player in the same installRuntimeSession CAS turn.
            outgoingVideoPlayerAtCommit =
                (expected as? VideoWallpaperSession)?.videoPlayer
            return true
        }
        let transactionalAfterCommit: @MainActor () -> Void = { [weak self] in
            self?.retireOutgoingVideoWork(
                for: screen.id,
                player: outgoingVideoPlayerAtCommit
            )
            afterCommit()
        }
        return beginPreparedAmbientSession(
            candidate,
            for: screen,
            replacing: expected,
            generation: generation,
            attemptID: attemptID,
            proposedConfiguration: configuration,
            expectedConfigurationRevision: expectedConfigurationRevision,
            timeout: timeout,
            beforeCommit: transactionalBeforeCommit,
            afterCommit: transactionalAfterCommit,
            completion: completion
        )
    }
}
