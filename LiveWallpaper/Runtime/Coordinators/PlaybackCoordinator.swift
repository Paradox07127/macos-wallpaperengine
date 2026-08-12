import CoreGraphics
import Foundation
import LiveWallpaperCore

/// Per-screen playback config mutations + async-transition registry.
@MainActor
final class PlaybackCoordinator {
    let transition = PlaybackTransitionRegistry()

    // Module-internal for same-type extensions across source files.
    let configurationStore: WallpaperConfigurationStore
    let playableVideoLoader: any PlayableVideoLoading
    let bookmarkResolver: SecurityScopedBookmarkResolver
    /// Injected from `ScreenManager` (policy source of truth).
    let applyPolicy: @MainActor (Screen) -> Void
    /// Callbacks into ScreenManager-owned lifetimes.
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
    /// Drops async effects state (incl. WorkKey tombstone) when a player loses its screen.
    let retireVideoEffectsWork: @MainActor (
        CGDirectDisplayID,
        WallpaperVideoPlayer
    ) -> Void
    /// Hook for ScreenManager's cached `CGDisplayCopyDisplayMode` lookup.
    let refreshRateLookup: @MainActor (CGDirectDisplayID) -> Int
    /// Matches `ScreenManager.screens` so async work can resolve a live screen.
    let screensProvider: @MainActor () -> [Screen]
    /// Refreshes inspector/sidebar state after deferred playback changes.
    let markSessionStateChanged: @MainActor () -> Void
    /// Owned by ScreenManager so the session lifecycle stays single-source.
    let releaseRuntimeSession: @MainActor (Screen) -> Void
    let notifyWallpaperSessionChanged: @MainActor () -> Void
    /// Reconciles non-video audio ownership after a cross-type commit.
    let refreshOtherAudioLeadership: @MainActor () -> Void
    /// Deferred configuration-change notification seam.
    let notifyConfigurationChanged: @MainActor (CGDirectDisplayID) -> Void
    /// Invalidates queued scene-property mutations before store revision advances.
    let advanceSceneMutationIntent: @MainActor (CGDirectDisplayID) -> Void
    /// Surfaces validation/setup failures before a session exists.
    let reportRuntimeError: @MainActor (CGDirectDisplayID, WallpaperRuntimeError?) -> Void
    /// Injected so Lite can swap in a no-op variant.
    let originReconciler: any OriginReconciler
    /// Master render gate.
    let isGloballyEnabled: @MainActor () -> Bool
    /// Process-lifecycle gate owned by `ScreenManager`.
    let isRuntimeInstallationAllowed: @MainActor () -> Bool

    init(
        configurationStore: WallpaperConfigurationStore,
        playableVideoLoader: any PlayableVideoLoading,
        bookmarkResolver: SecurityScopedBookmarkResolver = .shared,
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
