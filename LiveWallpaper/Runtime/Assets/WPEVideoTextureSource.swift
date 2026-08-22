#if !LITE_BUILD
import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import LiveWallpaperCore
import Metal
import QuartzCore
import simd

/// Display-sized decode cap for MP4-in-`.tex` (B3). Nil means "leave the
/// decoder at source size" — either no cap was given, or the source already
/// fits. Never upscales.
enum WPEVideoOutputCap: Sendable {
    static func clampedPixelSize(source: CGSize, maxEdge: Int) -> CGSize? {
        guard maxEdge > 0 else { return nil }
        let srcW = Double(source.width)
        let srcH = Double(source.height)
        guard srcW >= 1, srcH >= 1 else { return nil }
        let longest = max(srcW, srcH)
        guard longest > Double(maxEdge) else { return nil }
        let scale = Double(maxEdge) / longest
        return CGSize(
            width: evenPixelCount((srcW * scale).rounded()),
            height: evenPixelCount((srcH * scale).rounded())
        )
    }

    /// Smaller of the drawable's long edge and the MetalFX texture cap.
    /// A zero drawable (tests, pre-`nextDrawable`) contributes nothing, so a
    /// MetalFX-off display with an unknown size stays uncapped.
    static func maxOutputEdge(drawableSize: CGSize, latchedTextureCap: Int?) -> Int? {
        let drawableEdge = max(
            Int(drawableSize.width.rounded()),
            Int(drawableSize.height.rounded())
        )
        let display = drawableEdge > 0 ? drawableEdge : nil
        let plan = latchedTextureCap.flatMap { $0 > 0 ? $0 : nil }
        switch (display, plan) {
        case let (d?, p?): return min(d, p)
        case let (d?, nil): return d
        case let (nil, p?): return p
        case (nil, nil): return nil
        }
    }

    static func sourceDisplaySize(fileURL: URL) async -> CGSize? {
        let asset = AVURLAsset(url: fileURL)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else {
            return nil
        }
        guard let natural = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform) else {
            return nil
        }
        let displayed = natural.applying(transform)
        let width = abs(displayed.width)
        let height = abs(displayed.height)
        guard width >= 1, height >= 1 else { return nil }
        return CGSize(width: width, height: height)
    }

    private static func evenPixelCount(_ value: Double) -> Int {
        max(2, Int(value) & ~1)
    }
}

/// Process-wide live-decoder tickets for MP4-in-`.tex` sources (B4).
/// All mutable state sits behind `lock`; render actors on different displays
/// share `shared` and can acquire concurrently.
final class WPEVideoDecoderAdmission: @unchecked Sendable {
    struct Ticket: Equatable, Sendable {
        fileprivate let id: UInt64
    }

    static let shared = WPEVideoDecoderAdmission(
        limit: WPEMemoryTier.current.videoDecoderLimit
    )

    let limit: Int
    private let lock = NSLock()
    private var nextID: UInt64 = 1
    private var active: Set<UInt64> = []

    init(limit: Int) {
        self.limit = max(0, limit)
    }

    func tryAcquire() -> Ticket? {
        lock.lock()
        defer { lock.unlock() }
        guard active.count < limit else { return nil }
        let id = nextID
        nextID += 1
        active.insert(id)
        return Ticket(id: id)
    }

    func release(_ ticket: Ticket) {
        lock.lock()
        active.remove(ticket.id)
        lock.unlock()
    }

    var activeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return active.count
    }

    var hasVacancy: Bool {
        lock.lock()
        defer { lock.unlock() }
        return active.count < limit
    }
}

