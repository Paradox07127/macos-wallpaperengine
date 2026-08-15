#if !LITE_BUILD
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import LiveWallpaperCore
import Metal
import QuartzCore

/// MP4-in-`.tex` video source → current frame as Metal texture (player-level output on macOS 15+).
/// Player stays paused after init; performance profile starts it. Not `@MainActor` (renderer actor).
final class WPEVideoTextureSource {
    private let textureCache: CVMetalTextureCache
    private let player: AVQueuePlayer
    private let videoOutput: AVPlayerItemVideoOutput
    /// Retained for source lifetime — looper drops item rotation if released.
    private let playerLooper: AVPlayerLooper
    /// Resource-loader delegate is weak — hold the loader so in-memory bytes survive.
    private let inMemoryAssetLoader: InMemoryVideoAssetLoader?
    /// On-disk staging file; returned to disk cache on invalidate when onInvalidate set.
    private let cleanupURL: URL?
    /// Disk-cache reclaim hook on invalidate; nil unlinks the temp file (tests).
    private let onInvalidate: (@Sendable (URL) -> Void)?
    /// Rebind item-level videoOutput across looper item rotations.
    private weak var attachedOutputItem: AVPlayerItem?
    /// macOS 15+ player-level output (AnyObject for 14 floor); spans looper item rotations.
    private var playerLevelOutput: AnyObject?
    /// Last player-level frame PTS — avoid re-wrapping the same buffer every tick.
    private var lastPlayerLevelPresentationTime: CMTime?
    private var latest: PublishedFrame?
    private var isInvalidated = false

    private struct PublishedFrame {
        let texture: MTLTexture
        let cvTexture: CVMetalTexture
    }

    init(
        device: MTLDevice,
        videoURL: URL,
        onInvalidate: (@Sendable (URL) -> Void)? = nil
    ) throws {
        self.cleanupURL = videoURL
        self.onInvalidate = onInvalidate

        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard status == kCVReturnSuccess, let cache else {
            throw WPEMetalTextureLoaderError.textureAllocationFailed
        }
        self.textureCache = cache

        let assetOptions: [String: any Sendable] = [
            AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue,
            AVURLAssetAllowsCellularAccessKey: false,
            AVURLAssetAllowsExpensiveNetworkAccessKey: false,
            AVURLAssetAllowsConstrainedNetworkAccessKey: false
        ]
        let activeURL: URL
        let loader: InMemoryVideoAssetLoader?
        do {
            let result = try InMemoryVideoAssetLoader.load(from: videoURL)
            loader = result.loader
            activeURL = result.customURL
        } catch {
            loader = nil
            activeURL = videoURL
        }
        self.inMemoryAssetLoader = loader

        let asset = AVURLAsset(url: activeURL, options: assetOptions)
        if let loader {
            asset.resourceLoader.setDelegate(loader, queue: Self.resourceLoaderQueue)
        }

        let playerItem = AVPlayerItem(asset: asset)
        playerItem.preferredForwardBufferDuration = Self.bufferHintSeconds
        playerItem.canUseNetworkResourcesForLiveStreamingWhilePaused = false

        let queuePlayer = AVQueuePlayer()
        // Prefetch next looped item before wrap to avoid sparse-decode slow-mo.
        queuePlayer.automaticallyWaitsToMinimizeStalling = true
        queuePlayer.preventsDisplaySleepDuringVideoPlayback = false
        queuePlayer.isMuted = true
        queuePlayer.volume = 0
        self.player = queuePlayer

        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: Self.outputPixelBufferAttributes)
        output.suppressesPlayerRendering = true
        self.videoOutput = output

