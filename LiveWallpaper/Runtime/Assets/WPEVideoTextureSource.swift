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

/// Display-sized decode cap for MP4-in-`.tex`. Nil means leave the decoder at source size (no cap, or source already fits). Never upscales.
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

    /// Smaller of drawable long edge and MetalFX cap; a zero drawable contributes nothing so an unknown size stays uncapped.
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

/// Process-wide live-decoder tickets for MP4-in-`.tex` sources.
/// All mutable state sits behind `lock`; render actors on different displays share `shared`
/// and can acquire concurrently.
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

final class WPEVideoTextureSource {
    private let device: MTLDevice
    private let textureCache: CVMetalTextureCache
    private let player: AVQueuePlayer?
    /// Retained for source lifetime — looper drops item rotation if released.
    private let playerLooper: AVPlayerLooper?
    /// Resource-loader delegate is weak — hold the loader so in-memory bytes survive.
    private let inMemoryAssetLoader: InMemoryVideoAssetLoader?
    private let cleanupURL: URL?
    /// Disk-cache reclaim hook on invalidate; nil unlinks the temp file (tests).
    private let onInvalidate: (@Sendable (URL) -> Void)?
    /// Attach BEFORE the looper rotates to the item: attaching after would freeze the last frame at every wrap.
    private var itemOutputs: [(item: AVPlayerItem, output: AVPlayerItemVideoOutput)] = []
    /// Retirement is deferred two rotations (or `invalidate()`): releasing immediately would tear down a pool wrappers may still reference.
    private var retiredItemOutputs: [(item: AVPlayerItem, output: AVPlayerItemVideoOutput)] = []
    private var playerLevelOutput: AnyObject?
    /// Last player-level frame PTS — avoid re-wrapping the same buffer every tick.
    private var lastPlayerLevelPresentationTime: CMTime?
    private var latest: PublishedFrame?
    /// Staged until its NV12→BGRA pass is encoded into the scene command buffer, so a dropped buffer is never sampled unconverted.
    private var staged: StagedFrame?
    /// Arm on the scene buffer at encode; move to `pendingRetirements` only after commit — waiting on an uncommitted buffer never returns.
    private var armedRetirement: PendingFrameRetirement?
    private var isInvalidated = false

    private let conversionQueue: MTLCommandQueue
    private var conversionPipeline: MTLRenderPipelineState?
    private var conversionSetupFailed = false
    private var workingTarget: MTLTexture?
    private var workingSampleView: MTLTexture?
    /// HDR fallback engaged — outputs are pinned to 32BGRA for the source's lifetime.
    private var forcedBGRAOutput = false
    private var loggedUnsupportedFormat = false
    private var loggedSRGBWrapFailure = false
    private var loggedSampleViewFailure = false

    enum PublishPath {
        case biPlanar
        case bgra
    }

    #if DEBUG
    private(set) var lastPublishPathForTesting: PublishPath?
    /// Counts working-texture clears: an unwritten `.private` texture's contents are not decidable, so tests pin that the clear happens.
    private(set) var workingTextureClearsForTesting = 0
    var didForceBGRAOutputForTesting: Bool { forcedBGRAOutput }
    private(set) var publishedFrameCountForTesting = 0
    /// Fault injection for the two sRGB-decode sites and the allocation clear.
    var forceSRGBWrapFailureForTesting = false
    var forceSampleViewFailureForTesting = false
    var forceWorkingTextureClearFailureForTesting = false
    private(set) var srgbWrapFailuresForTesting = 0
    private(set) var sampleViewFailuresForTesting = 0
    #endif

    private struct StagedFrame {
        let frame: PublishedFrame
        /// Nil on the BGRA path: that wrap is sampleable as-is, only the
        /// publish/retire transaction waits for the scene command buffer.
        let conversion: PendingConversion?
    }