/// MP4-in-`.tex` video source → current frame as Metal texture (player-level output on macOS 15+).
/// Player stays paused after init; performance profile starts it. Not `@MainActor` (renderer actor).
final class WPEVideoTextureSource {
    private let device: MTLDevice
    private let textureCache: CVMetalTextureCache
    private let player: AVQueuePlayer?
    /// Retained for source lifetime — looper drops item rotation if released.
    private let playerLooper: AVPlayerLooper?
    /// Resource-loader delegate is weak — hold the loader so in-memory bytes survive.
    private let inMemoryAssetLoader: InMemoryVideoAssetLoader?
    /// On-disk staging file; returned to disk cache on invalidate when onInvalidate set.
    private let cleanupURL: URL?
    /// Disk-cache reclaim hook on invalidate; nil unlinks the temp file (tests).
    private let onInvalidate: (@Sendable (URL) -> Void)?
    /// Item-level outputs (macOS 14 / legacy path), one per queue item, attached
    /// BEFORE the looper rotates to it: a freshly attached output only starts
    /// delivering once the decoder feeds it, so attaching after the rotation
    /// froze the last frame ~150 ms at every wrap (loop-seam probe, 2026-08-20).
    private var itemOutputs: [(item: AVPlayerItem, output: AVPlayerItemVideoOutput)] = []
    /// Outputs whose item left the looper queue. Releasing one tears down its
    /// pixel-buffer pool, and `latest`/`pendingRetirements` wrappers may still
    /// reference buffers from it (same crash as documented in `invalidate()`),
    /// so retirement is deferred: entries release two rotations later — by then
    /// the continuous publish stream has replaced and fence-swept every wrapper
    /// the old pool backed — or in `invalidate()` after the frame teardown.
    private var retiredItemOutputs: [(item: AVPlayerItem, output: AVPlayerItemVideoOutput)] = []
    /// macOS 15+ player-level output (AnyObject for 14 floor); spans looper item rotations.
    private var playerLevelOutput: AnyObject?
    /// Last player-level frame PTS — avoid re-wrapping the same buffer every tick.
    private var lastPlayerLevelPresentationTime: CMTime?
    private var latest: PublishedFrame?
    private var isInvalidated = false

    /// Conversion passes commit here. In the app this is the render executor's
    /// frame queue: same-queue hazard tracking then orders the NV12→BGRA pass
    /// ahead of the frame that samples the working texture (a private queue
    /// would be unordered against the render frame).
    private let conversionQueue: MTLCommandQueue
    private var conversionPipeline: MTLRenderPipelineState?
    private var conversionSetupFailed = false
    /// Reused private BGRA render target for NV12 conversion, plus the sRGB
    /// view the renderer samples. Recreated only when the decoder size changes.
    private var workingTarget: MTLTexture?
    private var workingSampleView: MTLTexture?
    /// HDR fallback engaged — outputs are pinned to 32BGRA for the source's lifetime.
    private var forcedBGRAOutput = false
    private var loggedUnsupportedFormat = false

    enum PublishPath {
        case biPlanar
        case bgra
    }

    #if DEBUG
    /// Last publish branch taken — observation seam for the NV12 tests.
    private(set) var lastPublishPathForTesting: PublishPath?
    var didForceBGRAOutputForTesting: Bool { forcedBGRAOutput }
    /// Frames handed to `publish` — the loop-seam probe measures the gaps between increments.
    private(set) var publishedFrameCountForTesting = 0
    #endif

    private struct PublishedFrame {
        let texture: MTLTexture
        /// CV wrappers stay retained here until the next publish replaces this
        /// frame (one wrapper on the BGRA path, luma + chroma on biplanar).
        /// At replacement they do NOT drop — they move into
        /// `pendingRetirements`, fenced by a command buffer committed on
        /// `conversionQueue` at that publish (NV12: the conversion pass itself;
        /// BGRA: an empty marker buffer). In the app `conversionQueue` is the
        /// render executor's frame queue, so the fence completes only after
        /// every render command buffer that could still sample this frame —
        /// the pool cannot recycle a plane mid-read anymore. Release happens
        /// on the publishing thread (`sweepRetiredFrames`) or in `invalidate()`
        /// after `waitUntilCompleted` on the fences; the completed handler
        /// itself never releases anything (see `WPEFrameFenceFlag`).
        let retainedSourceTextures: [CVMetalTexture]
    }

    /// Retired frame wrappers waiting for their GPU fence. Mutated only on the
    /// thread that owns this source (render executor in the app); the completed
    /// handler touches only the flag, never this array.
    private var pendingRetirements: [PendingFrameRetirement] = []

    /// Test seam: retired frames whose wrappers are still held for the GPU.
    var pendingRetirementCountForTesting: Int { pendingRetirements.count }

    #if DEBUG
    /// Test seam: total fences ever registered. `pendingRetirements` is empty
    /// both when a frame was fenced-and-drained and when it was never fenced at
    /// all, so the count is what distinguishes them at teardown.
    private(set) var retirementFencesCreatedForTesting = 0
    #endif

    /// Test seam: skip the macOS 15+ player-level output so the item-level
    /// (`AVPlayerItemVideoOutput`) branch — the shipping path on macOS 14 — is
    /// exercisable on an OS where both APIs exist.
    private let forceLegacyItemLevelOutput: Bool
    /// Decoder output size after the display cap. Nil = source dimensions.
    private let outputPixelSize: CGSize?
    private let admission: WPEVideoDecoderAdmission?
    private let decoderTicket: WPEVideoDecoderAdmission.Ticket?

    var isLiveDecoder: Bool { player != nil }

