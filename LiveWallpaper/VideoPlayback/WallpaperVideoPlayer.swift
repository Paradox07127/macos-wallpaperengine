import AppKit
@preconcurrency import AVKit
import Combine
import CoreVideo
import LiveWallpaperCore
import QuartzCore

enum VideoCompositionOwner: Equatable, Sendable {
    case none
    case frameRate
    case effects
    case forceSDR
}

/// Video-output pixel-format negotiation, mirroring the scene-side source
/// (`WPEVideoTextureSource.negotiatedPixelFormats`): decoder-native NV12 first,
/// 32BGRA tail, and PQ/HLG sources pinned back to 32BGRA because the 8-bit
/// biplanar path cannot carry those transfer functions. Duplicated rather than
/// shared because `WPEVideoTextureSource.swift` is `#if !LITE_BUILD` while this
/// player ships in both SKUs.
enum WallpaperVideoOutputNegotiation {
    static let negotiatedPixelFormats: [OSType] = [
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        kCVPixelFormatType_32BGRA
    ]

    static let bgraOnlyPixelFormats: [OSType] = [kCVPixelFormatType_32BGRA]

    /// Width/height stay absent — buffers mirror the decoder's dimensions
    /// (VideoResolutionContract).
    static func pixelBufferAttributes(forcingBGRA: Bool) -> [String: any Sendable] {
        [
            kCVPixelBufferPixelFormatTypeKey as String: forcingBGRA
                ? bgraOnlyPixelFormats
                : negotiatedPixelFormats,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: any Sendable]()
        ]
    }

}

enum VideoDynamicRangePolicy {
    static func usesExtendedDynamicRange(
        formatInfo: VideoFormatInfo?,
        preference: VideoColorSpace
    ) -> Bool {
        switch preference {
        case .auto:
            return formatInfo?.isHDR == true
        case .rec2020HDR:
            return true
        case .sRGB, .displayP3, .forceSDR:
            return false
        }
    }
}

@MainActor
final class WallpaperVideoPlayer {
    typealias AssetLoaderOverride = @MainActor (URL) async throws -> AVURLAsset

    // MARK: - Notifications

    nonisolated static let didChangePlaybackStateNotification = Notification.Name("WallpaperVideoPlayerDidChangePlaybackState")

    // MARK: - Published Properties

    @Published private(set) var isPlaying: Bool = false {
        didSet {
            guard oldValue != isPlaying else { return }
            NotificationCenter.default.post(
                name: Self.didChangePlaybackStateNotification,
                object: self,
                userInfo: ["isPlaying": isPlaying]
            )
        }
    }

    @Published private(set) var videoFrameRate: Double = 0

    // MARK: - Public Properties

    private(set) var player: AVQueuePlayer?
    var videoURL: URL?
    /// scene.pkg entry name for in-place package playback (no extraction).
    private(set) var packageEntryName: String?
    private(set) var isMuted: Bool = true
    private(set) var audioVolume: Double = 1.0
    private(set) var shouldAutoplayWhenReady = true
    private(set) var requestedFrameRateLimit: Float = 0
    private(set) var runtimeError: WallpaperRuntimeError?
    /// Lazy HDR/codec probe; drives EDR on layer + window.
    private(set) var formatInfo: VideoFormatInfo?
    /// Replays any pre-existing error when assigned (late observers).
    var onError: (@MainActor (WallpaperRuntimeError) -> Void)? {
        didSet {
            if let runtimeError {
                onError?(runtimeError)
            }
        }
    }
    var currentWindowFrame: CGRect { window?.frame ?? initialFrame }
    var currentFitMode: VideoFitMode { fitMode }
    var currentPlaybackSpeed: Double { playbackSpeed }
    var currentColorSpacePreference: VideoColorSpace { lastColorSpacePreference }
    var currentSpanRenderConfiguration: VideoSpanRenderConfiguration? {
        pendingSpanRenderConfiguration
    }
    var currentParticleConfiguration: (effect: ParticleEffect, density: Double) {
        (currentParticleEffect, currentParticleDensity)
    }

    // MARK: - Private Properties

    private var window: VideoWallpaperWindow?
    private var videoView: VideoContainerView?
    private var playerLooper: AVPlayerLooper?
    private var templatePlayerItem: AVPlayerItem?
    private var pendingParticleEffect: (ParticleEffect, Double)?
    private var currentParticleEffect: ParticleEffect = .none
    private var currentParticleDensity: Double = 1
    private(set) var particleEffectsSuspended = false
    private var pendingSpanRenderConfiguration: VideoSpanRenderConfiguration?
    private var cleanupTasks = Set<AnyCancellable>()
    private var loadingTask: Task<Void, Never>?
    private var frameRateLimitTask: Task<Void, Never>?
    /// Strong retain: resource loader delegate is weak on AVFoundation's side.
    private var inMemoryAssetLoader: InMemoryVideoAssetLoader?
    private(set) var currentVideoComposition: AVVideoComposition?
    /// Distinguishes FPS vs effects vs Force SDR (AVFoundation only exposes the object).
    private(set) var videoCompositionOwner: VideoCompositionOwner = .none
    /// Composition publication gen; stale builds cancel, item replicas may rebind.
    private var videoCompositionGeneration: UInt64 = 0
    var videoCompositionRevision: UInt64 { videoCompositionGeneration }
    private var currentItemSubscription: AnyCancellable?
    /// Outstanding AVAsset property loads; cleanup cancels them explicitly.
    private var currentLoadingAsset: AVAsset?
    private var currentFrameRateLoadingAsset: AVAsset?
    private var accessToken = false
    private let initialFrame: CGRect
    private let startsHidden: Bool
    private let assetLoaderOverride: AssetLoaderOverride?
    private var fitMode: VideoFitMode = .aspectFill
    private var playbackSpeed: Double = 1
    private var hasRequestedPlaybackStart = false
    /// Outputs this player has attached to a player item. Owned so suspension
    /// and hibernation can release the conversion pool an output pins. The
    /// readiness probe is the only producer today and it never overlaps a
    /// suspend (a probed candidate is not session-installed yet), so the drain
    /// is normally a no-op — it is the invariant that matters, not the count.
    private var boundVideoOutputs: [(item: AVPlayerItem, output: AVPlayerItemVideoOutput)] = []
    /// Warm suspend: paused with the decoded last frame still on the layer.
    private(set) var isSuspended = false
    /// Deep hibernation: player/looper/decode pool/`lwmem://` mapping released
    /// behind a captured still frame.
    /// Same cover-then-release lifecycle the HTML view uses: the still frame is
    /// the cover, `retirePlaybackState()` the release, `setupPlayer` the rebuild.
    /// Holding it as a phase rather than a bool is what makes "rebuilding" an
    /// expressible state — a re-absence during a wake used to be indistinguishable
    /// from "not hibernated".
    private var hibernation = HibernationPhase()
    var isHibernated: Bool { hibernation.phase == .hibernated }
    /// Rebuilding behind the still frame after a wake. Callers report this
    /// instead of a pause: the wallpaper is coming back, not being held down.
    var isRestoringFromHibernation: Bool { hibernation.phase == .restoring }
    private var isHibernationEligible = false
    private let hibernationDelay: Duration
    private let hibernationDwell = AbsenceDwell()
    /// Latch + generation: detached mmap/property loads may finish after cancel.
    private(set) var isCleanedUp = false
    private var lifecycleGeneration: UInt64 = 0
    private var frameRateGeneration: UInt64 = 0
    /// Survives late `VideoContainerView` creation in `configurePlaybackComponents`.
    private var lastColorSpacePreference: VideoColorSpace = .auto
    /// Effects replay hook; permanent current-item observer avoids looper nil seams.
    var onCurrentItemAvailable: (@MainActor (WallpaperVideoPlayer) -> Void)?

