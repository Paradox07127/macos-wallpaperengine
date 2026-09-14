import CoreGraphics
import Foundation
import LiveWallpaperCore

@MainActor
final class PlaybackCoordinator {
    let transition = PlaybackTransitionRegistry()

    let configurationStore: WallpaperConfigurationStore
    let playableVideoLoader: any PlayableVideoLoading
    let bookmarkResolver: SecurityScopedBookmarkResolver
    let makeVideoPlayer: VideoWallpaperSession.RetryPlayerFactory
    let validateSavedVideoConfiguration: @MainActor (CGDirectDisplayID) -> Bool
    let applyPolicy: @MainActor (Screen) -> Void
    let applyVideoEffects: @MainActor (Screen, ScreenConfiguration) -> Void
    let prepareVideoEffects: @MainActor (
        WallpaperVideoPlayer,
        Screen,
        ScreenConfiguration
    ) async -> Bool
    /// Per-player effects generation for in-session retry CAS.
    let effectsWorkRevision: @MainActor (
        CGDirectDisplayID,
        WallpaperVideoPlayer
    ) -> UInt64?
    let effectsWorkIsActive: @MainActor (
        CGDirectDisplayID,
        WallpaperVideoPlayer
    ) -> Bool
    let retireVideoEffectsWork: @MainActor (
        CGDirectDisplayID,
        WallpaperVideoPlayer
    ) -> Void
    let refreshRateLookup: @MainActor (CGDirectDisplayID) -> Int
    let screensProvider: @MainActor () -> [Screen]
    let markSessionStateChanged: @MainActor () -> Void
    let releaseRuntimeSession: @MainActor (Screen) -> Void
    /// A committed session replacement must reset the per-screen playback
    /// state machine, or the outgoing session's intent would leak into it.
    let resetPlaybackStateMachine: @MainActor (Screen) -> Void
    let notifyWallpaperSessionChanged: @MainActor () -> Void
    let refreshOtherAudioLeadership: @MainActor () -> Void
    let notifyConfigurationChanged: @MainActor (CGDirectDisplayID) -> Void
    /// Invalidates queued scene-property mutations before store revision advances.
    let advanceSceneMutationIntent: @MainActor (CGDirectDisplayID) -> Void
    let reportRuntimeError: @MainActor (CGDirectDisplayID, WallpaperRuntimeError?) -> Void
    let originReconciler: any OriginReconciler
    let isGloballyEnabled: @MainActor () -> Bool
    let isRuntimeInstallationAllowed: @MainActor () -> Bool

    init(
        configurationStore: WallpaperConfigurationStore,
        playableVideoLoader: any PlayableVideoLoading,
        bookmarkResolver: SecurityScopedBookmarkResolver = .shared,
        makeVideoPlayer: @escaping VideoWallpaperSession.RetryPlayerFactory = { url, frame, fitMode, entryName in
            WallpaperVideoPlayer(
                url: url, frame: frame, fitMode: fitMode,
                packageEntryName: entryName, startsHidden: true
            )
        },
        validateSavedVideoConfiguration: @MainActor @escaping (CGDirectDisplayID) -> Bool = {
            SettingsManager.shared.validateConfiguration(for: $0)
        },
        applyPolicy: @MainActor @escaping (Screen) -> Void,
        applyVideoEffects: @MainActor @escaping (Screen, ScreenConfiguration) -> Void,
        prepareVideoEffects: @MainActor @escaping (
            WallpaperVideoPlayer,
            Screen,
            ScreenConfiguration
        ) async -> Bool = { _, _, _ in true },
        effectsWorkRevision: @MainActor @escaping (
            CGDirectDisplayID,
            WallpaperVideoPlayer
        ) -> UInt64? = { _, _ in nil },
        effectsWorkIsActive: @MainActor @escaping (
            CGDirectDisplayID,
            WallpaperVideoPlayer
        ) -> Bool = { _, _ in false },
        retireVideoEffectsWork: @MainActor @escaping (
            CGDirectDisplayID,
            WallpaperVideoPlayer
        ) -> Void = { _, _ in },
        refreshRateLookup: @MainActor @escaping (CGDirectDisplayID) -> Int,
        screensProvider: @MainActor @escaping () -> [Screen],
        markSessionStateChanged: @MainActor @escaping () -> Void,
        releaseRuntimeSession: @MainActor @escaping (Screen) -> Void,
        resetPlaybackStateMachine: @MainActor @escaping (Screen) -> Void = { _ in },
        notifyWallpaperSessionChanged: @MainActor @escaping () -> Void,
        refreshOtherAudioLeadership: @MainActor @escaping () -> Void = {},
        reportRuntimeError: @MainActor @escaping (CGDirectDisplayID, WallpaperRuntimeError?) -> Void = { _, _ in },
        originReconciler: any OriginReconciler,
        isGloballyEnabled: @MainActor @escaping () -> Bool = { true },
        isRuntimeInstallationAllowed: @MainActor @escaping () -> Bool = { true },
        advanceSceneMutationIntent: @MainActor @escaping (
            CGDirectDisplayID
        ) -> Void = { _ in },
        notifyConfigurationChanged: @MainActor @escaping (CGDirectDisplayID) -> Void = { screenID in
            Task { @MainActor in
                NotificationCenter.default.post(
                    name: .wallpaperConfigurationDidChange,
                    object: nil,
                    userInfo: ["screenID": screenID]
                )
            }
        }
    ) {
        self.configurationStore = configurationStore
        self.playableVideoLoader = playableVideoLoader
        self.bookmarkResolver = bookmarkResolver
        self.makeVideoPlayer = makeVideoPlayer
        self.validateSavedVideoConfiguration = validateSavedVideoConfiguration
        self.applyPolicy = applyPolicy
        self.applyVideoEffects = applyVideoEffects
        self.prepareVideoEffects = prepareVideoEffects
        self.effectsWorkRevision = effectsWorkRevision
        self.effectsWorkIsActive = effectsWorkIsActive
        self.retireVideoEffectsWork = retireVideoEffectsWork
        self.refreshRateLookup = refreshRateLookup
        self.screensProvider = screensProvider
        self.markSessionStateChanged = markSessionStateChanged
        self.releaseRuntimeSession = releaseRuntimeSession
        self.resetPlaybackStateMachine = resetPlaybackStateMachine
        self.notifyWallpaperSessionChanged = notifyWallpaperSessionChanged
        self.refreshOtherAudioLeadership = refreshOtherAudioLeadership
        self.notifyConfigurationChanged = notifyConfigurationChanged
        self.reportRuntimeError = reportRuntimeError
        self.originReconciler = originReconciler
        self.isGloballyEnabled = isGloballyEnabled
        self.isRuntimeInstallationAllowed = isRuntimeInstallationAllowed
        self.advanceSceneMutationIntent = advanceSceneMutationIntent
    }
}