    #if DEBUG
    var isLiveDecoderForTesting: Bool { isLiveDecoder }
    var outputPixelSizeForTesting: CGSize? { outputPixelSize }
    #endif

    init(
        device: MTLDevice,
        videoURL: URL,
        commandQueue: MTLCommandQueue? = nil,
        onInvalidate: (@Sendable (URL) -> Void)? = nil,
        forceLegacyItemLevelOutputForTesting: Bool = false,
        outputPixelSize: CGSize? = nil,
        decoderAdmission: WPEVideoDecoderAdmission? = nil
    ) throws {
        self.cleanupURL = videoURL
        self.onInvalidate = onInvalidate
        self.device = device
        self.forceLegacyItemLevelOutput = forceLegacyItemLevelOutputForTesting
        self.outputPixelSize = outputPixelSize
        self.admission = decoderAdmission
        guard let queue = commandQueue ?? device.makeCommandQueue() else {
            throw WPEMetalTextureLoaderError.textureAllocationFailed
        }
        self.conversionQueue = queue

        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard status == kCVReturnSuccess, let cache else {
            throw WPEMetalTextureLoaderError.textureAllocationFailed
        }
        self.textureCache = cache

        let ticket = decoderAdmission?.tryAcquire()
        // Admission is a hard cap: a failed still-frame extract must not
        // start an uncounted live decoder (that was the overflow hole).
        let mustStayStill = decoderAdmission != nil && ticket == nil

        if mustStayStill {
            self.decoderTicket = nil
            self.inMemoryAssetLoader = nil
            self.player = nil
            self.playerLooper = nil
        } else {
            self.decoderTicket = ticket

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
            // No forward-buffer hint: measured inert on this path (unset / 2s / 32s
            // gave the same footprint, swing, frame delivery, request count and byte
            // volume across three loops), same as the wallpaper player.
            playerItem.canUseNetworkResourcesForLiveStreamingWhilePaused = false
            if let outputPixelSize {
                playerItem.preferredMaximumResolution = outputPixelSize
            }

            let queuePlayer = AVQueuePlayer()
            // Deliberately NOT `actionAtItemEnd = .none`: AVPlayerLooper loops by
            // advancing the queue, and pinning the player at item end stalls it at
            // the last frame of the first pass. Do not re-add it.
            // Prefetch next looped item before wrap to avoid sparse-decode slow-mo.
            queuePlayer.automaticallyWaitsToMinimizeStalling = true
            queuePlayer.preventsDisplaySleepDuringVideoPlayback = false
            queuePlayer.isMuted = true
            queuePlayer.volume = 0
            self.player = queuePlayer

            // macOS 15+: attach player-level output BEFORE looper enqueues items.
            if #available(macOS 15.0, *), !forceLegacyItemLevelOutputForTesting {
                self.playerLevelOutput = WPEPlayerLevelVideoOutput(
                    player: queuePlayer,
                    pixelFormats: Self.negotiatedPixelFormats,
                    outputSize: outputPixelSize
                )
            }

            self.playerLooper = AVPlayerLooper(player: queuePlayer, templateItem: playerItem)

            // macOS 14 (or forced legacy): item-level outputs; stay paused until
            // performance profile. `texture(at:)` falls through to this path
            // whenever `playerLevelOutput` is nil. The looper may not have enqueued
            // its replicas yet — every texture tick re-runs the attachment.
            if playerLevelOutput == nil {
                ensureItemOutputs()
            }
        }

