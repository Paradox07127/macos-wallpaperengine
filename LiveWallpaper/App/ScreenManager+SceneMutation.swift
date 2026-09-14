import CoreGraphics
import Foundation
import LiveWallpaperCore

#if !LITE_BUILD
    import LiveWallpaperProWPE
#endif

@MainActor
extension ScreenManager {
    func advanceScenePropertyMutationIntent(for screenID: CGDirectDisplayID) {
        #if !LITE_BUILD
            guard let screen = screens.first(where: { $0.id == screenID }),
                  let session = screen.runtimeSession as? SceneWallpaperSession else {
                return
            }
            session.advanceScenePropertyMutationIntent()
        #else
            _ = screenID
        #endif
    }

    func isCurrentExplicitWallpaperSelection(
        _ generation: Int,
        expectedConfigurationRevision: UInt64,
        expectedSession: (any WallpaperRuntimeSession)?,
        expectedSceneMutationToken: ScenePropertyMutationToken? = nil,
        for screen: Screen
    ) -> Bool {
        guard !isTerminating,
              screens.first(where: { $0.id == screen.id }) === screen,
              isCurrentTransition(generation, for: screen.id),
              configurationStore.revision(for: screen.id)
              == expectedConfigurationRevision else {
            return false
        }
        switch (screen.runtimeSession, expectedSession) {
        case let (current?, expected?):
            guard ObjectIdentifier(current) == ObjectIdentifier(expected) else {
                return false
            }
            #if !LITE_BUILD
                if let expectedSceneMutationToken,
                   let sceneSession = current as? SceneWallpaperSession {
                    return sceneSession.isCurrentScenePropertyMutationIntent(
                        expectedSceneMutationToken
                    )
                }
                return expectedSceneMutationToken == nil
            #else
                return expectedSceneMutationToken == nil
            #endif
        case (nil, nil):
            return true
        default:
            return false
        }
    }

    func handleScenePresetLibraryChange() {
        guard !isTerminating else { return }
        var rendering: [CGDirectDisplayID: SceneDescriptor] = [:]
        for screen in screens {
            guard let configuration = configurationStore.get(
                for: screen.id,
                fingerprint: screen.displayFingerprint
            ), case let .scene(descriptor) = configuration.activeWallpaper,
            descriptor.presetID != nil else { continue }
            rendering[screen.id] = descriptor
        }
        configurationStore.clearCache()
        guard !rendering.isEmpty else { return }

        for screen in screens {
            guard let previous = rendering[screen.id],
                  let configuration = configurationStore.get(
                      for: screen.id,
                      fingerprint: screen.displayFingerprint
                  ),
                  case let .scene(reconciled) = configuration.activeWallpaper,
                  reconciled != previous else { continue }
            Task { @MainActor [weak self] in
                await self?.updateSceneDescriptor(reconciled, previous: previous, for: screen)
            }
        }
    }

    func updateSceneDescriptor(_ descriptor: SceneDescriptor, for screen: Screen) async {
        await updateSceneDescriptor(descriptor, previous: nil, for: screen)
    }

    /// previous is the descriptor the running session was last handed. It differs from the stored one only when something already wrote the new value to the store without going through a session.
    private func updateSceneDescriptor(
        _ descriptor: SceneDescriptor,
        previous: SceneDescriptor?,
        for screen: Screen
    ) async {
        guard !isTerminating else { return }
        // User edits are intent boundaries even when equal to persisted values.
        let generation = beginExplicitWallpaperSelection(for: screen)
        guard var configuration = configurationStore.get(
            for: screen.id,
            fingerprint: screen.displayFingerprint
        ) else { return }
        guard case let .scene(stored) = configuration.activeWallpaper,
              stored.workshopID == descriptor.workshopID else {
            return
        }
        let current = previous ?? stored
        guard current != descriptor else { return }
        let expectedSession = screen.runtimeSession
        let expectedConfigurationRevision = configurationStore.revision(for: screen.id)

        #if !LITE_BUILD
            if let sceneSession = screen.runtimeSession as? SceneWallpaperSession {
                let sceneMutationToken = sceneSession.currentScenePropertyMutationToken()
                let bindings = await sceneSession.scenePropertyBindings()
                guard isCurrentExplicitWallpaperSelection(
                    generation,
                    expectedConfigurationRevision: expectedConfigurationRevision,
                    expectedSession: expectedSession,
                    for: screen
                ) else { return }
                // Engine-level keys (`wec_*`, `volume`) are stripped by the property filter before the patch
                // is built, so they can never reach `changedKeys`. An engine-only preset change therefore
                // produced a *successful empty patch* — persisted and shown in the inspector, while the live
                // frame kept grading and playing from the descriptor it was loaded with. The renderer holds
                // that descriptor immutably, so a remount is what re-reads them.
                let engineSettingsChanged =
                    WPEEngineColorCorrection.parse(current.presetSnapshot)
                        != WPEEngineColorCorrection.parse(descriptor.presetSnapshot)
                    || WPEEngineAudioSettings.parse(current.presetSnapshot)
                        != WPEEngineAudioSettings.parse(descriptor.presetSnapshot)
                if !bindings.isEmpty, !engineSettingsChanged {
                    let patch = WPEScenePropertyPatch(
                        bindingsByProperty: bindings,
                        oldValues: effectiveSceneValues(
                            for: current,
                            origin: configuration.wpeOrigin
                        ),
                        newValues: effectiveSceneValues(
                            for: descriptor,
                            origin: configuration.wpeOrigin
                        )
                    )
                    if let preparedPatch = await sceneSession.prepareScenePropertyPatch(
                        patch,
                        expectedIntent: sceneMutationToken
                    ) {
                        guard isCurrentExplicitWallpaperSelection(
                            generation,
                            expectedConfigurationRevision: expectedConfigurationRevision,
                            expectedSession: expectedSession,
                            expectedSceneMutationToken: sceneMutationToken,
                            for: screen
                        ) else { return }
                        configuration.activeWallpaper = .scene(descriptor)
                        configuration.savedSceneDescriptor = descriptor
                        let posterCommit = sceneSession.stageScenePropertyPosterCommit(
                            overrides: descriptor.layeredPropertyValues()
                        )
                        saveConfiguration(configuration)
                        notifyWallpaperSessionChanged()
                        let committedRevision = configurationStore.revision(for: screen.id)
                        let didCommit = await sceneSession.commitScenePropertyPatch(
                            preparedPatch,
                            posterCommit: posterCommit,
                            updatedDescriptor: descriptor
                        )
                        if !didCommit {
                            restorePersistedSceneAfterFailedPatchDelivery(
                                descriptor,
                                committedRevision: committedRevision,
                                generation: generation,
                                expectedSession: expectedSession,
                                for: screen
                            )
                        }
                        return
                    }
                }
            }
        #endif

        guard isCurrentExplicitWallpaperSelection(
            generation,
            expectedConfigurationRevision: expectedConfigurationRevision,
            expectedSession: expectedSession,
            for: screen
        ) else { return }
        configuration.activeWallpaper = .scene(descriptor)
        configuration.savedSceneDescriptor = descriptor
        restoreProposedWallpaperSession(for: screen, configuration: configuration)
    }

