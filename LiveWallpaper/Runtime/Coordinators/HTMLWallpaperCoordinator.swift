import AppKit
import CoreGraphics
import Foundation
import LiveWallpaperCore

/// Owns HTML wallpaper setters and multi-instance audio-leader / trust policy.
@MainActor
final class HTMLWallpaperCoordinator {
    typealias SourcePreparer = @MainActor (
        _ source: HTMLSource,
        _ bookmarkID: UUID?,
        _ wpeOrigin: WPEOrigin?
    ) -> HTMLSource

    private let configurationStore: WallpaperConfigurationStore
    private let screensProvider: @MainActor () -> [Screen]
    private let saveConfiguration: @MainActor (ScreenConfiguration) -> Void
    private let restoreWallpaperSession: @MainActor (
        Screen,
        ScreenConfiguration,
        Bool,
        @MainActor @escaping () -> Bool
    ) -> Void
    private let notifyWallpaperSessionChanged: @MainActor () -> Void
    private let originReconciler: any OriginReconciler
    private let prepareSource: SourcePreparer

    init(
        configurationStore: WallpaperConfigurationStore,
        screensProvider: @MainActor @escaping () -> [Screen],
        saveConfiguration: @MainActor @escaping (ScreenConfiguration) -> Void,
        restoreWallpaperSession: @MainActor @escaping (
            Screen,
            ScreenConfiguration,
            Bool,
            @MainActor @escaping () -> Bool
        ) -> Void,
        notifyWallpaperSessionChanged: @MainActor @escaping () -> Void,
        originReconciler: any OriginReconciler,
        prepareSource: @escaping SourcePreparer = { source, _, _ in source }
    ) {
        self.configurationStore = configurationStore
        self.screensProvider = screensProvider
        self.saveConfiguration = saveConfiguration
        self.restoreWallpaperSession = restoreWallpaperSession
        self.notifyWallpaperSessionChanged = notifyWallpaperSessionChanged
        self.originReconciler = originReconciler
        self.prepareSource = prepareSource
    }

    // MARK: - Multi-instance diagnostics

    func screensRunningSameSource(as source: HTMLSource, excluding: CGDirectDisplayID) -> [Screen] {
        let signature = source.diagnosticSignature
        return screensProvider().filter { other in
            other.id != excluding
                && other.runtimeSession?.wallpaperType == .html
                && (configurationStore.get(for: other.id, fingerprint: other.displayFingerprint)?.activeWallpaper).flatMap { content -> String? in
                    if case .html(let s, _) = content { return s.diagnosticSignature }
                    return nil
                } == signature
        }
    }

    /// Elects one audio leader per same-source group (first unmuted, ascending screenID).
    /// Prior "no peer plays this source" rule muted every screen in a same-source pair.
    func isAudioLeader(source: HTMLSource, excluding screenID: CGDirectDisplayID) -> Bool {
        isAudioLeader(source: source, userMuted: storedMuteAudio(for: screenID) ?? false, for: screenID)
    }