        if mustStayStill,
           let stillBuffer = Self.makeStillPixelBuffer(fileURL: videoURL, outputSize: outputPixelSize) {
            publish(pixelBuffer: stillBuffer)
        }
    }

    func texture(at time: TimeInterval) -> MTLTexture? {
        _ = time   // Wall-clock pacing comes from AVPlayer, not the scene clock.
        guard !isInvalidated else { return nil }
        guard player != nil else { return latest?.texture }

        // Script play-once: freeze on natural loop wrap (don't mutate looper queue — races frame tap).
        if scriptControlled {
            if scriptHeldAtEnd { return latest?.texture }
            let playhead = playheadSeconds
            if playhead + 0.1 < scriptLastPlaybackSeconds {
                player?.pause()
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

        ensureItemOutputs()
        guard let videoOutput = currentItemOutput else { return latest?.texture }

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
            if !scriptControlled { player?.play() }
        case .suspended:
            player?.pause()
            // `sweepRetiredFrames` only runs from `publish`, and a paused source
            // never publishes again — without this the last replaced frame's
            // planes (~12 MiB NV12 4K, ~32 MiB BGRA) stay resident for the whole
            // suspension. Fences here are a conversion pass or an empty marker,
            // both already committed, so the wait is bounded and short.
            drainRetiredFrames()
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
        player?.play()
    }

    func scriptPause() {
        guard !isInvalidated else { return }
        enterScriptControlledMode()
        player?.pause()
    }

    /// Pause + rewind to first frame (reset play-once for replay).
    func scriptStop() {
        guard !isInvalidated else { return }
        enterScriptControlledMode()
        player?.pause()
        player?.seek(to: .zero)
        resetScriptPlayback()
    }

    func scriptSetCurrentTime(_ seconds: TimeInterval) {
        guard !isInvalidated else { return }
        enterScriptControlledMode()
        player?.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600))
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
        // Drain in-flight GPU work BEFORE releasing any CV wrapper: a pending
        // conversion pass may still be reading retired planes, and the
        // completed handlers only mark flags — they hold no wrapper to carry a
        // late release past this point. Bounded wait (one small pass per
        // fence, already committed).
        // The frame still published has never been retired — retirement happens
        // at replacement, and there is no next publish. On the biplanar path the
        // drain below already covers it (its conversion pass is the fence
        // registered by that publish), but a BGRA frame is sampled by the
        // renderer directly, so fence it now: without this, releasing the
        // wrapper hands the buffer back to a pool the decoder is still feeding
        // for the few milliseconds until `player.pause()` below, and a render
        // command buffer mid-flight would sample the overwritten surface.
        if let current = latest, let marker = conversionQueue.makeCommandBuffer() {
            retire(current, fence: marker)
            marker.commit()
        }
        drainRetiredFrames()
        // Drop the published frame BEFORE the player goes away. Its
        // `CVMetalTexture` backing references a pixel buffer owned by the video
        // output's pool, so releasing it after the outputs are removed /
        // `removeAllItems()` has torn that pool down dereferences a dead
        // backing — EXC_BAD_ACCESS at 0x0 inside `CVBufferBacking::releaseUser`,
        // reached from `WPEDisplayRenderActor` teardown on a scene swap.
        latest = nil
        CVMetalTextureCacheFlush(textureCache, 0)
        // Plain GPU allocations (not CV-backed) — safe to drop in any order;
        // the renderer's own reference keeps a sampled view alive if needed.
        workingTarget = nil
        workingSampleView = nil
        conversionPipeline = nil
        if #available(macOS 15.0, *), let playerOutput = playerLevelOutput as? WPEPlayerLevelVideoOutput {
            playerOutput.detach()
        }
        playerLevelOutput = nil
        lastPlayerLevelPresentationTime = nil
        playerLooper?.disableLooping()
        player?.pause()
        for entry in itemOutputs { entry.item.remove(entry.output) }
        itemOutputs.removeAll()
        for entry in retiredItemOutputs { entry.item.remove(entry.output) }
        retiredItemOutputs.removeAll()
        player?.removeAllItems()
        if let decoderTicket {
            admission?.release(decoderTicket)
        }
        if let cleanupURL {
            if let onInvalidate {
                onInvalidate(cleanupURL)
            } else {
                try? FileManager.default.removeItem(at: cleanupURL)
            }
        }
    }

    // MARK: - Internals

    /// Attach an output to every item the looper has enqueued (current + the
    /// pre-rolled next), and move entries whose item left the queue into the
    /// deferred-release list (see `retiredItemOutputs`).
    private func ensureItemOutputs() {
        guard let player else { return }
        let items = player.items()
        itemOutputs.removeAll { entry in
            guard !items.contains(where: { $0 === entry.item }) else { return false }
            retiredItemOutputs.append(entry)
            return true
        }
        while retiredItemOutputs.count > 2 {
            let entry = retiredItemOutputs.removeFirst()
            entry.item.remove(entry.output)
        }
        for item in items where !itemOutputs.contains(where: { $0.item === item }) {
            let attributes = Self.pixelBufferAttributes(
                pixelFormats: forcedBGRAOutput
                    ? [kCVPixelFormatType_32BGRA]
                    : Self.negotiatedPixelFormats,
                outputSize: outputPixelSize
            )
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: attributes)
            output.suppressesPlayerRendering = true
            item.add(output)
            itemOutputs.append((item, output))
        }
    }

    private var currentItemOutput: AVPlayerItemVideoOutput? {
        guard let current = player?.currentItem else { return nil }
        return itemOutputs.first { $0.item === current }?.output
    }

    private func publish(pixelBuffer: CVPixelBuffer) {
        #if DEBUG
        publishedFrameCountForTesting += 1
        #endif
        sweepRetiredFrames()
        switch CVPixelBufferGetPixelFormatType(pixelBuffer) {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            publishBiPlanar(pixelBuffer: pixelBuffer, fullRange: false)
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            publishBiPlanar(pixelBuffer: pixelBuffer, fullRange: true)
        case kCVPixelFormatType_32BGRA:
            publishBGRA(pixelBuffer: pixelBuffer)
        default:
            // A format outside the requested set — drop the frame, keep the last one.
            if !loggedUnsupportedFormat {
                loggedUnsupportedFormat = true
                Logger.warning(
                    "[WPE.video] unsupported pixel format \(CVPixelBufferGetPixelFormatType(pixelBuffer)) — frame dropped",
                    category: .wpeRender
                )
            }
        }
    }

    /// NV12 decode surface → reused private BGRA working texture via a
    /// fragment-shader YCbCr→RGB pass (matrix from the buffer's colorimetry
    /// attachments). HDR (PQ/HLG) is explicitly out of scope: those buffers
    /// re-pin the outputs to 32BGRA and take the legacy path instead.
    private func publishBiPlanar(pixelBuffer: CVPixelBuffer, fullRange: Bool) {
        if !forcedBGRAOutput, Self.isHDRTransfer(pixelBuffer) {
            rebuildOutputsForBGRAFallback(reason: "HDR transfer function detected")
            return
        }
        guard let pipeline = ensureConversionPipeline() else { return }
        let lumaWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let lumaHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let chromaWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1)
        let chromaHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)

        var lumaCV: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, nil,
            .r8Unorm, lumaWidth, lumaHeight, 0, &lumaCV
        ) == kCVReturnSuccess, let lumaCV, let lumaTexture = CVMetalTextureGetTexture(lumaCV) else {
            return
        }
        var chromaCV: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, nil,
            .rg8Unorm, chromaWidth, chromaHeight, 1, &chromaCV
        ) == kCVReturnSuccess, let chromaCV, let chromaTexture = CVMetalTextureGetTexture(chromaCV) else {
            return
        }
        guard let working = ensureWorkingTexture(width: lumaWidth, height: lumaHeight) else { return }

        let matrixAttachment = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, nil) as? String
        var conversion = WPEVideoYCbCrConversion.make(
            kind: WPEVideoYCbCrConversion.kind(matrixAttachment: matrixAttachment, sourceHeight: lumaHeight),
            fullRange: fullRange
        )

        let passDescriptor = MTLRenderPassDescriptor()
        passDescriptor.colorAttachments[0].texture = working.target
        passDescriptor.colorAttachments[0].loadAction = .dontCare
        passDescriptor.colorAttachments[0].storeAction = .store
        guard let commandBuffer = conversionQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else {
            return
        }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(lumaTexture, index: 0)
        encoder.setFragmentTexture(chromaTexture, index: 1)
        encoder.setFragmentBytes(&conversion, length: MemoryLayout<WPEVideoYCbCrConversion>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        // The conversion pass doubles as the retirement fence for the frame
        // being replaced (same queue as the render executor → completes after
        // any render pass that sampled it). Handler must attach pre-commit.
        retire(latest, fence: commandBuffer)
        commandBuffer.commit()

        latest = PublishedFrame(texture: working.sampleView, retainedSourceTextures: [lumaCV, chromaCV])
        #if DEBUG
        lastPublishPathForTesting = .biPlanar
        #endif
        // The cache holds a mapping per pixel buffer it has wrapped; the pool
        // rotates buffers, so without a periodic flush the mappings accumulate
        // for the source's lifetime. Flushing only drops unreferenced mappings —
        // the frame just stored in `latest` retains its wrappers, so the in-use
        // mappings survive.
        CVMetalTextureCacheFlush(textureCache, 0)
    }

    /// Legacy direct-wrap path: BGRA buffers arrive when NV12 cannot represent
    /// the source (alpha-bearing video) or after the HDR fallback pinned the
    /// outputs to 32BGRA.
    private func publishBGRA(pixelBuffer: CVPixelBuffer) {
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
        // No conversion pass on this path — commit an empty marker buffer as
        // the retirement fence for the frame being replaced. If the marker
        // cannot be created the wrappers drop immediately: that is exactly the
        // pre-hardening contract, not a new hole.
        if let previous = latest, let marker = conversionQueue.makeCommandBuffer() {
            retire(previous, fence: marker)
            marker.commit()
        }
        latest = PublishedFrame(texture: texture, retainedSourceTextures: [cvTexture])
        #if DEBUG
        lastPublishPathForTesting = .bgra
        #endif
        // See publishBiPlanar for why this flush is safe and required.
        CVMetalTextureCacheFlush(textureCache, 0)
    }

    /// Queue a replaced frame's CV wrappers behind a GPU fence. Also called
    /// with `nil` (biplanar first publish) purely to track the fence, so
    /// `invalidate()` can wait out the conversion pass reading the CURRENT
    /// frame's planes. Must run before `fence` is committed.
    private func retire(_ previous: PublishedFrame?, fence: MTLCommandBuffer) {
        #if DEBUG
        retirementFencesCreatedForTesting += 1
        #endif
        let flag = WPEFrameFenceFlag()
        fence.addCompletedHandler { _ in flag.markCompleted() }
        pendingRetirements.append(PendingFrameRetirement(
            fence: fence,
            flag: flag,
            wrappers: previous?.retainedSourceTextures ?? []
        ))
    }

    /// Release wrappers whose fence completed. Runs on the publishing thread,
    /// so wrapper release is never concurrent with player/pool teardown.
    private func sweepRetiredFrames() {
        guard !pendingRetirements.isEmpty else { return }
        pendingRetirements.removeAll { $0.flag.isCompleted }
    }

    /// Wait out every pending fence and release all retired wrappers. Same
    /// owning thread as `sweepRetiredFrames`; used where no further publish
    /// will arrive to sweep (suspend, invalidate).
    private func drainRetiredFrames() {
        for retirement in pendingRetirements {
            retirement.fence.waitUntilCompleted()
        }
        pendingRetirements.removeAll()
    }

    /// PQ/HLG-tagged buffers must not go through the 8-bit matrix path (that
    /// would drop the transfer function). P010/EDR is explicitly out of scope
    /// (plan P1.6) — pin the outputs back to 32BGRA and let AVFoundation own
    /// the HDR→SDR conversion, exactly the pre-NV12 behavior.
    static func isHDRTransfer(_ pixelBuffer: CVPixelBuffer) -> Bool {
        guard let transfer = CVBufferCopyAttachment(
            pixelBuffer, kCVImageBufferTransferFunctionKey, nil
        ) as? String else {
            return false
        }
        return transfer == (kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String)
            || transfer == (kCVImageBufferTransferFunction_ITU_R_2100_HLG as String)
    }

    private func rebuildOutputsForBGRAFallback(reason: String) {
        guard !forcedBGRAOutput else { return }
        forcedBGRAOutput = true
        bgraFallbackRebuildCountForTesting += 1
        Logger.info(
            "[WPE.video] \(reason) — pinning video output to 32BGRA",
            category: .wpeRender
        )
        // Deferred, not released: `latest` may still be backed by these pools.
        retiredItemOutputs.append(contentsOf: itemOutputs)
        itemOutputs.removeAll()
        if #available(macOS 15.0, *), !forceLegacyItemLevelOutput, let player {
            (playerLevelOutput as? WPEPlayerLevelVideoOutput)?.detach()
            playerLevelOutput = WPEPlayerLevelVideoOutput(
                player: player,
                pixelFormats: [kCVPixelFormatType_32BGRA],
                outputSize: outputPixelSize
            )
            lastPlayerLevelPresentationTime = nil
        } else {
            // `forcedBGRAOutput` is latched above, so this recreates every
            // item's output with the BGRA-pinned attributes.
            ensureItemOutputs()
        }
    }

    /// Test seam: number of HDR/shader-fallback output rebuilds (contract: at most 1).
    private(set) var bgraFallbackRebuildCountForTesting = 0

    private func ensureConversionPipeline() -> MTLRenderPipelineState? {
        if let conversionPipeline { return conversionPipeline }
        guard !conversionSetupFailed else { return nil }
        guard let library = device.makeDefaultLibrary(),
              let vertexFunction = library.makeFunction(name: "wpe_fullscreen_vertex"),
              let fragmentFunction = library.makeFunction(name: "wpe_video_nv12_convert_fragment") else {
            conversionSetupFailed = true
            // Same escape hatch as HDR: don't latch into dropping every NV12
            // frame (frozen video) — rebuild the outputs as 32BGRA and keep playing.
            rebuildOutputsForBGRAFallback(reason: "NV12 conversion shaders unavailable")
            return nil
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        do {
            let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            conversionPipeline = pipeline
            return pipeline
        } catch {
            conversionSetupFailed = true
            rebuildOutputsForBGRAFallback(reason: "NV12 conversion pipeline failed: \(error)")
            return nil
        }
    }

    private func ensureWorkingTexture(width: Int, height: Int) -> (target: MTLTexture, sampleView: MTLTexture)? {
        if let workingTarget, let workingSampleView,
           workingTarget.width == width, workingTarget.height == height {
            return (workingTarget, workingSampleView)
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        // `.pixelFormatView` is required for the sRGB view below. Omitting it
        // happens to work on this Mac even under the Metal validation layer,
        // but that is undocumented tolerance: without the flag the view can
        // fail elsewhere and the `?? target` fallback would silently sample
        // gamma bytes as linear — brighter video, no log.
        descriptor.usage = [.renderTarget, .shaderRead, .pixelFormatView]
        descriptor.storageMode = .private
        guard let target = device.makeTexture(descriptor: descriptor) else { return nil }
        target.label = "WPE video NV12 working texture"
        // The pass stores gamma R'G'B' bytes in a non-sRGB target; the renderer
        // samples through this sRGB view — byte-identical to the old
        // `.bgra8Unorm_srgb` CV wrap, with no double gamma conversion.
        let sampleView = target.makeTextureView(pixelFormat: .bgra8Unorm_srgb) ?? target
        workingTarget = target
        workingSampleView = sampleView
        return (target, sampleView)
    }

    /// Direct pixel-buffer ingest — test seam for hermetic NV12/HDR/BGRA
    /// branch coverage without AVPlayer timing.
    func ingestForTesting(pixelBuffer: CVPixelBuffer) {
        publish(pixelBuffer: pixelBuffer)
    }

    /// Decoder-native NV12 first (video then full range) with a 32BGRA tail:
    /// AVFoundation picks the closest match to the source, so 8-bit SDR lands
    /// on the biplanar path and sources NV12 cannot represent (alpha video)
    /// negotiate BGRA. Width/height are added only when `outputSize` is set,
    /// which is the display-sized cap (never an upscale).
    static let negotiatedPixelFormats: [OSType] = [
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        kCVPixelFormatType_32BGRA
    ]

    /// Metal video-output attrs as `[String: any Sendable]` for concurrency.
    static func pixelBufferAttributes(
        pixelFormats: [OSType],
        outputSize: CGSize?
    ) -> [String: any Sendable] {
        var attributes: [String: any Sendable] = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormats,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: any Sendable]()
        ]
        if let outputSize {
            attributes[kCVPixelBufferWidthKey as String] = Int(outputSize.width)
            attributes[kCVPixelBufferHeightKey as String] = Int(outputSize.height)
        }
        return attributes
    }

    private static func makeStillPixelBuffer(fileURL: URL, outputSize: CGSize?) -> CVPixelBuffer? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: fileURL))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .positiveInfinity
        if let outputSize {
            generator.maximumSize = outputSize
        }
        guard let image = try? generator.copyCGImage(at: .zero, actualTime: nil) else {
            return nil
        }
        return makeBGRAPixelBuffer(from: image)
    }

    private static func makeBGRAPixelBuffer(from image: CGImage) -> CVPixelBuffer? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: any Sendable]
        ]
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &buffer
        ) == kCVReturnSuccess, let buffer else {
            return nil
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            return nil
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    /// Resource-loader queue — byte-range fulfilment stays off main.
    private static let resourceLoaderQueue = DispatchQueue(
        label: "app.livewallpaper.wpe.video.in-memory-loader",
        qos: .userInitiated,
        autoreleaseFrequency: .workItem
    )

    /// Current item time (s); used by play-once wrap detection in all builds.
    private var playheadSeconds: TimeInterval {
        guard let time = player?.currentTime(), time.isValid, !time.isIndefinite else { return 0 }
        let seconds = time.seconds
        return seconds.isFinite ? seconds : 0
    }

    // MARK: - Intro→loop phase alignment

    /// On-disk MP4 for offline analysis (custom in-memory URL is unreadable by ImageGenerator).
    var analysisURL: URL? { cleanupURL }

    var currentPlayheadSeconds: TimeInterval { playheadSeconds }

    var loopDurationSeconds: TimeInterval {
        let duration = player?.currentItem?.duration ?? .invalid
        guard duration.isValid, !duration.isIndefinite else { return 0 }
        let seconds = duration.seconds
        return seconds.isFinite ? seconds : 0
    }

    var isActivelyPlaying: Bool { !isInvalidated && (player?.rate ?? 0) > 0 }

    /// Phase-align seek (does not enter script-controlled mode).
    func alignPlayhead(to seconds: TimeInterval) {
        guard !isInvalidated, !scriptControlled else { return }
        player?.seek(
            to: CMTime(seconds: max(0, seconds), preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }
}

extension WPEVideoTextureSource: WPEDynamicTextureSource {}

/// The ONLY thing a frame-fence completed handler captures. It must never
/// capture the source, the texture cache, or the wrappers themselves: an
/// earlier attempt that released wrappers from the handler crashed when the
/// handler fired after `invalidate()` had torn the buffer pool down
/// (`CVBufferBacking::releaseUser` on a dead backing). A handler that only
/// flips this flag is safe to fire at any time, on any thread.
private final class WPEFrameFenceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    func markCompleted() {
        lock.lock()
        completed = true
        lock.unlock()
    }

    var isCompleted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return completed
    }
}