    #if !LITE_BUILD
        private func restorePersistedSceneAfterFailedPatchDelivery(
            _ descriptor: SceneDescriptor,
            committedRevision: UInt64,
            generation: Int,
            expectedSession: (any WallpaperRuntimeSession)?,
            for screen: Screen
        ) {
            guard !isTerminating,
                  screens.first(where: { $0.id == screen.id }) === screen,
                  isCurrentTransition(generation, for: screen.id),
                  configurationStore.revision(for: screen.id) == committedRevision,
                  let currentSession = screen.runtimeSession,
                  let expectedSession,
                  ObjectIdentifier(currentSession) == ObjectIdentifier(expectedSession),
                  let latest = configurationStore.get(
                      for: screen.id,
                      fingerprint: screen.displayFingerprint
                  ),
                  latest.activeWallpaper == .scene(descriptor) else {
                return
            }
            restoreWallpaperSession(
                for: screen,
                configuration: latest,
                preservingState: false
            )
        }

        private func effectiveSceneValues(
            for descriptor: SceneDescriptor,
            origin: WPEOrigin?
        ) -> [String: WallpaperEngineProjectPropertyValue] {
            switch descriptor.assetStorage {
            case .cache:
                guard WPEPathSafety.isSafeCacheRelativePath(descriptor.cacheRelativePath),
                      let supportRoot = try? FileManager.default.url(
                          for: .applicationSupportDirectory,
                          in: .userDomainMask,
                          appropriateFor: nil,
                          create: false
                      ).appendingPathComponent("LiveWallpaper", isDirectory: true) else {
                    return descriptor.layeredPropertyValues()
                }
                let cacheRoot = supportRoot.appendingPathComponent(
                    descriptor.cacheRelativePath,
                    isDirectory: true
                )
                if FileManager.default.fileExists(atPath: cacheRoot.path) {
                    return WallpaperEngineProjectPropertySchema.effectiveSceneValues(
                        descriptor: descriptor,
                        cacheRootURL: cacheRoot
                    )
                }
                // Cache purged but the import source may still be resolvable — read
                // project.json in place so diffing matches lazy render fallback.
                guard let origin,
                      case let .success(resolved) = SecurityScopedBookmarkResolver.shared.resolve(
                          origin.sourceFolderBookmark,
                          target: .transient
                      ) else {
                    return descriptor.layeredPropertyValues()
                }
                return SecurityScopedBookmarkResolver.withScopedAccess(resolved.url) { _ in
                    WallpaperEngineProjectPropertySchema.effectiveSceneValues(
                        descriptor: descriptor,
                        cacheRootURL: resolved.url
                    )
                }
            case .sourceDirectory, .packageSource:
                guard let origin,
                      case let .success(resolved) = SecurityScopedBookmarkResolver.shared.resolve(
                          origin.sourceFolderBookmark,
                          target: .transient
                      ) else {
                    return descriptor.layeredPropertyValues()
                }
                return SecurityScopedBookmarkResolver.withScopedAccess(resolved.url) { _ in
                    WallpaperEngineProjectPropertySchema.effectiveSceneValues(
                        descriptor: descriptor,
                        cacheRootURL: resolved.url
                    )
                }
            }
        }
    #endif
}