    private func storedMuteAudio(for screenID: CGDirectDisplayID) -> Bool? {
        guard let screen = screensProvider().first(where: { $0.id == screenID }),
              let configuration = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint),
              case .html(_, let config) = configuration.activeWallpaper else { return nil }
        return config.muteAudio
    }

    private func isAudioLeader(source: HTMLSource, userMuted: Bool, for screenID: CGDirectDisplayID) -> Bool {
        var entries = [VideoAudioLeadershipPolicy.Entry(
            screenID: screenID,
            urlKey: source.diagnosticSignature,
            userMuted: userMuted
        )]
        for other in screensProvider() where other.id != screenID {
            guard other.runtimeSession?.wallpaperType == .html,
                  let configuration = configurationStore.get(for: other.id, fingerprint: other.displayFingerprint),
                  case .html(let otherSource, let otherConfig) = configuration.activeWallpaper else { continue }
            entries.append(VideoAudioLeadershipPolicy.Entry(
                screenID: other.id,
                urlKey: otherSource.diagnosticSignature,
                userMuted: otherConfig.muteAudio
            ))
        }
        return Self.effectiveAudioMutedStates(for: entries)[screenID] == false
    }

    /// Delegates the election to `VideoAudioLeadershipPolicy`; sorting first
    /// makes the winner independent of screen enumeration order.
    static func effectiveAudioMutedStates(
        for entries: [VideoAudioLeadershipPolicy.Entry]
    ) -> [CGDirectDisplayID: Bool] {
        VideoAudioLeadershipPolicy.effectiveMutedStates(
            for: entries.sorted { $0.screenID < $1.screenID }
        )
    }

    /// Merges audio-leader muting + trust evaluation into the effective config.
    func runtimeConfig(source: HTMLSource, config: HTMLConfig, for screen: Screen) -> HTMLConfig {
        var effectiveConfig = config

        if !effectiveConfig.muteAudio,
           !isAudioLeader(source: source, userMuted: config.muteAudio, for: screen.id) {
            effectiveConfig.muteAudio = true
            Logger.info("Multi-instance HTML wallpaper: muting screen \(screen.id) (another screen running the same source won the audio-leader election)", category: .screenManager)
        }

        return HTMLWallpaperCompatibilityPolicy.runtimeConfig(
            source: source,
            config: effectiveConfig,
            trustedOrigins: TrustedHostStore.shared.originSet
        ).config
    }

    /// Re-elects audio leadership across live HTML sessions after add/remove.
    /// Leadership is baked at creation; survivors otherwise stay muted forever.
    func refreshAudioLeadership() {
        for screen in screensProvider() {
            guard screen.runtimeSession?.wallpaperType == .html,
                  let applier = screen.runtimeSession as? any HTMLWallpaperConfigApplying,
                  let config = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint),
                  case .html(let source, let htmlConfig) = config.activeWallpaper else { continue }
            _ = applier.applyHTMLConfig(runtimeConfig(source: source, config: htmlConfig, for: screen))
        }
    }

    // MARK: - Public setters

    func setWallpaper(
        source: HTMLSource,
        config: HTMLConfig = .default,
        forceReload: Bool = false,
        bookmarkID: UUID? = nil,
        wpeOrigin: WPEOrigin? = nil,
        for screen: Screen
    ) {
        // Resolve stale grants before identity probes — probes can burn the one-shot grace.
        let effectiveSource = prepareSource(source, bookmarkID, wpeOrigin)
        let effectiveOrigin: WPEOrigin? = {
            guard let wpeOrigin,
                  let original = source.localBookmarkData,
                  let refreshed = effectiveSource.localBookmarkData,
                  original != refreshed,
                  let updated = wpeOrigin.replacingSourceFolderBookmark(
                    matching: original,
                    with: refreshed
                  ) else { return wpeOrigin }
            return updated
        }()
        let existingConfiguration = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint)
        let previousContent = existingConfiguration?.activeWallpaper
        let previousHTMLSource: HTMLSource?
        let previousHTMLConfig: HTMLConfig?
        if case .html(let source, let config) = previousContent {
            previousHTMLSource = source
            previousHTMLConfig = config
        } else {
            previousHTMLSource = nil
            previousHTMLConfig = nil
        }

        var persistedConfig = config
        if !persistedConfig.physicalPixelLayout,
           HTMLWallpaperCompatibilityPolicy.shouldAutoEnablePhysicalPixelLayout(effectiveSource) {
            persistedConfig.physicalPixelLayout = true
            Logger.info("HTML wallpaper: auto-enabling physical-pixel layout for Wallpaper Engine folder on screen \(screen.id)", category: .screenManager)
        }
        persistedConfig = Self.bindingLegacyProjectProperties(
            in: persistedConfig,
            previousSource: previousHTMLSource,
            previousConfig: previousHTMLConfig,
            nextSource: effectiveSource
        )

        var configuration = existingConfiguration ?? ScreenConfiguration(
            screenID: screen.id,
            wallpaper: .html(source: effectiveSource, config: persistedConfig)
        ).applyingDisplayDefaults(SettingsManager.shared.loadDisplayDefaults())
        if !forceReload,
           case .html(let existingSource, let existingConfig) = configuration.activeWallpaper,
           existingSource == effectiveSource,
           existingConfig == persistedConfig,
           screen.runtimeSession?.wallpaperType == .html {
            Logger.info("HTML wallpaper unchanged for screen \(screen.id); keeping existing WKWebView session", category: .screenManager)
            return
        }

        configuration.setHTMLWallpaper(source: effectiveSource, config: persistedConfig)
        if let effectiveOrigin {
            configuration.wpeOrigin = effectiveOrigin
        }
        originReconciler.reconcile(
            &configuration,
            event: .userReplacedActiveWallpaper(previous: previousContent)
        )
        restoreWallpaperSession(screen, configuration, false) { [weak self] in
            self?.saveConfiguration(configuration)
            return self != nil
        }
    }

    func setWallpaperPreservingConfig(source: HTMLSource, for screen: Screen) {
        let preserved = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint)?.htmlConfig ?? .default
        setWallpaper(source: source, config: preserved, for: screen)
    }

    func setWallpaper(url: String, for screen: Screen) {
        guard let source = HTMLSource(userInput: url) else { return }
        setWallpaper(source: source, for: screen)
    }

    func updateConfig(_ config: HTMLConfig, for screen: Screen) {
        guard var existing = configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint),
              case .html(let source, let previousConfig) = existing.activeWallpaper else { return }
        guard previousConfig != config else { return }
        existing.activeWallpaper = .html(source: source, config: config)

        let runtimeConfigValue = runtimeConfig(source: source, config: config, for: screen)
        if !Self.requiresSessionRebuild(previous: previousConfig, current: config),
           let applier = screen.runtimeSession as? any HTMLWallpaperConfigApplying,
           applier.applyHTMLConfig(runtimeConfigValue) {
            saveConfiguration(existing)
            if let window = screen.activeWallpaperWindow as? VideoWallpaperWindow {
                window.setWallpaperMouseInteractionEnabled(config.allowMouseInteraction)
            }
            // Mute is an election input; re-sync peers or a leader mute silences the group.
            if previousConfig.muteAudio != config.muteAudio {
                refreshAudioLeadership()
            }
            notifyWallpaperSessionChanged()
            return
        }

        restoreWallpaperSession(screen, existing, false) { [weak self] in
            self?.saveConfiguration(existing)
            return self != nil
        }
    }

    private static func requiresSessionRebuild(previous: HTMLConfig, current: HTMLConfig) -> Bool {
        previous.requiresEphemeralStorage != current.requiresEphemeralStorage
            || previous.originKind != current.originKind
            || previous.allowJavaScript != current.allowJavaScript
            || previous.blockTrackers != current.blockTrackers
    }

    private static func bindingLegacyProjectProperties(
        in config: HTMLConfig,
        previousSource: HTMLSource?,
        previousConfig: HTMLConfig?,
        nextSource: HTMLSource
    ) -> HTMLConfig {
        let legacyOverrides = config.wallpaperEngineProjectProperties
        guard !legacyOverrides.isEmpty else { return config }

        var result = config
        let sourceForLegacy: HTMLSource
        if let previousSource,
           previousSource != nextSource,
           previousConfig?.wallpaperEngineProjectProperties == legacyOverrides {
            sourceForLegacy = previousSource
        } else {
            sourceForLegacy = nextSource
        }

        guard let projectKey = WallpaperEngineProjectIdentity.key(source: sourceForLegacy) else {
            return result
        }
        if result.wallpaperEngineProjectPropertiesByProject[projectKey] == nil {
            result.wallpaperEngineProjectPropertiesByProject[projectKey] = legacyOverrides
        }
        result.wallpaperEngineProjectProperties = [:]
        return result
    }
}
