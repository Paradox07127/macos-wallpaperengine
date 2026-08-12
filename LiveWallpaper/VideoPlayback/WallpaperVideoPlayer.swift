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
        assetLoaderOverride: AssetLoaderOverride? = nil
    ) {
        Logger.functionStart(category: .videoPlayer)
        self.initialFrame = frame
        self.fitMode = fitMode
        self.videoURL = url
        self.packageEntryName = packageEntryName
        self.startsHidden = startsHidden
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
        accessToken = url.startAccessingSecurityScopedResource()
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
                        bufferDuration: Self.inMemoryBufferDuration,
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

                let cmDuration: CMTime?
                do {
                    let loadedDuration = try await asset.load(.duration)
                    try self.ensureLifecycleActive(generation)
                    cmDuration = loadedDuration
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    try self.ensureLifecycleActive(generation)
                    cmDuration = nil
                }
                let durationSeconds = Self.usableDuration(from: cmDuration)

                let activeAsset: AVURLAsset
                let loader: InMemoryVideoAssetLoader?
                let bufferDuration: TimeInterval

                if let packagedLoader {
                    // Package path always windowed mmap — skip size-based memory decision.
                    activeAsset = asset
                    loader = packagedLoader
                    bufferDuration = Self.inMemoryBufferDuration
                } else {
                    let fileSize = Self.fileSize(of: url)
                    let memoryCached = Self.shouldUseInMemoryCache(fileSize: fileSize)
                    // In-RAM path uses a flat short buffer, not duration×bitrate.
                    bufferDuration = memoryCached
                        ? Self.inMemoryBufferDuration
                        : Self.bufferDuration(forDuration: durationSeconds)

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
                                "Loaded \(fileSize / (1024 * 1024)) MB video into RAM — 0 physical reads expected after warmup",
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
                    bufferDuration: bufferDuration,
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
            func unbindOutput() {
                if let boundItem, let output {
                    boundItem.remove(output)
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
                    let nextOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                    ])
                    item.add(nextOutput)
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
        bufferDuration: TimeInterval,
        generation: UInt64,
        timer: PerformanceTimer,
        url: URL
    ) async throws {
        try ensureLifecycleActive(generation)
        currentLoadingAsset = asset
        inMemoryAssetLoader = loader
        configurePlaybackComponents(
            with: asset,
            bufferDuration: bufferDuration,
            generation: generation
        )
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
    
    /// Cap full-buffer mode; longer clips fall back to 5s (avoids multi-GB buffers).
    private static let fullBufferCapSeconds: TimeInterval = 60

    /// In-memory path buffer: 5s decoder headroom (bytes already mmap'd).
    private static let inMemoryBufferDuration: TimeInterval = 5

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

    /// Loop wrap headroom for full-buffer mode (looper cross-fades past duration).
    private static let bufferSafetyMargin: TimeInterval = 2

    private static func usableDuration(from cmTime: CMTime?) -> TimeInterval {
        guard let cmTime, cmTime.isValid, !cmTime.isIndefinite else { return 0 }
        let seconds = cmTime.seconds
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return seconds
    }

    private static func bufferDuration(forDuration durationSeconds: TimeInterval) -> TimeInterval {
        guard durationSeconds > 0 else { return 5 }
        if durationSeconds <= fullBufferCapSeconds {
            return durationSeconds + bufferSafetyMargin
        }
        return 5
    }

    private func configurePlaybackComponents(
        with asset: AVURLAsset,
        bufferDuration: TimeInterval,
        generation: UInt64
    ) {
        guard isLifecycleActive(generation) else { return }
        let playerItem = AVPlayerItem(asset: asset)

        playerItem.preferredForwardBufferDuration = bufferDuration
        // Local sources: skip composition seek waits and remote stall heuristics.
        playerItem.seekingWaitsForVideoCompositionRendering = false
        playerItem.audioTimePitchAlgorithm = .timeDomain
        playerItem.canUseNetworkResourcesForLiveStreamingWhilePaused = false
        Logger.debug("Forward buffer hint: \(String(format: "%.1f", bufferDuration))s", category: .videoPlayer)

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
        
        let videoWindow = VideoWallpaperWindow(frame: initialFrame)
        let containerView = VideoContainerView(frame: initialFrame)
        containerView.fitMode = fitMode
        videoWindow.contentView = containerView
        containerView.setPlayer(player)
        containerView.setSpanRenderConfiguration(pendingSpanRenderConfiguration)

        videoWindow.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        if startsHidden {
            videoWindow.orderOut(nil)
        } else {
            videoWindow.orderBack(nil)
        }

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
    }

    private func detectFormatInfoIfNeeded(asset: AVURLAsset, generation: UInt64) async throws {
        guard formatInfo == nil else { return }
        let detected = try await PlayableVideoLoader.detectFormat(asset: asset)
        try ensureLifecycleActive(generation)
        formatInfo = detected
        reconcileDynamicRange()
    }

    private func reconcileDynamicRange() {
        let usesExtendedDynamicRange = VideoDynamicRangePolicy.usesExtendedDynamicRange(
            formatInfo: formatInfo,
            preference: lastColorSpacePreference
        )
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
            player.publisher(for: \.timeControlStatus)
                .map { $0 == .playing }
                .removeDuplicates()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] isCurrentlyPlaying in
                    guard let self else { return }
                    self.isPlaying = isCurrentlyPlaying
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
        playbackSpeed = speed
        player?.defaultRate = Float(speed)
        if player?.timeControlStatus == .playing {
            player?.rate = Float(speed)
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

    func setParticleDensity(_ density: Double) {
        videoView?.setParticleDensity(density)
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

    func setWindowVisible(_ visible: Bool) {
        guard let window else { return }
        if visible {
            window.orderBack(nil)
        } else {
            window.orderOut(nil)
        }
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
        lifecycleGeneration &+= 1
        frameRateGeneration &+= 1
        Logger.debug("Cleaning up video player resources", category: .videoPlayer)

        currentLoadingAsset?.cancelLoading()
        currentLoadingAsset = nil
        currentFrameRateLoadingAsset?.cancelLoading()
        currentFrameRateLoadingAsset = nil
        loadingTask?.cancel()
        loadingTask = nil
        frameRateLimitTask?.cancel()
        frameRateLimitTask = nil
        hasRequestedPlaybackStart = false

        pause()

        playerLooper?.disableLooping()
        playerLooper = nil
        templatePlayerItem?.videoComposition = nil
        templatePlayerItem = nil

        currentItemSubscription?.cancel()
        currentItemSubscription = nil
        onCurrentItemAvailable = nil
        videoCompositionGeneration &+= 1
        currentVideoComposition = nil
        videoCompositionOwner = .none

        if inMemoryAssetLoader != nil {
            Logger.info("Releasing in-memory video cache for \(videoURL?.lastPathComponent ?? "<unknown>")", category: .videoPlayer)
        }
        inMemoryAssetLoader = nil

        cleanupTasks.removeAll()

        videoView?.setParticleEffect(.none, density: 0)

        window?.close()

        window = nil
        videoView = nil
        player = nil
        
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