/// Wrappers of a replaced frame plus the command buffer whose completion
/// proves the GPU is done reading them. Owned exclusively by
/// `WPEVideoTextureSource.pendingRetirements`.
private struct PendingFrameRetirement {
    let fence: MTLCommandBuffer
    let flag: WPEFrameFenceFlag
    let wrappers: [CVMetalTexture]
}

/// macOS 15+ player-level frame tap (spans looper rotations). Pixel formats
/// come from the caller: NV12-first for the normal path, 32BGRA-only after the
/// HDR fallback.
@available(macOS 15.0, *)
private final class WPEPlayerLevelVideoOutput {
    private let output: AVPlayerVideoOutput
    private weak var player: AVQueuePlayer?

    init(player: AVQueuePlayer, pixelFormats: [OSType], outputSize: CGSize?) {
        let specification = AVVideoOutputSpecification(tagCollections: [.monoscopicForVideoOutput()])
        specification.defaultOutputSettings = WPEVideoTextureSource.pixelBufferAttributes(
            pixelFormats: pixelFormats,
            outputSize: outputSize
        )
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

/// CPU-side YCbCr→RGB conversion parameters, laid out to match the shader's
/// `WPEVideoYCbCrUniforms` (float3x3 + float3, 64 bytes) so it can be passed
/// via `setFragmentBytes` directly. Living on the CPU lets tests pin the
/// coefficients against the published BT.601/709/2020 constants.
struct WPEVideoYCbCrConversion: Equatable {
    enum MatrixKind: Equatable {
        case bt601
        case bt709
        case bt2020
    }

    var matrix: simd_float3x3
    var offset: SIMD3<Float>

    /// Honors the buffer's `kCVImageBufferYCbCrMatrixKey`; untagged buffers use
    /// the conventional SD→601 / HD→709 line-count heuristic.
    static func kind(matrixAttachment: String?, sourceHeight: Int) -> MatrixKind {
        if let matrixAttachment {
            if matrixAttachment == (kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String) { return .bt709 }
            if matrixAttachment == (kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String) { return .bt601 }
            if matrixAttachment == (kCVImageBufferYCbCrMatrix_ITU_R_2020 as String) { return .bt2020 }
        }
        return sourceHeight < 720 ? .bt601 : .bt709
    }

    /// Standard full-matrix derivation from the luma coefficients:
    /// R = y + 2(1−Kr)·cr, G = y − 2Kb(1−Kb)/Kg·cb − 2Kr(1−Kr)/Kg·cr,
    /// B = y + 2(1−Kb)·cb, with 219/224 range expansion folded in for
    /// video-range sources.
    static func make(kind: MatrixKind, fullRange: Bool) -> WPEVideoYCbCrConversion {
        let (kr, kb): (Float, Float)
        switch kind {
        case .bt601: (kr, kb) = (0.299, 0.114)
        case .bt709: (kr, kb) = (0.2126, 0.0722)
        case .bt2020: (kr, kb) = (0.2627, 0.0593)
        }
        let kg = 1 - kr - kb
        let yScale: Float = fullRange ? 1 : 255.0 / 219.0
        let cScale: Float = fullRange ? 1 : 255.0 / 224.0
        let matrix = simd_float3x3(columns: (
            SIMD3(yScale, yScale, yScale),
            SIMD3(0, -2 * kb * (1 - kb) / kg * cScale, 2 * (1 - kb) * cScale),
            SIMD3(2 * (1 - kr) * cScale, -2 * kr * (1 - kr) / kg * cScale, 0)
        ))
        let offset = SIMD3<Float>(fullRange ? 0 : 16.0 / 255.0, 128.0 / 255.0, 128.0 / 255.0)
        return WPEVideoYCbCrConversion(matrix: matrix, offset: offset)
    }

    /// Reference implementation of the shader's math for test comparison.
    func apply(_ ycbcr: SIMD3<Float>) -> SIMD3<Float> {
        simd_clamp(matrix * (ycbcr - offset), SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 1))
    }
}
#endif