    private struct PendingConversion {
        let pipeline: MTLRenderPipelineState
        let target: MTLTexture
        let luma: MTLTexture
        let chroma: MTLTexture
        let uniforms: WPEVideoYCbCrConversion
    }

    private struct PublishedFrame {
        let texture: MTLTexture
        /// Wrappers move to `pendingRetirements` at replacement, fenced by the scene buffer; the completed handler releases nothing (see `WPEFrameFenceFlag`).
        let retainedSourceTextures: [CVMetalTexture]
    }

    private var pendingRetirements: [PendingFrameRetirement] = []

    var pendingRetirementCountForTesting: Int { pendingRetirements.count }

    #if DEBUG
    /// Total fences ever registered: `pendingRetirements` is empty both after drain and when never fenced.
    private(set) var retirementFencesCreatedForTesting = 0
    #endif

    private let forceLegacyItemLevelOutput: Bool
    /// Decoder output size after the display cap. Nil = source dimensions.
    private let outputPixelSize: CGSize?
    private let admission: WPEVideoDecoderAdmission?
    private let decoderTicket: WPEVideoDecoderAdmission.Ticket?

    var isLiveDecoder: Bool { player != nil }

    #if DEBUG
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
            // No forward-buffer hint: it is inert on this path.
            playerItem.canUseNetworkResourcesForLiveStreamingWhilePaused = false
            if let outputPixelSize {
                playerItem.preferredMaximumResolution = outputPixelSize
            }

            let queuePlayer = AVQueuePlayer()
            // Do not set actionAtItemEnd = .none: the looper advances the queue and that pin would stall at the last frame. Prefetch the next looped item before wrap.
            queuePlayer.automaticallyWaitsToMinimizeStalling = true
            queuePlayer.preventsDisplaySleepDuringVideoPlayback = false
            // Frames are consumed as a Metal texture and never presented by a
            // player layer, so an AirPlay route would be meaningless — and it is
            // picked from the player regardless of what it outputs.
            queuePlayer.allowsExternalPlayback = false
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

