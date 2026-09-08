import Foundation
import LiveWallpaperCore

@MainActor
extension ScreenManager {
    #if !LITE_BUILD
    func captureActiveSceneFailure(_ session: SceneWallpaperSession) {
        guard let error = session.loadError,
              let screen = screens.first(where: { $0.runtimeSession === session }),
              wallpaperLoads.attempt(for: screen) == nil,
              let config = getConfiguration(for: screen), case let .scene(descriptor) = config.activeWallpaper else { return }
        let id = wallpaperLoads.begin(for: screen, title: config.wpeOrigin?.title ?? wallpaperDisplayName(for: screen) ?? "", origin: config.wpeOrigin)
        wallpaperLoads.update(id, for: screen) { $0.configuration = config; $0.phase = .preparing }
        let cause = session.loadFailureCause ?? SceneFailureCause.make(error)
        Task { @MainActor [weak self, weak screen, weak session] in
            guard let self, let screen, let session else { return }
            await session.pollRendererState()
            guard screen.runtimeSession === session, session.loadError != nil else {
                wallpaperLoads.clear(for: screen, matching: id)
                return
            }
            let diagnostics = WPERenderDiagnosticReport.make(descriptor: descriptor, diagnostics: session.rendererDiagnostics, errorCode: cause.code)
            failWallpaperAttempt(id, for: screen, cause: cause, stage: "runtime", diagnostics: diagnostics)
        }
    }

    func recordSceneImportFailure(_ cause: WallpaperFailureCause, origin: WPEOrigin?, descriptor: SceneDescriptor?, for screen: Screen) {
        guard let attempt = wallpaperLoads.attempt(for: screen) else { return }
        wallpaperLoads.update(attempt.id, for: screen) {
            if let origin {
                $0.origin = origin; $0.title = origin.title
            }
            if let descriptor {
                var config = getConfiguration(for: screen) ?? ScreenConfiguration(screenID: screen.id, wallpaper: .scene(descriptor))
                config.activeWallpaper = .scene(descriptor)
                config.wpeOrigin = origin
                $0.configuration = config
            }
        }
        failWallpaperAttempt(attempt.id, for: screen, cause: cause, stage: "import")
    }
    #endif

    func inspectedWallpaperAttempt(for screen: Screen) -> WallpaperLoadAttempt? {
        guard let attempt = wallpaperLoads.attempt(for: screen), attempt.isInspecting else { return nil }
        return attempt
    }

    func failWallpaperAttempt(_ id: UUID, for screen: Screen, cause: WallpaperFailureCause, stage: String, diagnostics: String = "") {
        guard let attempt = wallpaperLoads.attempt(for: screen), attempt.id == id else { return }
        let failure = WallpaperFailureSnapshot(
            id: id, title: LogPrivacyRedactor.scrub(attempt.title), workshopID: attempt.origin?.workshopID,
            displayName: LogPrivacyRedactor.scrub(screen.name), stage: stage, cause: cause,
            previousWallpaper: screen.runtimeSession == nil ? nil : wallpaperOriginTitle(for: screen) ?? wallpaperDisplayName(for: screen),
            timestamp: Date(), diagnostics: LogPrivacyRedactor.scrub(diagnostics),
            wallpaperType: attempt.configuration?.wallpaperType ?? (attempt.origin?.originalType == .scene ? .scene : nil)
        )
        wallpaperLoads.update(id, for: screen) {
            $0.phase = .failed
            $0.failure = failure
        }
        #if !LITE_BUILD
        WorkshopToastCenter.shared.postFailure(failure, screenID: screen.id)
        #endif
    }

    func inspectWallpaperAttempt(_ inspect: Bool, for screen: Screen) {
        guard let attempt = wallpaperLoads.attempt(for: screen) else { return }
        wallpaperLoads.update(attempt.id, for: screen) { $0.isInspecting = inspect }
    }

    func updateAttemptDescriptor(_ descriptor: SceneDescriptor, attemptID: UUID, for screen: Screen) {
        wallpaperLoads.update(attemptID, for: screen) { attempt in
            guard var config = attempt.configuration else { return }
            config.activeWallpaper = .scene(descriptor)
            attempt.configuration = config
        }
    }

    func retryWallpaperAttempt(for screen: Screen) {
        guard !isTerminating, let attempt = wallpaperLoads.attempt(for: screen), attempt.phase == .failed else { return }
        if let config = attempt.configuration {
            beginExplicitWallpaperSelection(for: screen)
            restoreProposedWallpaperSession(for: screen, configuration: config)
        } else {
            #if !LITE_BUILD
            Task { @MainActor [weak self, weak screen] in
                guard let self, let screen,
                      wallpaperLoads.attempt(for: screen)?.id == attempt.id,
                      screens.contains(where: { $0 === screen }) else { return }
                if let origin = attempt.origin {
                    await activateWPEHistoryEntry(WPEHistoryEntry(origin: origin, importedAt: Date(), lastUsedAt: nil), for: screen)
                } else if let url = attempt.sourceURL {
                    await importWallpaperEngineProject(at: url, for: screen)
                }
            }
            #endif
        }
    }
}