        // macOS 15+: attach player-level output BEFORE looper enqueues items.
        if #available(macOS 15.0, *) {
            self.playerLevelOutput = WPEPlayerLevelVideoOutput(player: queuePlayer)
        }

        self.playerLooper = AVPlayerLooper(player: queuePlayer, templateItem: playerItem)

        // macOS 14: item-level output; stay paused until performance profile.
        if #unavailable(macOS 15.0) {
            attachOutputIfNeeded(to: queuePlayer.currentItem ?? playerItem)
        }
    }

    func texture(at time: TimeInterval) -> MTLTexture? {
        _ = time   // Wall-clock pacing comes from AVPlayer, not the scene clock.
        guard !isInvalidated else { return nil }

        // Script play-once: freeze on natural loop wrap (don't mutate looper queue — races frame tap).
        if scriptControlled {
            if scriptHeldAtEnd { return latest?.texture }
            let playhead = playheadSeconds
            if playhead + 0.1 < scriptLastPlaybackSeconds {
                player.pause()
                scriptHeldAtEnd = true
                return latest?.texture   // hold the pre-wrap (≈ last) frame
            }
            scriptLastPlaybackSeconds = playhead
        }

        if #available(macOS 15.0, *), let playerOutput = playerLevelOutput as? WPEPlayerLevelVideoOutput {
            if let frame = playerOutput.currentFrame(),
               lastPlayerLevelPresentationTime.map({ CMTimeCompare($0, frame.presentationTime) != 0 }) ?? true {
                publish(pixelBuffer: frame.pixelBuffer)
                lastPlayerLevelPresentationTime = frame.presentationTime
            }
            return latest?.texture
        }

        attachOutputIfNeeded(to: player.currentItem)

        let host = CACurrentMediaTime()
        let itemTime = videoOutput.itemTime(forHostTime: host)
        guard itemTime.isValid else { return latest?.texture }

        if videoOutput.hasNewPixelBuffer(forItemTime: itemTime),
           let pixelBuffer = videoOutput.copyPixelBuffer(
               forItemTime: itemTime,
               itemTimeForDisplay: nil
           ) {
            publish(pixelBuffer: pixelBuffer)
        }
        return latest?.texture
    }

    func applyPerformanceProfile(_ profile: WallpaperPerformanceProfile) {
        guard !isInvalidated else { return }
        switch profile {
        case .quality:
            // Script-owned source: don't force-play on policy resume.
            if !scriptControlled { player.play() }
        case .suspended:
            player.pause()
        }
    }

    // MARK: - SceneScript playback control (`thisLayer.getVideoTexture()`)

    /// Script owns playback — policy stops force-play; texture path becomes play-once.
    private var scriptControlled = false
    /// Last playhead for loop-wrap detection (backward jump).
    private var scriptLastPlaybackSeconds: TimeInterval = 0
    /// Play-once reached end and froze on last frame.
    private var scriptHeldAtEnd = false

    private func enterScriptControlledMode() {
        guard !scriptControlled else { return }
        scriptControlled = true
        resetScriptPlayback()
    }

    /// Clear freeze + wrap baseline for a fresh play-through.
    private func resetScriptPlayback() {
        scriptHeldAtEnd = false
        scriptLastPlaybackSeconds = playheadSeconds
    }

    func scriptPlay() {
        guard !isInvalidated else { return }
        enterScriptControlledMode()
        resetScriptPlayback()
        player.play()
    }

    func scriptPause() {
        guard !isInvalidated else { return }
        enterScriptControlledMode()
        player.pause()
    }

    /// Pause + rewind to first frame (reset play-once for replay).
    func scriptStop() {
        guard !isInvalidated else { return }
        enterScriptControlledMode()
        player.pause()
        player.seek(to: .zero)
        resetScriptPlayback()
    }

    func scriptSetCurrentTime(_ seconds: TimeInterval) {
        guard !isInvalidated else { return }
        enterScriptControlledMode()
        player.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600))
        resetScriptPlayback()
    }

    /// A playing `AVQueuePlayer` is retained by AVFoundation's own CoreMedia
    /// threads, so dropping the last Swift reference does NOT stop it: the MP4
    /// and its decode buffers stay resident and the decoder keeps running.
    /// Sampled in Release at 10.8 GB / 42 threads with four live
    /// `coremedia.audioqueue.source` sets. `invalidate()` is idempotent, so this
    /// is a pure backstop for paths that never reached an explicit teardown.
    deinit {
        invalidate()
    }

    func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        // Drop the published frame BEFORE the player goes away. Its
        // `CVMetalTexture` backing references a pixel buffer owned by the video
        // output's pool, so releasing it after `remove(videoOutput)` /
        // `removeAllItems()` have torn that pool down dereferences a dead
        // backing — EXC_BAD_ACCESS at 0x0 inside `CVBufferBacking::releaseUser`,
        // reached from `WPEDisplayRenderActor` teardown on a scene swap.
        latest = nil
        CVMetalTextureCacheFlush(textureCache, 0)
        if #available(macOS 15.0, *), let playerOutput = playerLevelOutput as? WPEPlayerLevelVideoOutput {
            playerOutput.detach()
        }
        playerLevelOutput = nil
        lastPlayerLevelPresentationTime = nil
        playerLooper.disableLooping()
        player.pause()
        if let item = attachedOutputItem {
            item.remove(videoOutput)
            attachedOutputItem = nil
        }
        player.removeAllItems()
        if let cleanupURL {
            if let onInvalidate {
                onInvalidate(cleanupURL)
            } else {
                try? FileManager.default.removeItem(at: cleanupURL)
            }
        }
    }

    // MARK: - Internals

    private func attachOutputIfNeeded(to item: AVPlayerItem?) {
        guard let item, item !== attachedOutputItem else { return }
        if let previous = attachedOutputItem {
            previous.remove(videoOutput)
        }
        item.add(videoOutput)
        attachedOutputItem = item
    }

    private func publish(pixelBuffer: CVPixelBuffer) {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var cvTexture: CVMetalTexture?
        var status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .bgra8Unorm_srgb,
            width,
            height,
            0,
            &cvTexture
        )
        if status != kCVReturnSuccess {
            status = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault,
                textureCache,
                pixelBuffer,
                nil,
                .bgra8Unorm,
                width,
                height,
                0,
                &cvTexture
            )
        }
        guard status == kCVReturnSuccess,
              let cvTexture,
              let texture = CVMetalTextureGetTexture(cvTexture) else {
            return
        }
        latest = PublishedFrame(texture: texture, cvTexture: cvTexture)
        // The cache holds a mapping per pixel buffer it has wrapped; the pool
        // rotates buffers, so without a periodic flush the mappings accumulate
        // for the source's lifetime. Flushing only drops unreferenced mappings —
        // the frame just stored in `latest` retains its `CVMetalTexture`, so
        // the in-use mapping survives.
        CVMetalTextureCacheFlush(textureCache, 0)
    }

    /// 2s forward buffer (RAM-resident asset; longer buffers only cost decoder state).
    private static let bufferHintSeconds: TimeInterval = 2

    /// BGRA Metal video-output attrs as `[String: any Sendable]` for concurrency.
    private static let outputPixelBufferAttributes: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferMetalCompatibilityKey as String: true,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: any Sendable]()
    ]

    /// Resource-loader queue — byte-range fulfilment stays off main.
    private static let resourceLoaderQueue = DispatchQueue(
        label: "app.livewallpaper.wpe.video.in-memory-loader",
        qos: .userInitiated,
        autoreleaseFrequency: .workItem
    )

    /// Current item time (s); used by play-once wrap detection in all builds.
    private var playheadSeconds: TimeInterval {
        let time = player.currentTime()
        guard time.isValid, !time.isIndefinite else { return 0 }
        let seconds = time.seconds
        return seconds.isFinite ? seconds : 0
    }

    // MARK: - Intro→loop phase alignment

    /// On-disk MP4 for offline analysis (custom in-memory URL is unreadable by ImageGenerator).
    var analysisURL: URL? { cleanupURL }

    var currentPlayheadSeconds: TimeInterval { playheadSeconds }

    var loopDurationSeconds: TimeInterval {
        let duration = player.currentItem?.duration ?? .invalid
        guard duration.isValid, !duration.isIndefinite else { return 0 }
        let seconds = duration.seconds
        return seconds.isFinite ? seconds : 0
    }

    var isActivelyPlaying: Bool { !isInvalidated && player.rate > 0 }

    /// Phase-align seek (does not enter script-controlled mode).
    func alignPlayhead(to seconds: TimeInterval) {
        guard !isInvalidated, !scriptControlled else { return }
        player.seek(
            to: CMTime(seconds: max(0, seconds), preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }
}

extension WPEVideoTextureSource: WPEDynamicTextureSource {}

/// macOS 15+ player-level frame tap (spans looper rotations; 32BGRA for existing texture path).
@available(macOS 15.0, *)
private final class WPEPlayerLevelVideoOutput {
    private let output: AVPlayerVideoOutput
    private weak var player: AVQueuePlayer?

    init(player: AVQueuePlayer) {
        let specification = AVVideoOutputSpecification(tagCollections: [.monoscopicForVideoOutput()])
        // Pin 32BGRA so existing .bgra8Unorm[_srgb] texture path is unchanged.
        let outputSettings: [String: any Sendable] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: any Sendable]()
        ]
        specification.defaultOutputSettings = outputSettings
        let output = AVPlayerVideoOutput(specification: specification)
        player.videoOutput = output
        self.output = output
        self.player = player
    }

    /// Frame for current host time, or nil (caller keeps last frame).
    func currentFrame() -> (pixelBuffer: CVPixelBuffer, presentationTime: CMTime)? {
        guard let sample = output.taggedBuffers(
            forHostTime: CMClockGetTime(.hostTimeClock)
        ) else {
            return nil
        }
        for tagged in sample.taggedBufferGroup {
            if case let .pixelBuffer(pixelBuffer) = tagged.buffer {
                return (pixelBuffer, sample.presentationTime)
            }
        }
        return nil
    }

    func detach() {
        player?.videoOutput = nil
    }
}
#endif