            if playerLevelOutput == nil {
                ensureItemOutputs()
            }
        }

        if mustStayStill,
           let stillBuffer = Self.makeStillPixelBuffer(fileURL: videoURL, outputSize: outputPixelSize) {
            publish(pixelBuffer: stillBuffer)
        }
    }

    /// A staged frame wins over published — handed out before its conversion runs; `ensureWorkingTexture` clears new backing at allocation.
    private var currentTexture: MTLTexture? { staged?.frame.texture ?? latest?.texture }

    func texture(at time: TimeInterval) -> MTLTexture? {
        _ = time   // Wall-clock pacing comes from AVPlayer, not the scene clock.
        guard !isInvalidated else { return nil }
        guard player != nil else { return currentTexture }

        // Script play-once: freeze on natural loop wrap (don't mutate looper queue — races frame tap).
        if scriptControlled {
            if scriptHeldAtEnd { return currentTexture }
            let playhead = playheadSeconds
            if playhead + 0.1 < scriptLastPlaybackSeconds {
                player?.pause()
                scriptHeldAtEnd = true
                return currentTexture   // hold the pre-wrap (≈ last) frame
            }
            scriptLastPlaybackSeconds = playhead
        }

        if #available(macOS 15.0, *), let playerOutput = playerLevelOutput as? WPEPlayerLevelVideoOutput {
            if let frame = playerOutput.currentFrame(),
               lastPlayerLevelPresentationTime.map({ CMTimeCompare($0, frame.presentationTime) != 0 }) ?? true {
                publish(pixelBuffer: frame.pixelBuffer)
                lastPlayerLevelPresentationTime = frame.presentationTime
            }
            return currentTexture
        }

        ensureItemOutputs()
        guard let videoOutput = currentItemOutput else { return currentTexture }

        let host = CACurrentMediaTime()
        let itemTime = videoOutput.itemTime(forHostTime: host)
        guard itemTime.isValid else { return currentTexture }

        if videoOutput.hasNewPixelBuffer(forItemTime: itemTime),
           let pixelBuffer = videoOutput.copyPixelBuffer(
               forItemTime: itemTime,
               itemTimeForDisplay: nil
           ) {
            publish(pixelBuffer: pixelBuffer)
        }
        return currentTexture
    }

    func applyPerformanceProfile(_ profile: WallpaperPerformanceProfile) {
        guard !isInvalidated else { return }
        switch profile {
        case .quality:
            // Script-owned source: don't force-play on policy resume.
            if !scriptControlled { player?.play() }
        case .suspended:
            player?.pause()
            // A paused source never publishes again, so drain here or the last replaced frame's planes stay resident.
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

    /// Dropping the last Swift reference does not stop a playing `AVQueuePlayer`; `invalidate()` is the teardown backstop.
    deinit {
        invalidate()
    }

    func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        // Drain in-flight GPU work before releasing any CV wrapper; BGRA is sampled directly so fence the still-published frame now.
        if let current = latest, let marker = conversionQueue.makeCommandBuffer() {
            WPEFrameOccupancyMeter.count(.videoMarkerCommandBuffer)
            retire(current, fence: marker)
            marker.commit()
        }
        drainRetiredFrames()
        // A staged frame needs no fence: `commitStagedFrameWork` clears `staged`
        // in the same synchronous step that commits its buffer, so anything
        // still staged here was never handed to committed GPU work. Same for an
        // armed retirement — its buffer never reached `pendingRetirements`.
        armedRetirement = nil
        staged = nil
        // Drop the published frame BEFORE the player goes away: releasing CV wrappers after the pool is torn down is EXC_BAD_ACCESS.
        latest = nil
        CVMetalTextureCacheFlush(textureCache, 0)
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
        let conversion = WPEVideoYCbCrConversion.make(
            kind: WPEVideoYCbCrConversion.kind(matrixAttachment: matrixAttachment, sourceHeight: lumaHeight),
            fullRange: fullRange
        )

        #if DEBUG
        lastPublishPathForTesting = .biPlanar
        #endif
        stage(
            PublishedFrame(texture: working.sampleView, retainedSourceTextures: [lumaCV, chromaCV]),
            conversion: PendingConversion(
                pipeline: pipeline,
                target: working.target,
                luma: lumaTexture,
                chroma: chromaTexture,
                uniforms: conversion
            )
        )
    }

    private func publishBGRA(pixelBuffer: CVPixelBuffer) {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        #if DEBUG
        let forceWrapFailure = forceSRGBWrapFailureForTesting
        #else
        let forceWrapFailure = false
        #endif
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
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
        guard !forceWrapFailure,
              status == kCVReturnSuccess,
              let cvTexture,
              let texture = CVMetalTextureGetTexture(cvTexture) else {
            // No plain-unorm retry: the renderer would sample its gamma bytes as linear. The last frame stays published.
            #if DEBUG
            srgbWrapFailuresForTesting += 1
            #endif
            if !loggedSRGBWrapFailure {
                loggedSRGBWrapFailure = true
                Logger.warning(
                    "[WPE.video] sRGB BGRA wrap failed (CVReturn \(status)) — keeping the last frame",
                    category: .wpeRender
                )
            }
            return
        }
        #if DEBUG
        lastPublishPathForTesting = .bgra
        #endif
        // Nothing to convert, but the publish still goes through staging: the
        // scene command buffer is what fences the frame this one replaces.
        stage(PublishedFrame(texture: texture, retainedSourceTextures: [cvTexture]), conversion: nil)
    }

    /// Hand a decoded frame to the renderer without publishing it. Replacing an already-staged
    /// frame drops its wrappers immediately — safe because a staged frame is only ever
    /// referenced by a command buffer that was NOT committed (commit clears `staged`
    /// synchronously), so no GPU work can still be reading it.
    private func stage(_ frame: PublishedFrame, conversion: PendingConversion?) {
        staged = StagedFrame(frame: frame, conversion: conversion)
        // The cache holds a mapping per pixel buffer it has wrapped; the pool
        // rotates buffers, so without a periodic flush the mappings accumulate
        // for the source's lifetime. Flushing only drops unreferenced mappings —
        // the frame just staged retains its wrappers, so the in-use ones survive.
        CVMetalTextureCacheFlush(textureCache, 0)
    }

    // MARK: - Renderer frame contract

    var hasStagedFrameWork: Bool { staged != nil }

    /// Encode into the scene command buffer before any scene pass so same-buffer ordering puts the write ahead of every read.
    func encodeStagedFrameWork(into commandBuffer: MTLCommandBuffer) {
        guard !isInvalidated, let staged else { return }
        if let conversion = staged.conversion {
            let passDescriptor = MTLRenderPassDescriptor()
            passDescriptor.colorAttachments[0].texture = conversion.target
            passDescriptor.colorAttachments[0].loadAction = .dontCare
            passDescriptor.colorAttachments[0].storeAction = .store
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else {
                // Nothing encoded and nothing armed, so `commitStagedFrameWork`
                // will not publish: the frame stays staged for the next buffer
                // and the working texture keeps the last converted frame — the
                // very texture object `latest` hands out.
                return
            }
            WPEFrameOccupancyMeter.count(.helperEncoder)
            var uniforms = conversion.uniforms
            encoder.setRenderPipelineState(conversion.pipeline)
            encoder.setFragmentTexture(conversion.luma, index: 0)
            encoder.setFragmentTexture(conversion.chroma, index: 1)
            encoder.setFragmentBytes(
                &uniforms, length: MemoryLayout<WPEVideoYCbCrConversion>.stride, index: 0
            )
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()
        }
        armRetirement(of: latest, fence: commandBuffer)
    }

    func commitStagedFrameWork() {
        guard let armed = armedRetirement, let staged else {
            armedRetirement = nil
            return
        }
        armedRetirement = nil
        #if DEBUG
        retirementFencesCreatedForTesting += 1
        #endif
        pendingRetirements.append(armed)
        latest = staged.frame
        self.staged = nil
    }

    /// Step 2b. Drop the armed retirement only — its wrappers are a copy of the
    /// ones `latest` still holds, and `latest` did not move. The staged frame
    /// stays staged so the next scene command buffer re-encodes it.
    func rollbackStagedFrameWork() {
        armedRetirement = nil
    }

    /// Arm the replaced frame's wrappers behind the scene command buffer. Also
    /// armed with `nil` (first publish) purely to track the fence, so
    /// `invalidate()` can wait out the pass reading the CURRENT frame's planes.
    private func armRetirement(of previous: PublishedFrame?, fence: MTLCommandBuffer) {
        let flag = WPEFrameFenceFlag()
        fence.addCompletedHandler { _ in flag.markCompleted() }
        armedRetirement = PendingFrameRetirement(
            fence: fence,
            flag: flag,
            wrappers: previous?.retainedSourceTextures ?? []
        )
    }

    /// Teardown-only twin of `armRetirement`: `invalidate()`'s marker buffer is
    /// committed on the spot, so the entry can go straight into
    /// `pendingRetirements`. Must run before `fence` is committed.
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

    private func sweepRetiredFrames() {
        guard !pendingRetirements.isEmpty else { return }
        pendingRetirements.removeAll { $0.flag.isCompleted }
    }

    private func drainRetiredFrames() {
        for retirement in pendingRetirements {
            retirement.fence.waitUntilCompleted()
        }
        pendingRetirements.removeAll()
    }

    /// PQ/HLG buffers must not go through the 8-bit matrix path; pin outputs to 32BGRA and let AVFoundation own HDR→SDR.
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
        // `.pixelFormatView` is required for the sRGB view below; omitting it happens to work on
        // this Mac but is undocumented tolerance, and a failed view refuses every NV12 frame.
        descriptor.usage = [.renderTarget, .shaderRead, .pixelFormatView]
        descriptor.storageMode = .private
        guard let target = device.makeTexture(descriptor: descriptor) else { return nil }
        target.label = "WPE video NV12 working texture"
        // The pass stores gamma R'G'B' bytes in a non-sRGB target; the renderer
        // samples through this sRGB view — byte-identical to the old
        // `.bgra8Unorm_srgb` CV wrap, with no double gamma conversion.
        #if DEBUG
        let forceViewFailure = forceSampleViewFailureForTesting
        #else
        let forceViewFailure = false
        #endif
        guard !forceViewFailure, let sampleView = target.makeTextureView(pixelFormat: .bgra8Unorm_srgb) else {
            // Handing out the raw target instead would sample its gamma bytes as linear. The last frame stays published.
            #if DEBUG
            sampleViewFailuresForTesting += 1
            #endif
            if !loggedSampleViewFailure {
                loggedSampleViewFailure = true
                Logger.warning(
                    "[WPE.video] sRGB view of the NV12 working texture failed — keeping the last frame",
                    category: .wpeRender
                )
            }
            return nil
        }
        // Clear once at allocation, not per frame: texture(at:) hands a staged target out before conversion, so an unwritten .private backing would sample as undefined if the encoder is nil.
        let clearPass = MTLRenderPassDescriptor()
        clearPass.colorAttachments[0].texture = target
        clearPass.colorAttachments[0].loadAction = .clear
        clearPass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        clearPass.colorAttachments[0].storeAction = .store
        #if DEBUG
        let forceClearFailure = forceWorkingTextureClearFailureForTesting
        #else
        let forceClearFailure = false
        #endif
        // An uncleared texture is never cached or handed out; the next frame allocates again.
        guard !forceClearFailure,
              let clearBuffer = conversionQueue.makeCommandBuffer(),
              let clearEncoder = clearBuffer.makeRenderCommandEncoder(descriptor: clearPass) else {
            return nil
        }
        clearEncoder.endEncoding()
        clearBuffer.commit()
        #if DEBUG
        workingTextureClearsForTesting += 1
        #endif
        workingTarget = target
        workingSampleView = sampleView
        return (target, sampleView)
    }

    func ingestForTesting(pixelBuffer: CVPixelBuffer, drivesFrame: Bool = true) {
        publish(pixelBuffer: pixelBuffer)
        if drivesFrame { driveStagedFrameWorkForTesting() }
    }

    @discardableResult
    func driveStagedFrameWorkForTesting() -> Bool {
        guard hasStagedFrameWork, let commandBuffer = conversionQueue.makeCommandBuffer() else {
            return false
        }
        encodeStagedFrameWork(into: commandBuffer)
        commandBuffer.commit()
        commitStagedFrameWork()
        return true
    }

    /// NV12 video-range then full-range, 32BGRA tail; width/height only when `outputSize` is set (never an upscale).
    static let negotiatedPixelFormats: [OSType] = [
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        kCVPixelFormatType_32BGRA
    ]

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

/// The completed handler must capture only this flag — never the source, cache, or wrappers (that crashed after invalidate tore the pool down).
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

private struct PendingFrameRetirement {
    let fence: MTLCommandBuffer
    let flag: WPEFrameFenceFlag
    let wrappers: [CVMetalTexture]
}

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

/// CPU YCbCr→RGB params laid out as float3x3 + float3 (64 bytes) for `setFragmentBytes`, matching the shader uniforms.
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

    func apply(_ ycbcr: SIMD3<Float>) -> SIMD3<Float> {
        simd_clamp(matrix * (ycbcr - offset), SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 1))
    }
}
#endif