    var isForceSDRActive: Bool { lastColorSpacePreference == .forceSDR }
    /// Pending FPS work after retry (nil composition ≠ "plain video ready").
    var requiresFrameRatePreparationForRetry: Bool {
        !isForceSDRActive
            && requestedFrameRateLimit > 0
            && currentVideoComposition == nil
    }
    #if DEBUG
    // Test-only introspection; no production reader.
    var hasInstalledPlaybackWindow: Bool { window != nil }
    var boundVideoOutputCountForTesting: Int { boundVideoOutputs.count }
    var hasInMemoryAssetLoaderForTesting: Bool { inMemoryAssetLoader != nil }
    var isShowingHibernationStillFrameForTesting: Bool { videoView?.isShowingStillFrame == true }
    /// Binds a probe-shaped output so the drain invariant is observable without
    /// racing the readiness gate.
    @discardableResult
    func attachVideoOutputForTesting() -> Bool {
        guard let item = player?.currentItem else { return false }
        bindVideoOutput(
            AVPlayerItemVideoOutput(
                pixelBufferAttributes: WallpaperVideoOutputNegotiation.pixelBufferAttributes(
                    forcingBGRA: false
                )
            ),
            to: item
        )
        return true
    }
    #endif
    var isReadyForDisplay: Bool { videoView?.isReadyForDisplay == true }
    
    // MARK: - Initialization
    init(
        url: URL,
        frame: CGRect,
        fitMode: VideoFitMode = .aspectFill,
        packageEntryName: String? = nil,
        startsHidden: Bool = false,
        loadImmediately: Bool = true,
        hibernationDelay: Duration = .seconds(20),
        assetLoaderOverride: AssetLoaderOverride? = nil
    ) {
        Logger.functionStart(category: .videoPlayer)
        self.initialFrame = frame
        self.fitMode = fitMode
        self.videoURL = url
        self.packageEntryName = packageEntryName
        self.startsHidden = startsHidden
        self.hibernationDelay = hibernationDelay
        // Hidden candidates: dormant particles until `show()` publishes the session.
        self.particleEffectsSuspended = startsHidden
        self.assetLoaderOverride = assetLoaderOverride
        
        guard !frame.isEmpty else {
            let error = NSError(
                domain: "WallpaperVideoPlayer",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid frame provided"]
            )
            Logger.error("Invalid frame provided: \(frame)", category: .videoPlayer)
            Logger.error("WallpaperVideoPlayer init error: \(error.localizedDescription)", category: .videoPlayer)
            reportError(.mediaNotPlayable(url, code: error.code))
            return
        }

        guard loadImmediately else {
            Logger.functionEnd(category: .videoPlayer)
            return
        }
        
        setupPlayer(with: url)
        Logger.functionEnd(category: .videoPlayer)
    }
    
    // MARK: - Video Player Setup
    private func setupPlayer(with url: URL) {
        guard !isCleanedUp else { return }
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        Logger.debug("Setting up player with URL: \(url.lastPathComponent)", category: .videoPlayer)
        // A hibernation wake re-enters here with the scope already held; a second
        // start would need a second stop and leak the scope.
        if !accessToken {
            accessToken = url.startAccessingSecurityScopedResource()
        }
        if !accessToken {
            guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
                let error = NSError(
                    domain: "WallpaperVideoPlayer",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to access security scoped resource"]
                )
                Logger.error("Failed to access security scoped resource: \(url.lastPathComponent)", category: .videoPlayer)
                Logger.error("WallpaperVideoPlayer init error: \(error.localizedDescription)", category: .videoPlayer)
                reportError(.fileAccessDenied(url))
                return
            }

            Logger.debug(
                "Using directly accessible video file without security scope: \(url.lastPathComponent)",
                category: .videoPlayer
            )
        }

        loadingTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.lifecycleGeneration == generation {
                    self.currentLoadingAsset = nil
                    self.loadingTask = nil
                }
            }

            do {
                let timer = PerformanceTimer(description: "Loading video asset", category: .videoPlayer)

                if let assetLoaderOverride = self.assetLoaderOverride {
                    let asset = try await assetLoaderOverride(url)
                    try self.ensureLifecycleActive(generation)
                    self.currentLoadingAsset = asset
                    try await self.installPreparedPlayback(
                        asset: asset,
                        loader: nil,
                        generation: generation,
                        timer: timer,
                        url: url
                    )
                    self.finishLoading(asset: asset, generation: generation)
                    return
                }

                // Packaged: custom-scheme asset windowed into scene.pkg (probe + play).
                let asset: AVURLAsset
                let packagedLoader: InMemoryVideoAssetLoader?
                if let entryName = self.packageEntryName {
                    let result = try await Task.detached(priority: .utility) {
                        try InMemoryVideoAssetLoader.loadPackageEntry(packageURL: url, entryName: entryName)
                    }.value
                    try self.ensureLifecycleActive(generation)
                    let memAsset = AVURLAsset(url: result.customURL, options: Self.inMemoryAssetOptions)
                    memAsset.resourceLoader.setDelegate(result.loader, queue: Self.resourceLoaderQueue)
                    asset = memAsset
                    packagedLoader = result.loader
                } else {
                    asset = AVURLAsset(url: url)
                    packagedLoader = nil
                }

                try self.ensureLifecycleActive(generation)
                self.currentLoadingAsset = asset

                let isPlayable = try await asset.load(.isPlayable)
                try self.ensureLifecycleActive(generation)

                guard isPlayable else {
                    self.stopAccessingResource()
                    Logger.error("Video is not playable: \(url.lastPathComponent)", category: .videoPlayer)
                    self.reportError(.mediaNotPlayable(url, code: nil))
                    return
                }

                let videoTracks = try await asset.loadTracks(withMediaType: .video)
                try self.ensureLifecycleActive(generation)
                if let videoTrack = videoTracks.first {
                    let frameRate = try await videoTrack.load(.nominalFrameRate)
                    try self.ensureLifecycleActive(generation)
                    self.videoFrameRate = Double(frameRate)
                    Logger.debug("Video frame rate: \(self.videoFrameRate) FPS", category: .videoPlayer)
                }

                let activeAsset: AVURLAsset
                let loader: InMemoryVideoAssetLoader?

                if let packagedLoader {
                    // Package path always windowed mmap — skip size-based memory decision.
                    activeAsset = asset
                    loader = packagedLoader
                } else {
                    let fileSize = Self.fileSize(of: url)
                    let memoryCached = Self.shouldUseInMemoryCache(fileSize: fileSize)

                    if memoryCached {
                        do {
                            // mmap + attrs off MainActor (large clips are expensive).
                            let result = try await Task.detached(priority: .utility) {
                                try InMemoryVideoAssetLoader.load(from: url)
                            }.value
                            try self.ensureLifecycleActive(generation)
                            let memAsset = AVURLAsset(url: result.customURL, options: Self.inMemoryAssetOptions)
                            memAsset.resourceLoader.setDelegate(result.loader, queue: Self.resourceLoaderQueue)
                            activeAsset = memAsset
                            loader = result.loader
                            Logger.info(
                                "Serving \(fileSize / (1024 * 1024)) MB video from a mapping — playback reads go to page cache, not the vnode",
                                category: .videoPlayer
                            )
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            try self.ensureLifecycleActive(generation)
                            Logger.info(
                                "In-memory load failed (\(error.localizedDescription)) — falling back to streaming",
                                category: .videoPlayer
                            )
                            activeAsset = asset
                            loader = nil
                        }
                    } else {
                        activeAsset = asset
                        loader = nil
                        let budgetMB = SettingsManager.shared.loadGlobalSettings()
                            .videoCacheMaxBytesPerScreen / (1024 * 1024)
                        Logger.debug(
                            "Streaming from disk: \(fileSize / (1024 * 1024)) MB exceeds in-memory budget (\(budgetMB) MB). Raise the slider in General Settings to keep this clip in RAM.",
                            category: .videoPlayer
                        )
                    }
                }

                timer.checkpoint("Properties loaded")
                try await self.installPreparedPlayback(
                    asset: activeAsset,
                    loader: loader,
                    generation: generation,
                    timer: timer,
                    url: url
                )
                self.finishLoading(asset: activeAsset, generation: generation)
            } catch is CancellationError {
                Logger.debug("Video loading task was cancelled", category: .videoPlayer)
                self.stopAccessingResource()
            } catch {
                self.stopAccessingResource()
                guard self.isLifecycleActive(generation) else { return }
                Logger.error("Error loading video: \(error.localizedDescription)", category: .videoPlayer)
                self.reportError(self.makeRuntimeError(from: error, url: url))
            }

        }
    }

    func prepareForDisplay(timeout: Duration) async -> WallpaperPreparationResult {
        await WallpaperPreparationWaiter.wait(timeout: timeout) { [weak self] in
            guard let self else { return .cancelled }
            if self.runtimeError != nil || self.isCleanedUp {
                return .failed
            }
            return self.isReadyForDisplay ? .ready : nil
        }
    }

    /// After base readiness; wait for late Force SDR Rec.709 before snapshotting composition.
    func prepareForCurrentComposition(
        after base: WallpaperPreparationResult,
        timeout: Duration
    ) async -> WallpaperPreparationResult {
        guard base == .ready else { return base }
        guard currentVideoComposition != nil || isForceSDRActive else { return .ready }
        let expectedLifecycleGeneration = lifecycleGeneration
        let waitsForLateForceSDRComposition = isForceSDRActive && currentVideoComposition == nil
        return await WallpaperPreparationWaiter.withHardDeadline(timeout: timeout) { [weak self] in
            guard let self else { return .cancelled }
            while self.currentVideoComposition == nil {
                guard waitsForLateForceSDRComposition,
                      self.isForceSDRActive,
                      self.lifecycleGeneration == expectedLifecycleGeneration,
                      !self.isCleanedUp else {
                    return .cancelled
                }
                do {
                    try await Task.sleep(for: .milliseconds(16))
                } catch {
                    return .cancelled
                }
            }
            let expectedCompositionGeneration = self.videoCompositionGeneration
            var coordinator = VideoCompositedFrameReadinessCoordinator(
                expectedLifecycleGeneration: expectedLifecycleGeneration,
                expectedCompositionGeneration: expectedCompositionGeneration
            )
            var boundItem: AVPlayerItem?
            var output: AVPlayerItemVideoOutput?
            // A closure, not a nested func: nested funcs do not inherit the
            // enclosing closure's MainActor isolation, and the unbind is
            // MainActor-isolated.
            let unbindOutput = {
                if let boundItem, let output {
                    self.unbindVideoOutput(output, from: boundItem)
                }
                boundItem = nil
                output = nil
            }
            defer { unbindOutput() }

            while !Task.isCancelled {
                if self.runtimeError != nil || self.isCleanedUp {
                    return .failed
                }
                let item = self.player?.currentItem
                let action = coordinator.nextAction(
                    lifecycleGeneration: self.lifecycleGeneration,
                    compositionGeneration: self.videoCompositionGeneration,
                    currentItemID: item.map(ObjectIdentifier.init)
                )
                switch action {
                case .cancelled:
                    return .cancelled
                case .waitForItem:
                    unbindOutput()
                case .bind:
                    guard let item else { continue }
                    unbindOutput()
                    guard self.player?.currentItem === item else { continue }
                    // KVO is async — apply composition now before attaching output.
                    self.applyCurrentCompositionToQueueItems()
                    guard self.player?.currentItem === item else { continue }
                    let nextOutput = AVPlayerItemVideoOutput(
                        pixelBufferAttributes: WallpaperVideoOutputNegotiation.pixelBufferAttributes(
                            forcingBGRA: self.usesExtendedDynamicRange
                        )
                    )
                    self.bindVideoOutput(nextOutput, to: item)
                    boundItem = item
                    output = nextOutput
                case .poll:
                    break
                }

                if let item, let output, boundItem === item {
                    if item.status == .failed {
                        return .failed
                    }
                    guard self.lifecycleGeneration == expectedLifecycleGeneration,
                          self.videoCompositionGeneration == expectedCompositionGeneration,
                          self.currentVideoComposition != nil else {
                        return .cancelled
                    }
                    let itemTime = output.itemTime(forHostTime: CACurrentMediaTime())
                    var displayTime = CMTime.invalid
                    if output.copyPixelBuffer(
                        forItemTime: itemTime,
                        itemTimeForDisplay: &displayTime
                    ) != nil,
                       self.player?.currentItem === item {
                        return .ready
                    }
                }
                do {
                    try await Task.sleep(for: .milliseconds(16))
                } catch {
                    return .cancelled
                }
            }
            return .cancelled
        }
    }

    private func installPreparedPlayback(
        asset: AVURLAsset,
        loader: InMemoryVideoAssetLoader?,
        generation: UInt64,
        timer: PerformanceTimer,
        url: URL
    ) async throws {
        try ensureLifecycleActive(generation)
        currentLoadingAsset = asset
        inMemoryAssetLoader = loader
        configurePlaybackComponents(with: asset, generation: generation)
        try ensureLifecycleActive(generation)
        timer.checkpoint("Playback configured")

        do {
            // Custom-scheme assets have no file URL — probe tracks on the asset itself.
            try await detectFormatInfoIfNeeded(asset: asset, generation: generation)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try ensureLifecycleActive(generation)
            Logger.warning("Unable to detect video format: \(error.localizedDescription)", category: .videoPlayer)
        }

        try ensureLifecycleActive(generation)
        Logger.debug("Video loaded: \(url.lastPathComponent)", category: .videoPlayer)
    }

    private func ensureLifecycleActive(_ generation: UInt64) throws {
        try Task.checkCancellation()
        guard isLifecycleActive(generation) else { throw CancellationError() }
    }

    private func isLifecycleActive(_ generation: UInt64) -> Bool {
        !isCleanedUp && lifecycleGeneration == generation
    }

    private func finishLoading(asset: AVAsset, generation: UInt64) {
        guard lifecycleGeneration == generation, currentLoadingAsset === asset else { return }
        currentLoadingAsset = nil
    }
    
    /// Resource-loader callbacks off main (byte-range / Data copies).
    private static let resourceLoaderQueue = DispatchQueue(
        label: "app.livewallpaper.video.in-memory-loader",
        qos: .userInitiated
    )

    /// lwmem:// assets: forbid external refs / network.
    private static let inMemoryAssetOptions: [String: Any] = [
        AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue,
        AVURLAssetAllowsCellularAccessKey: false,
        AVURLAssetAllowsExpensiveNetworkAccessKey: false,
        AVURLAssetAllowsConstrainedNetworkAccessKey: false
    ]

    /// Probe packaged playability; holds loader (weak AVFoundation delegate) across await.
    static func validatePackagedVideo(packageURL: URL, entryName: String) async throws {
        // Bookmark-apply has no accessToken — start scope here for the mmap.
        let didStart = packageURL.startAccessingSecurityScopedResource()
        defer { if didStart { packageURL.stopAccessingSecurityScopedResource() } }

        let result = try InMemoryVideoAssetLoader.loadPackageEntry(packageURL: packageURL, entryName: entryName)
        let asset = AVURLAsset(url: result.customURL, options: inMemoryAssetOptions)
        asset.resourceLoader.setDelegate(result.loader, queue: resourceLoaderQueue)
        try await PlayableVideoLoader.validatePlayableVideo(asset: asset)
        withExtendedLifetime(result.loader) {}
    }


    private static func fileSize(of url: URL) -> Int {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)),
              let size = attrs[.size] as? NSNumber else {
            return 0
        }
        return size.intValue
    }

    /// Size-only in-memory gate (duration irrelevant once under budget).
    private static func shouldUseInMemoryCache(fileSize: Int) -> Bool {
        guard fileSize > 0 else { return false }
        let budget = SettingsManager.shared.loadGlobalSettings().videoCacheMaxBytesPerScreen
        guard budget > 0 else { return false }
        return fileSize <= budget
    }

    private func configurePlaybackComponents(with asset: AVURLAsset, generation: UInt64) {
        guard isLifecycleActive(generation) else { return }
        let playerItem = AVPlayerItem(asset: asset)

        // No `preferredForwardBufferDuration`: measured inert here (unset / 5s / 32s
        // gave the same footprint, swing, delivered bytes and request count on both
        // the file-URL and the lwmem path once the resource declares on-demand
        // availability). The duration probe that used to size it went with it.
        // Local sources: skip composition seek waits and remote stall heuristics.
        playerItem.seekingWaitsForVideoCompositionRendering = false
        playerItem.audioTimePitchAlgorithm = .timeDomain
        playerItem.canUseNetworkResourcesForLiveStreamingWhilePaused = false

        applyAudioPolicy(to: playerItem)

        let queuePlayer = AVQueuePlayer()
        queuePlayer.actionAtItemEnd = .none
        queuePlayer.automaticallyWaitsToMinimizeStalling = false
        queuePlayer.preventsDisplaySleepDuringVideoPlayback = false
        queuePlayer.volume = isMuted ? 0 : Float(audioVolume)
        queuePlayer.isMuted = isMuted
        queuePlayer.defaultRate = Float(playbackSpeed)
        self.player = queuePlayer
        self.templatePlayerItem = playerItem
        self.playerLooper = AVPlayerLooper(player: queuePlayer, templateItem: playerItem)
        if currentVideoComposition != nil {
            applyCurrentCompositionToQueueItems()
        }
        applyAudioPolicyToQueueItems()
        
        let videoWindow: VideoWallpaperWindow
        let containerView: VideoContainerView
        if let window, let videoView {
            // Hibernation wake: reuse the live window/view so the still frame
            // stays up and the window keeps its current frame, level and order.
            videoWindow = window
            containerView = videoView
        } else {
            videoWindow = VideoWallpaperWindow(frame: initialFrame)
            containerView = VideoContainerView(frame: initialFrame)
            videoWindow.contentView = containerView
            videoWindow.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
            if startsHidden {
                videoWindow.orderOut(nil)
            } else {
                videoWindow.orderBack(nil)
            }
        }
        containerView.fitMode = fitMode
        containerView.setPlayer(player)
        containerView.setSpanRenderConfiguration(pendingSpanRenderConfiguration)

        self.window = videoWindow
        self.videoView = containerView

        // Prefs/format may predate the container — reconcile once layer exists.
        containerView.applyColorSpacePreference(lastColorSpacePreference)
        reconcileDynamicRange()
        if lastColorSpacePreference == .forceSDR {
            installSDRComposition()
        }

        if let pending = pendingParticleEffect {
            pendingParticleEffect = nil
            containerView.setParticleEffect(pending.0, density: pending.1)
        }
        containerView.setParticleEffectsSuspended(particleEffectsSuspended)

        setupPlaybackObservers()
        installQueueItemMaintenanceObserver()
        applyRequestedFrameRateLimitIfReady()
        setupPlayerReadyObserver()
        // No-op unless a hibernation still frame is up; the frame is held until
        // the rebuilt layer actually has a picture, otherwise wake flashes black.
        // The rebuild has a picture (or is about to): close out the restore so a
        // later absence starts from `.live`. The one-shot return is the HTML
        // view's "drop the cover now" signal; here the container owns that via
        // `clearStillFrameWhenPlayerIsReady`, so the flag itself is what matters.
        _ = hibernation.didRestore()
        containerView.clearStillFrameWhenPlayerIsReady()
    }

    private func detectFormatInfoIfNeeded(asset: AVURLAsset, generation: UInt64) async throws {
        guard formatInfo == nil else { return }
        let detected = try await PlayableVideoLoader.detectFormat(asset: asset)
        try ensureLifecycleActive(generation)
        formatInfo = detected
        reconcileDynamicRange()
    }

    var usesExtendedDynamicRange: Bool {
        VideoDynamicRangePolicy.usesExtendedDynamicRange(
            formatInfo: formatInfo,
            preference: lastColorSpacePreference
        )
    }

    private func reconcileDynamicRange() {
        let usesExtendedDynamicRange = self.usesExtendedDynamicRange
        videoView?.applyHDRPreference(usesExtendedDynamicRange)
        window?.setExtendedDynamicRangeEnabled(usesExtendedDynamicRange)

        if let formatInfo, formatInfo.isHDR {
            let details = formatInfo.badges.isEmpty == false
                ? formatInfo.badges.map(\.displayLabel).joined(separator: " ")
                : "transfer function detected"
            Logger.debug(
                "HDR source (\(details)); EDR=\(usesExtendedDynamicRange) preference=\(lastColorSpacePreference.rawValue)",
                category: .videoPlayer
            )
        }
    }

    private func setupPlayerReadyObserver() {
        guard let player = player else { return }

        player.publisher(for: \.status)
            .first(where: { $0 == .readyToPlay })
            .delay(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.shouldAutoplayWhenReady else { return }
                Logger.debug("Player is ready to play", category: .videoPlayer)
                self.applyAudioPolicyToQueueItems()
                self.play()
                Logger.debug("Auto-starting video playback", category: .videoPlayer)
            }
            .store(in: &cleanupTasks)
    }
    
    // MARK: - Observers
    private func setupPlaybackObservers() {
        if let player = player {
            let status = player.publisher(for: \.timeControlStatus)
                .receive(on: DispatchQueue.main)
            // Kept mapped-then-deduplicated: `.waitingToPlayAtSpecifiedRate` must
            // not read as "not playing", or the session summary flips to
            // policy-suspended for the length of a buffering blip.
            status
                .map { $0 == .playing }
                .removeDuplicates()
                .sink { [weak self] isCurrentlyPlaying in
                    guard let self else { return }
                    self.isPlaying = isCurrentlyPlaying
                }
                .store(in: &cleanupTasks)
            status
                .filter { $0 == .paused }
                .sink { [weak self, weak player] _ in
                    guard let self, let player, self.player === player else { return }
                    self.recoverFromStall(on: player)
                }
                .store(in: &cleanupTasks)
        }

        let benignLooperCodes: Set<Int> = [-11847, -11858, -11878, -12504, -12509, -12784, -12823, -12852, -12860]
        NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime, object: nil)
            .sink { [weak self] notification in
                guard let self,
                      let item = notification.object as? AVPlayerItem,
                      let queue = self.player,
                      queue.items().contains(item) || queue.currentItem === item,
                      let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                else { return }
                let nsError = error as NSError
                if nsError.domain == AVFoundationErrorDomain && benignLooperCodes.contains(nsError.code) {
                    return
                }
                Logger.warning("Playback item failed (code: \(nsError.code)): \(error.localizedDescription)", category: .videoPlayer)
                if let url = self.videoURL {
                    self.reportError(self.makeRuntimeError(from: error, url: url))
                }
            }
            .store(in: &cleanupTasks)
    }

    /// AVPlayer clears the desired rate to 0 when the playback buffer empties
    /// while `automaticallyWaitsToMinimizeStalling` is false (AVPlayer.h). Nobody
    /// re-issued a rate after that, so one underrun froze the wallpaper for good
    /// (issue #131).
    ///
    /// Only reacts to a pause we did not ask for: `pause()` clears
    /// `shouldAutoplayWhenReady` first, and the pre-start `.paused` is filtered
    /// out by the start latch. Deliberately talks to AVFoundation directly rather
    /// than going through `play()`: clearing `hasRequestedPlaybackStart` to get
    /// past that latch would leave it cleared whenever this arrives while the
    /// player is already playing, disarming the next real recovery. Nothing here
    /// throttles because the source is a status *transition* — one resume per
    /// stall is exactly the intended rate.
    private func recoverFromStall(on player: AVQueuePlayer) {
        guard !isCleanedUp, shouldAutoplayWhenReady, hasRequestedPlaybackStart else { return }
        Logger.warning("Playback stalled and the rate was cleared — resuming", category: .videoPlayer)
        player.play()
    }

    // MARK: - Playback Controls

    func play() {
        guard !isCleanedUp else { return }
        shouldAutoplayWhenReady = true
        guard let player = player else { return }
        guard !hasRequestedPlaybackStart, player.timeControlStatus != .playing else { return }
        hasRequestedPlaybackStart = true
        player.play()
        isPlaying = true
        Logger.debug("Video playback started", category: .videoPlayer)
    }

    func pause() {
        shouldAutoplayWhenReady = false
        hasRequestedPlaybackStart = false
        guard let player else { return }
        let wasActive = isPlaying || player.timeControlStatus != .paused
        player.pause()
        if isPlaying {
            isPlaying = false
        }
        if wasActive {
            Logger.debug("Video playback paused", category: .videoPlayer)
        }
    }

    func setPlaybackSpeed(_ speed: Double) {
        let clamped = Self.clampedPlaybackSpeed(speed)
        playbackSpeed = clamped
        player?.defaultRate = Float(clamped)
        if player?.timeControlStatus == .playing {
            player?.rate = Float(clamped)
        }
    }

    func setMuted(_ muted: Bool) {
        guard isMuted != muted else { return }
        isMuted = muted

        applyAudioPolicyToQueueItems()
    }

    func setVolume(_ volume: Double) {
        let clampedVolume = Self.clampedVolume(volume)
        guard abs(audioVolume - clampedVolume) > 0.001 else { return }
        audioVolume = clampedVolume
        updatePlayerAudioOutput()
    }

    private func applyAudioPolicyToQueueItems() {
        guard let player else { return }
        if let templatePlayerItem {
            applyAudioPolicy(to: templatePlayerItem)
        }
        if let current = player.currentItem {
            applyAudioPolicy(to: current)
        }
        for item in player.items() where item !== player.currentItem {
            applyAudioPolicy(to: item)
        }
        updatePlayerAudioOutput()
    }

    private func updatePlayerAudioOutput() {
        guard let player else { return }
        player.isMuted = isMuted
        player.volume = isMuted ? 0 : Float(audioVolume)
    }

    private func applyAudioPolicy(to playerItem: AVPlayerItem) {
        let enable = !isMuted
        for track in playerItem.tracks where track.assetTrack?.mediaType == .audio {
            track.isEnabled = enable
        }
    }

    private static func clampedVolume(_ value: Double) -> Double {
        guard value.isFinite else { return 1.0 }
        return min(max(value, 0), 1)
    }

    /// Same [0.25, 4.0] range as DisplayPlaybackDefaults.clampedPlaybackSpeed
    /// (Packages/LiveWallpaperCore/.../DisplayDefaults.swift:85-88).
    private static func clampedPlaybackSpeed(_ value: Double) -> Double {
        guard value.isFinite else { return 1.0 }
        return min(max(value, 0.25), 4.0)
    }

    private func installQueueItemMaintenanceObserver() {
        guard currentItemSubscription == nil, let queuePlayer = player else { return }
        currentItemSubscription = queuePlayer.publisher(for: \.currentItem)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] item in
                guard let self else { return }
                if let item {
                    self.applyAudioPolicy(to: item)
                }
                self.applyCurrentCompositionToQueueItems()
                guard item != nil else { return }
                self.applyRequestedFrameRateLimitIfReady()
                self.onCurrentItemAvailable?(self)
            }
    }

    func setVideoFitMode(_ mode: VideoFitMode) {
        guard mode != fitMode else { return }
        fitMode = mode
        videoView?.fitMode = mode
    }

    /// Force SDR installs Rec.709 composition (exclusive with frame-rate composition).
    func setVideoColorSpace(_ preference: VideoColorSpace) {
        guard !isCleanedUp else { return }
        let previousPreference = lastColorSpacePreference
        lastColorSpacePreference = preference
        videoView?.applyColorSpacePreference(preference)
        reconcileDynamicRange()

        if preference == .forceSDR {
            // Cancel in-flight FPS build so it cannot race past Rec.709.
            invalidateFrameRateCompositionBuild()
            installSDRComposition()
        } else if previousPreference == .forceSDR {
            // Leaving Force SDR: re-apply FPS limit if any (composition slot freed).
            setVideoComposition(nil, owner: .none)
            if requestedFrameRateLimit > 0 {
                setFrameRateLimit(requestedFrameRateLimit)
            }
        }
    }

    private func installSDRComposition() {
        guard !isCleanedUp else { return }
        guard let templateItem = templatePlayerItem else {
            // No asset yet — late path via lastColorSpacePreference.
            if currentVideoComposition != nil {
                setVideoComposition(nil, owner: .none)
            }
            return
        }
        let asset = templateItem.asset
        let composition = AVMutableVideoComposition(
            asset: asset,
            applyingCIFiltersWithHandler: { request in
                request.finish(with: request.sourceImage, context: nil)
            }
        )
        composition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        composition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        composition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        setVideoComposition(composition, owner: .forceSDR)
    }

    func setSpanRenderConfiguration(_ configuration: VideoSpanRenderConfiguration?) {
        pendingSpanRenderConfiguration = configuration
        videoView?.setSpanRenderConfiguration(configuration)
    }

    func setParticleEffect(_ effect: ParticleEffect, density: Double = 1.0) {
        currentParticleEffect = effect
        currentParticleDensity = density
        guard let videoView = videoView else {
            pendingParticleEffect = (effect, density)
            return
        }
        videoView.setParticleEffect(effect, density: density)
    }

    func setParticleEffectsSuspended(_ suspended: Bool) {
        guard particleEffectsSuspended != suspended else { return }
        particleEffectsSuspended = suspended
        videoView?.setParticleEffectsSuspended(suspended)
    }

    // MARK: - Window Management

    func updateWindowFrame(_ newFrame: CGRect) {
        guard isValidFrame(newFrame) else {
            Logger.warning("Invalid frame provided to updateWindowFrame: \(newFrame)", category: .videoPlayer)
            return
        }

        if let window = window, !Self.areFramesEquivalent(window.frame, newFrame) {
            Logger.debug("Updating video window frame to \(newFrame)", category: .videoPlayer)
            window.updateFrame(newFrame, animate: false)
        }

        if let videoView = videoView {
            videoView.frame = NSRect(x: 0, y: 0, width: newFrame.width, height: newFrame.height)
            videoView.needsLayout = true
        }
    }

    func orderWindowBack() {
        window?.orderBack(nil)
    }

    private func isValidFrame(_ frame: CGRect) -> Bool {
        !frame.isEmpty && frame.width > 0 && frame.height > 0
    }

    private static func areFramesEquivalent(_ frame1: CGRect, _ frame2: CGRect, tolerance: CGFloat = 1.0) -> Bool {
        abs(frame1.origin.x - frame2.origin.x) < tolerance &&
        abs(frame1.origin.y - frame2.origin.y) < tolerance &&
        abs(frame1.width - frame2.width) < tolerance &&
        abs(frame1.height - frame2.height) < tolerance
    }

    // MARK: - Video Composition

    func setVideoComposition(
        _ composition: AVVideoComposition?,
        owner: VideoCompositionOwner
    ) {
        guard !isCleanedUp else { return }
        assert(
            composition == nil || owner != .none,
            "A non-nil video composition must have a semantic owner"
        )
        if owner == .effects || owner == .forceSDR {
            // Effects/ForceSDR supersede FPS; keep requested limit, kill late FPS builds.
            invalidateFrameRateCompositionBuild()
        }
        videoCompositionGeneration &+= 1
        currentVideoComposition = composition
        videoCompositionOwner = composition == nil ? .none : owner
        applyCurrentCompositionToQueueItems()
        installQueueItemMaintenanceObserver()
    }

    private func invalidateFrameRateCompositionBuild() {
        frameRateLimitTask?.cancel()
        frameRateLimitTask = nil
        currentFrameRateLoadingAsset = nil
        frameRateGeneration &+= 1
    }

    private func applyCurrentCompositionToQueueItems() {
        guard let queuePlayer = player else { return }
        let composition = currentVideoComposition
        templatePlayerItem?.videoComposition = composition
        queuePlayer.currentItem?.videoComposition = composition
        for item in queuePlayer.items() {
            item.videoComposition = composition
        }
    }

    // MARK: - Frame Rate Limiting
    func setFrameRateLimit(_ framesPerSecond: Float) {
        guard !isCleanedUp else { return }
        if requestedFrameRateLimit == framesPerSecond,
           frameRateLimitTask == nil,
           (framesPerSecond > 0
                ? videoCompositionOwner == .frameRate && currentVideoComposition != nil
                : videoCompositionOwner == .none && currentVideoComposition == nil) {
            return
        }
        requestedFrameRateLimit = framesPerSecond
        invalidateFrameRateCompositionBuild()
        let taskGeneration = frameRateGeneration
        let lifecycleGeneration = lifecycleGeneration

        // Force SDR owns videoComposition; do not overwrite with FPS.
        guard lastColorSpacePreference != .forceSDR else {
            Logger.debug("Skipping frame-rate composition while Force SDR is active", category: .videoPlayer)
            return
        }

        if framesPerSecond <= 0 {
            setVideoComposition(nil, owner: .none)
            Logger.debug("Frame rate limit disabled, using native frame rate", category: .videoPlayer)
            return
        }

        if videoCompositionOwner == .effects {
            // Drop effects composition now; FPS build is async.
            setVideoComposition(nil, owner: .none)
        }
        let expectedCompositionGeneration = videoCompositionGeneration

        guard let playerItem = player?.currentItem else {
            Logger.debug("Deferring frame-rate limit until player item is ready", category: .videoPlayer)
            return
        }

        let asset = playerItem.asset
        currentFrameRateLoadingAsset = asset
        frameRateLimitTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.frameRateGeneration == taskGeneration,
                   self.currentFrameRateLoadingAsset === asset {
                    self.currentFrameRateLoadingAsset = nil
                }
                if self.frameRateGeneration == taskGeneration {
                    self.frameRateLimitTask = nil
                }
            }
            do {
                try Task.checkCancellation()

                let videoTracks = try await asset.loadTracks(withMediaType: .video)
                try self.ensureLifecycleActive(lifecycleGeneration)
                guard let videoTrack = videoTracks.first else {
                    Logger.warning("Cannot set frame rate limit: No video track found", category: .videoPlayer)
                    return
                }

                try Task.checkCancellation()

                let naturalSize = try await videoTrack.load(.naturalSize)
                try self.ensureLifecycleActive(lifecycleGeneration)
                let transform = try await videoTrack.load(.preferredTransform)
                try self.ensureLifecycleActive(lifecycleGeneration)

                let targetFPS = framesPerSecond
                let duration = try await asset.load(.duration)
                try self.ensureLifecycleActive(lifecycleGeneration)

                let displayed = naturalSize.applying(transform)
                let renderSize = CGSize(width: abs(displayed.width), height: abs(displayed.height))

                let frameDuration = CMTime(value: 1, timescale: CMTimeScale(targetFPS))
                let composition: AVVideoComposition

                if #available(macOS 26.0, *) {
                    var layerInstrConfig = AVVideoCompositionLayerInstruction.Configuration(assetTrack: videoTrack)
                    layerInstrConfig.setTransform(transform, at: .zero)

                    var instrConfig = AVVideoCompositionInstruction.Configuration()
                    instrConfig.timeRange = CMTimeRange(start: .zero, duration: duration)
                    instrConfig.layerInstructions = [AVVideoCompositionLayerInstruction(configuration: layerInstrConfig)]

                    var compositionConfig = AVVideoComposition.Configuration()
                    compositionConfig.frameDuration = frameDuration
                    compositionConfig.renderSize = renderSize
                    compositionConfig.instructions = [AVVideoCompositionInstruction(configuration: instrConfig)]
                    compositionConfig.sourceTrackIDForFrameTiming = videoTrack.trackID

                    composition = AVVideoComposition(configuration: compositionConfig)
                } else {
                    let layerInstr = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
                    layerInstr.setTransform(transform, at: .zero)

                    let instr = AVMutableVideoCompositionInstruction()
                    instr.timeRange = CMTimeRange(start: .zero, duration: duration)
                    instr.layerInstructions = [layerInstr]

                    let mutableComposition = AVMutableVideoComposition()
                    mutableComposition.frameDuration = frameDuration
                    mutableComposition.renderSize = renderSize
                    mutableComposition.instructions = [instr]
                    mutableComposition.sourceTrackIDForFrameTiming = videoTrack.trackID

                    composition = mutableComposition
                }

                await MainActor.run { [weak self] in
                    // Force SDR may have taken the composition slot during the build.
                    guard let self,
                          self.isLifecycleActive(lifecycleGeneration),
                          self.frameRateGeneration == taskGeneration,
                          self.videoCompositionGeneration == expectedCompositionGeneration,
                          !self.isForceSDRActive else { return }
                    self.setVideoComposition(composition, owner: .frameRate)
                    Logger.info("Frame rate limit set to \(Int(targetFPS)) FPS", category: .videoPlayer)
                }
            } catch is CancellationError {
                Logger.debug("Frame rate limit task was cancelled", category: .videoPlayer)
            } catch {
                guard self.isLifecycleActive(lifecycleGeneration),
                      self.frameRateGeneration == taskGeneration else { return }
                Logger.error("Failed to set frame rate limit: \(error.localizedDescription)", category: .videoPlayer)
            }
        }
    }

    /// Wait until this player owns the FPS composition (then pixel-gate as needed).
    func prepareFrameRateLimit(
        _ framesPerSecond: Float,
        timeout: Duration
    ) async -> WallpaperPreparationResult {
        let reusesMatchingBuild = requestedFrameRateLimit == framesPerSecond
            && frameRateLimitTask != nil
            && currentVideoComposition == nil
            && !isForceSDRActive
        if !reusesMatchingBuild {
            setFrameRateLimit(framesPerSecond)
        }
        if isForceSDRActive || framesPerSecond <= 0 {
            return .ready
        }

        let generation = frameRateGeneration
        guard let task = frameRateLimitTask else {
            return videoCompositionOwner == .frameRate && currentVideoComposition != nil
                ? .ready
                : .failed
        }
        return await WallpaperPreparationWaiter.withHardDeadline(timeout: timeout) { [weak self] in
            await task.value
            guard let self else { return .cancelled }
            guard !Task.isCancelled,
                  !self.isCleanedUp,
                  self.frameRateGeneration == generation else {
                return .cancelled
            }
            return self.videoCompositionOwner == .frameRate
                && self.currentVideoComposition != nil
                ? .ready
                : .failed
        }
    }

    private func applyRequestedFrameRateLimitIfReady() {
        guard !isCleanedUp,
              player?.currentItem != nil,
              requestedFrameRateLimit > 0,
              currentVideoComposition == nil else { return }
        setFrameRateLimit(requestedFrameRateLimit)
    }

    // MARK: - Video Output Ownership

    private func bindVideoOutput(_ output: AVPlayerItemVideoOutput, to item: AVPlayerItem) {
        item.add(output)
        boundVideoOutputs.append((item, output))
    }

    private func unbindVideoOutput(_ output: AVPlayerItemVideoOutput, from item: AVPlayerItem) {
        guard let index = boundVideoOutputs.firstIndex(where: { $0.output === output }) else {
            // Already drained — removing twice is what this guard prevents.
            return
        }
        boundVideoOutputs.remove(at: index)
        item.remove(output)
    }

    private func drainVideoOutputs() {
        guard !boundVideoOutputs.isEmpty else { return }
        let drained = boundVideoOutputs
        boundVideoOutputs.removeAll()
        for entry in drained {
            entry.item.remove(entry.output)
        }
    }

    // MARK: - Suspension and Deep Hibernation

    /// Warm suspend: releases attached video outputs but keeps the player, so
    /// the layer still shows the last decoded frame — an occluded wallpaper that
    /// is asked to redraw must not go black. Play/pause stays with the caller;
    /// this only sets resource depth. Deep hibernation is the dwell-gated depth
    /// below it (`setHibernationEligible`).
    func setSuspended(_ suspended: Bool) {
        guard !isCleanedUp, isSuspended != suspended else { return }
        isSuspended = suspended
        if suspended {
            drainVideoOutputs()
            // A suspend landing mid-rebuild: the still frame is still up, so go
            // back to a phase the dwell can arm from instead of stranding the
            // player at `.restoring`, which never hibernates again.
            hibernation.noteSuspendedDuringRestore()
            // Eligibility can be pushed before the suspend lands; re-evaluate so
            // the arming order between the two calls does not matter.
            if isHibernationEligible {
                setHibernationEligible(true)
            }
        } else {
            isHibernationEligible = false
            cancelHibernationDwell()
            resumeFromHibernationIfNeeded()
        }
    }

    /// `ScreenManager` marks the player eligible while it is suspended for an
    /// absence-like reason (lock, display sleep, full-screen cover/occlusion).
    /// After `hibernationDelay` of uninterrupted eligibility the player, looper
    /// items, decode pool and `lwmem://` mapping are released behind a captured
    /// still frame; any flip back cancels the countdown.
    func setHibernationEligible(_ eligible: Bool) {
        isHibernationEligible = eligible
        // Deliberately not gated on `player != nil`: a wake rebuilds the player
        // asynchronously, so an absence that returns during that window would
        // cancel the dwell and — because eligibility is event-driven — never see
        // another push, leaving the rebuilt player resident for the whole
        // absence. `hibernateNow` treats a missing player as transient instead.
        guard eligible, !isCleanedUp, !isHibernated, isSuspended else {
            cancelHibernationDwell()
            return
        }
        hibernationDwell.arm(initial: hibernationDelay, retry: hibernationDelay) {
            [weak self] in
            guard let self else { return true }
            return await hibernateNow()
        }
    }

    private func cancelHibernationDwell() {
        hibernationDwell.cancel()
    }

    /// Returns false only on a transient blocker (an in-flight load or
    /// frame-rate build) so the countdown re-arms; true when hibernated or no
    /// longer applicable.
    private func hibernateNow() async -> Bool {
        guard !isCleanedUp, !isHibernated, isSuspended, isHibernationEligible else {
            return true
        }
        // Transient while a load can still produce a player (the wake window);
        // terminal once nothing is in flight to build one.
        guard player != nil else { return loadingTask == nil }
        // Never tear down under an in-flight load or composition build.
        guard loadingTask == nil, frameRateLimitTask == nil else { return false }

        let generation = lifecycleGeneration
        let stillFrame = await captureStillFrame()
        // Re-validated at publication, not at entry: the capture awaited.
        guard !isCleanedUp,
              !isHibernated,
              isSuspended,
              isHibernationEligible,
              lifecycleGeneration == generation,
              player != nil else {
            return true
        }
        // No cover, no teardown. Retiring anyway leaves the container with
        // neither a player nor a still, so the desktop goes black for the whole
        // absence — and the wake deadline cannot rescue it, since that bails out
        // when no still is on screen. Staying warm costs memory, not pixels.
        guard let stillFrame else {
            Logger.warning(
                "Video wallpaper stayed warm: still-frame capture failed, so hibernating would black the desktop",
                category: .videoPlayer
            )
            return true
        }
        guard hibernation.begin() == .presentCover else { return true }
        videoView?.showStillFrame(stillFrame)
        guard hibernation.coverDidPresent(true, generation: hibernation.generation)
            == .releaseResources else { return true }
        retirePlaybackState()
        Logger.info(
            "Video wallpaper hibernated: \(videoURL?.lastPathComponent ?? "<unknown>")",
            category: .videoPlayer
        )
        return true
    }

    private func resumeFromHibernationIfNeeded() {
        guard !isCleanedUp, let url = videoURL else { return }
        // `.rebuild` only from `.hibernated`; `.keepCover` means a rebuild is
        // already running under the still frame and must not be restarted.
        guard hibernation.requestRestore() == .rebuild else { return }
        // Armed here, not at the end of the rebuild: a load that fails before
        // `configurePlaybackComponents` never reaches the readiness handoff, and
        // this player cannot re-hibernate or re-wake afterwards, so the still
        // frame would stay on screen for the rest of the session.
        videoView?.clearStillFrameNoLaterThan(Self.stillFrameWakeDeadlineSeconds)
        Logger.info(
            "Waking hibernated video wallpaper: \(url.lastPathComponent)",
            category: .videoPlayer
        )
        // Rebuilt from live state through the same path a fresh load takes:
        // `configurePlaybackComponents` re-applies the colour-space preference
        // and re-runs the deferred frame-rate build, so nothing is restored from
        // a descriptor snapshotted at hibernate time.
        setupPlayer(with: url)
    }

    /// Width-capped like the HTML suspend snapshot: an uncapped 4K still is
    /// ~33 MB and would eat most of what releasing the decode pool returned.
    private static let maxStillFrameWidth: CGFloat = 1920
    /// Generous enough to cover a cold 4K rebuild off a slow volume; past it a
    /// frozen fake frame is worse than whatever the player is actually showing.
    private static let stillFrameWakeDeadlineSeconds: TimeInterval = 10

    private func captureStillFrame() async -> CGImage? {
        guard let player, let item = player.currentItem else { return nil }
        let generator = AVAssetImageGenerator(asset: item.asset)
        generator.appliesPreferredTrackTransform = true
        // Exact time, not the nearest keyframe: the still replaces a frame that
        // is currently on screen, so a tolerance window would pop.
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(
            width: Self.maxStillFrameWidth,
            height: Self.maxStillFrameWidth
        )
        let time = player.currentTime()
        // Non-Sendable generator crossing the await; same escape as
        // DesktopPictureFrameExtractor.
        nonisolated(unsafe) let capture = generator
        do {
            let (image, _) = try await capture.image(at: time)
            return image
        } catch {
            Logger.debug(
                "Hibernation still frame unavailable: \(error.localizedDescription)",
                category: .videoPlayer
            )
            return nil
        }
    }

    /// Teardown half of `cleanup()`: releases the queue player, the looper's
    /// items, the decode pool and the `lwmem://` mapping while keeping the
    /// window, view and user-facing configuration, so hibernation wakes through
    /// `setupPlayer` instead of a second recovery path.
    private func retirePlaybackState() {
        lifecycleGeneration &+= 1
        frameRateGeneration &+= 1

        currentLoadingAsset?.cancelLoading()
        currentLoadingAsset = nil
        currentFrameRateLoadingAsset?.cancelLoading()
        currentFrameRateLoadingAsset = nil
        loadingTask?.cancel()
        loadingTask = nil
        frameRateLimitTask?.cancel()
        frameRateLimitTask = nil
        hasRequestedPlaybackStart = false

        drainVideoOutputs()

        player?.pause()
        if isPlaying {
            isPlaying = false
        }

        playerLooper?.disableLooping()
        playerLooper = nil
        templatePlayerItem?.videoComposition = nil
        templatePlayerItem = nil

        currentItemSubscription?.cancel()
        currentItemSubscription = nil
        videoCompositionGeneration &+= 1
        currentVideoComposition = nil
        videoCompositionOwner = .none

        if inMemoryAssetLoader != nil {
            Logger.info(
                "Releasing in-memory video cache for \(videoURL?.lastPathComponent ?? "<unknown>")",
                category: .videoPlayer
            )
        }
        inMemoryAssetLoader = nil

        cleanupTasks.removeAll()

        videoView?.setPlayer(nil)
        player = nil
    }

    private func reportError(_ error: WallpaperRuntimeError) {
        runtimeError = error
        onError?(error)
    }

    private func makeRuntimeError(from error: Error, url: URL) -> WallpaperRuntimeError {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorNotConnectedToInternet {
            return .networkOffline
        }
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileReadNoPermissionError {
            return .fileAccessDenied(url)
        }
        return .mediaNotPlayable(url, code: nsError.code)
    }

    private func stopAccessingResource() {
        if accessToken, let url = videoURL {
            url.stopAccessingSecurityScopedResource()
            accessToken = false
        }
    }
    
    // MARK: - Cleanup
    func cleanup() {
        guard !isCleanedUp else { return }
        isCleanedUp = true
        Logger.debug("Cleaning up video player resources", category: .videoPlayer)

        isHibernationEligible = false
        cancelHibernationDwell()
        pause()
        retirePlaybackState()

        onCurrentItemAvailable = nil

        videoView?.setParticleEffect(.none, density: 0)
        videoView?.clearStillFrame()

        window?.close()

        window = nil
        videoView = nil

        stopAccessingResource()
        Logger.debug("Video player resources cleaned up", category: .videoPlayer)
    }

    deinit {
        let url = videoURL
        let hadAccess = accessToken
        if hadAccess, let url {
            Task { @MainActor in
                url.stopAccessingSecurityScopedResource()
            }
        }
    }
}
