@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import QuartzCore
import os.log

/// Feeds one surface's AVSampleBufferDisplayLayer from an AVAssetReader, with
/// a CMTimebase as the playback clock so rate changes (and the ease-to-still
/// ramp) come for free (contract §5, §8).
///
/// `@unchecked Sendable` is carried by `queue`: every stored property below is
/// read and written only from it, and the public entry points hop onto it
/// rather than mutating from the caller's thread. The one object touched from
/// two queues is `displayLayer` — CALayer mutation is done inside a
/// CATransaction, and AVFoundation documents `sampleBufferRenderer` as safe to
/// enqueue from a background thread (AVSampleBufferDisplayLayer.h:245).
final class VideoRenderer: @unchecked Sendable {
    private let displayLayer: AVSampleBufferDisplayLayer
    /// Taken once on the main actor and used from `queue` thereafter: the
    /// layer type is NS_SWIFT_UI_ACTOR, but the renderer it vends is not, and
    /// AVFoundation documents it as safe to enqueue into from a background
    /// thread (AVSampleBufferDisplayLayer.h:245).
    private let renderer: AVSampleBufferVideoRenderer
    private let queue = DispatchQueue(label: "com.loomscreen.wallpaper.render")
    private var timebase: CMTimebase?
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var asset: AVURLAsset?
    private var ptsOffset: CMTime = .zero
    private var maxSampleEnd: CMTime = .zero
    private var firstFrameHandler: (@Sendable () -> Void)?
    private var didSignalFirstFrame = false
    private var currentRate: Double = 0
    /// What the policy last asked for. The first frame must land on this, not
    /// on a hardcoded 1: an update can arrive before the first frame (lock
    /// screen easing in with "still on desktop"), and forcing 1 there plays a
    /// wallpaper the policy just stopped.
    private var desiredRate: Double = 1
    private var rampTimer: DispatchSourceTimer?
    private var deepPauseTimer: (any DispatchSourceTimer)?
    /// Kept so a deep-paused renderer can rebuild its pipeline on resume.
    private var sourceURL: URL?
    private var isDeepPaused = false
    /// In-asset position captured when the pipeline was dropped. The timebase
    /// runs on the shifted (looped) timeline, so this is `time - ptsOffset` —
    /// resuming must not feed the absolute clock back in as a file position.
    private var deepPauseResumePosition: CMTime = .zero
    private var decoderLossObserver: (any NSObjectProtocol)?

    var layer: CALayer { displayLayer }

    init() {
        let prepared = Self.makeLayer()
        displayLayer = prepared.layer
        renderer = prepared.renderer
        timebase = prepared.timebase
        // The system reclaims video decoder resources from background processes
        // — "the value of this property changes to YES along with the video
        // renderer's status changing to AVQueuedSampleBufferRenderingStatusFailed
        // … clients must first reset the video renderer by calling flush"
        // (AVSampleBufferVideoRenderer.h:86-87). Nothing else clears it, so
        // without this the wallpaper stays on its last frame for the rest of
        // the process's life while still reporting itself healthy.
        decoderLossObserver = NotificationCenter.default.addObserver(
            forName: AVSampleBufferVideoRenderer.requiresFlushToResumeDecodingDidChangeNotification,
            object: renderer,
            queue: nil
        ) { [weak self] _ in self?.handleDecoderLoss() }
    }

    deinit {
        if let decoderLossObserver {
            NotificationCenter.default.removeObserver(decoderLossObserver)
        }
    }

    private func handleDecoderLoss() {
        queue.async { [weak self] in
            guard let self, renderer.requiresFlushToResumeDecoding else { return }
            renderer.flush()
            // A flush resets decoder state, so the next buffer has to be a sync
            // sample (AVSampleBufferVideoRenderer.h:140). Reopening the reader
            // at the clock's in-asset position gives one: AVAssetReader backs a
            // non-zero `timeRange.start` up to the preceding sync sample
            // (measured 2026-08-29). A deep-paused renderer has no pipeline to
            // rebuild — its resume already opens a fresh reader.
            guard !isDeepPaused, let sourceURL else { return }
            renderer.stopRequestingMediaData()
            reader?.cancelReading()
            reader = nil
            output = nil
            let inAsset = CMTimeSubtract(timebase.map { CMTimebaseGetTime($0) } ?? .zero, ptsOffset)
            openReader(url: sourceURL, from: CMTimeCompare(inAsset, .zero) > 0 ? inAsset : .zero)
            wpxLog.info("decoder reclaimed — flushed and rebuilt the pipeline")
        }
    }

    /// The three objects leave the main actor exactly once, into the single
    /// instance that owns them; nothing on main keeps a reference afterwards.
    private struct Prepared: @unchecked Sendable {
        let layer: AVSampleBufferDisplayLayer
        let renderer: AVSampleBufferVideoRenderer
        let timebase: CMTimebase?
    }

    /// All layer setup happens here, on the main actor, because
    /// AVSampleBufferDisplayLayer is declared NS_SWIFT_UI_ACTOR. Everything
    /// after this point goes through `renderer`, which is not isolated.
    private static func makeLayer() -> Prepared {
        let work: @MainActor () -> Prepared = {
            let layer = AVSampleBufferDisplayLayer()
            layer.videoGravity = .resizeAspectFill
            layer.isOpaque = true
            // Apple's own wallpaper layers set this; without it the layer paints
            // opaque black before its first frame composites (contract §5).
            let sel = NSSelectorFromString("_setDisallowsVideoLayerDisplayCompositing:")
            if layer.responds(to: sel) {
                layer.perform(sel, with: NSNumber(value: true))
            }
            var tb: CMTimebase?
            CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault,
                                            sourceClock: CMClockGetHostTimeClock(),
                                            timebaseOut: &tb)
            if let tb {
                CMTimebaseSetRate(tb, rate: 0)
                CMTimebaseSetTime(tb, time: .zero)
                layer.controlTimebase = tb
            }
            return Prepared(layer: layer, renderer: layer.sampleBufferRenderer, timebase: tb)
        }
        // Surfaces are created on the lifecycle queue, which never blocks the
        // main thread, so this hop cannot deadlock.
        if Thread.isMainThread {
            return MainActor.assumeIsolated(work)
        }
        return DispatchQueue.main.sync { MainActor.assumeIsolated(work) }
    }

    /// Show a still immediately. Must be an IOSurface-backed sample buffer —
    /// a CALayer.contents CGImage does not composite in a remote context
    /// (contract §5, RE-confirmed upstream).
    /// Synchronous on purpose: acquire must not reply until this still is on
    /// screen (contract §3.1). The render queue never calls back into the
    /// lifecycle queue synchronously, so this cannot deadlock.
    /// Seeds the layer and — this is the part that matters — waits until the
    /// layer reports it has something to show. `enqueue` is asynchronous, so
    /// replying to acquire right after it hands the Agent a context whose
    /// surface has never been written: an all-zero YUV surface composites as
    /// flat green, which is the flash seen when switching to our wallpaper.
    /// `posterURL` nil (or undecodable) falls back to black — a seeded black
    /// frame is still infinitely better than an unwritten surface.
    func enqueueStill(posterURL: URL?, size: CGSize) {
        queue.sync {
            let buffer = posterURL.flatMap { StillFrameFactory.makeSampleBuffer(imageURL: $0, size: size) }
                ?? StillFrameFactory.makeSampleBuffer(color: CGColor(gray: 0, alpha: 1), size: size)
            guard let buffer else { return }
            renderer.enqueue(buffer)
        }
        waitForFirstDisplay()
    }

    /// Bounded wait — a wallpaper switch must not hang on a layer that never
    /// reports ready, and one dropped frame beats a stalled Settings panel.
    private func waitForFirstDisplay(timeout: TimeInterval = 0.5) {
        let start = Date()
        let deadline = start.addingTimeInterval(timeout)
        while Date() < deadline {
            if isLayerReadyForDisplay() {
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                wpxLog.info("seed still on screen after \(ms, privacy: .public)ms")
                return
            }
            usleep(4000)
        }
        wpxLog.info("still frame did not report ready within \(timeout, privacy: .public)s")
    }

    private func isLayerReadyForDisplay() -> Bool {
        let layer = displayLayer
        let read: @MainActor () -> Bool = { layer.isReadyForDisplay }
        if Thread.isMainThread {
            return MainActor.assumeIsolated(read)
        }
        return DispatchQueue.main.sync { MainActor.assumeIsolated(read) }
    }

    func start(url: URL, onFirstFrame: (@Sendable () -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            // Switching videos reuses this renderer (a fresh layer would not
            // composite in an already-hosted context, contract §5), so the
            // previous pump has to be torn down first: requesting media data
            // twice without stopping is an AVFoundation contract violation and
            // would leave two readers feeding one layer.
            renderer.stopRequestingMediaData()
            reader?.cancelReading()
            reader = nil
            output = nil
            cancelDeepPauseTimer()
            // A still-running ease from the previous video must not keep
            // steering the new video's clock.
            cancelRamp()
            // On a switch the timebase has been running for as long as the old
            // video played; the new video's samples start at PTS 0 and would
            // all be judged hours late, so drop the queued tail (the displayed
            // frame stays) and wind the clock back before the new pump starts.
            // The first start after the poster seed must NOT flush — the seed
            // may not have displayed yet and flushing would un-seed the surface.
            if sourceURL != nil {
                renderer.flush()
                if let timebase {
                    CMTimebaseSetRate(timebase, rate: 0)
                    CMTimebaseSetTime(timebase, time: .zero)
                }
                currentRate = 0
            }
            ptsOffset = .zero
            maxSampleEnd = .zero
            firstFrameHandler = onFirstFrame
            didSignalFirstFrame = false
            sourceURL = url
            isDeepPaused = false
            openReader(url: url)
        }
    }

    private func openReader(url: URL, from startTime: CMTime = .zero) {
        let asset = AVURLAsset(url: url)
        self.asset = asset
        guard let track = loadFirstVideoTrack(asset) else {
            wpxLog.error("no video track in \(url.lastPathComponent, privacy: .private)")
            return
        }
        do {
            let reader = try AVAssetReader(asset: asset)
            if startTime > .zero {
                // Resuming a deep-paused wallpaper: read on from where the
                // still froze, not from the top of the file. timeRange only
                // filters — samples keep their file PTS — so `ptsOffset` must
                // stay whatever the loop seam accumulated: adding the start
                // again would double-shift every sample past the clock.
                reader.timeRange = CMTimeRange(start: startTime, duration: .positiveInfinity)
            }
            // nil outputSettings passes compressed samples straight through.
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { return }
            reader.add(output)
            guard reader.startReading() else {
                wpxLog.error("reader failed: \(WPXLogPrivacy.summary(reader.error), privacy: .public)")
                return
            }
            self.reader = reader
            self.output = output
            requestMedia()
        } catch {
            wpxLog.error("reader init failed: \(WPXLogPrivacy.summary(error), privacy: .public)")
        }
    }

    /// Blocks the render queue until the track metadata is in. Called only at
    /// open time, on a local file, before any frame is due — and the semaphore
    /// is what publishes the callback's write to this thread.
    private func loadFirstVideoTrack(_ asset: AVURLAsset) -> AVAssetTrack? {
        final class Box: @unchecked Sendable { var track: AVAssetTrack? }
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)
        asset.loadTracks(withMediaType: .video) { tracks, _ in
            box.track = tracks?.first
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 5) == .success else {
            wpxLog.error("track load timed out")
            return nil
        }
        return box.track
    }

    private func requestMedia() {
        renderer.requestMediaDataWhenReady(on: queue) { [weak self] in
            guard let self else { return }
            while self.renderer.isReadyForMoreMediaData {
                guard let output = self.output,
                      let sample = output.copyNextSampleBuffer() else {
                    self.loopIfFinished()
                    return
                }
                if let shifted = self.shift(sample) {
                    self.renderer.enqueue(shifted)
                }
                self.signalFirstFrameIfNeeded()
            }
        }
    }

    /// Loop seam: offset every sample past the previous run's end so DTS/PTS
    /// stay monotonic (B-frames make the last PTS unreliable, so track the max
    /// sample end rather than the last one).
    private func shift(_ sample: CMSampleBuffer) -> CMSampleBuffer? {
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let duration = CMSampleBufferGetDuration(sample)
        // Zero-sample buffers are edit-list markers, not frames. A file with a
        // trailing empty edit ends with one carrying the asset's full duration
        // (measured 2026-08-29), and letting it set `maxSampleEnd` parks the
        // next loop that far past the last real frame — a freeze on every seam.
        if pts.isValid, CMSampleBufferGetNumSamples(sample) > 0 {
            let end = duration.isValid ? CMTimeAdd(pts, duration) : pts
            let shiftedEnd = CMTimeAdd(end, ptsOffset)
            if CMTimeCompare(shiftedEnd, maxSampleEnd) > 0 { maxSampleEnd = shiftedEnd }
        }
        guard ptsOffset != .zero else { return sample }
        var timing = CMSampleTimingInfo()
        guard CMSampleBufferGetSampleTimingInfo(sample, at: 0, timingInfoOut: &timing) == noErr else {
            return sample
        }
        if timing.presentationTimeStamp.isValid {
            timing.presentationTimeStamp = CMTimeAdd(timing.presentationTimeStamp, ptsOffset)
        }
        if timing.decodeTimeStamp.isValid {
            timing.decodeTimeStamp = CMTimeAdd(timing.decodeTimeStamp, ptsOffset)
        }
        var copy: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault,
                                              sampleBuffer: sample,
                                              sampleTimingEntryCount: 1,
                                              sampleTimingArray: &timing,
                                              sampleBufferOut: &copy)
        return copy ?? sample
    }

    private func loopIfFinished() {
        guard let reader, reader.status == .completed, let url = asset?.url else { return }
        ptsOffset = maxSampleEnd
        self.reader = nil
        self.output = nil
        openReader(url: url)
    }

    private func signalFirstFrameIfNeeded() {
        guard !didSignalFirstFrame else { return }
        didSignalFirstFrame = true
        CATransaction.flush()
        if currentRate == 0 {
            if desiredRate > 0, let timebase {
                CMTimebaseSetRate(timebase, rate: desiredRate)
                currentRate = desiredRate
            } else {
                // The policy asked for a still before the first frame arrived
                // (ease-to-still, idle): stay parked, but arm the decoder
                // release — nothing else will, since no rate change follows.
                scheduleDeepPause()
            }
        }
        let handler = firstFrameHandler
        firstFrameHandler = nil
        handler?()
    }

    // MARK: - Deep pause

    /// A paused renderer still owns an AVAssetReader and a hardware video
    /// decoder. With "ease to a still" that is the whole session, so drop the
    /// pipeline once the wallpaper has been motionless for a while — the last
    /// frame stays on screen because the layer keeps it.
    private static let deepPauseDelay: TimeInterval = 30

    private func scheduleDeepPause() {
        cancelDeepPauseTimer()
        guard !isDeepPaused, reader != nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.deepPauseDelay)
        timer.setEventHandler { [weak self] in self?.enterDeepPause() }
        deepPauseTimer = timer
        timer.resume()
    }

    private func cancelDeepPauseTimer() {
        deepPauseTimer?.cancel()
        deepPauseTimer = nil
    }

    private func enterDeepPause() {
        cancelDeepPauseTimer()
        guard !isDeepPaused, let reader else { return }
        renderer.stopRequestingMediaData()
        reader.cancelReading()
        self.reader = nil
        output = nil
        // The clock has been parked for `deepPauseDelay`, so the renderer holds
        // a full queue of frames ahead of it — the same frames the rebuilt
        // reader re-reads on resume, at the same timestamps. Dropping them also
        // releases the decoded frames deep pause exists to release; a plain
        // flush keeps the displayed image (AVSampleBufferVideoRenderer.h:134).
        renderer.flush()
        isDeepPaused = true
        // The timebase runs on the looped timeline (ptsOffset per completed
        // loop); the reader needs the position inside the file.
        let now = timebase.map { CMTimebaseGetTime($0) } ?? .zero
        let inAsset = CMTimeSubtract(now, ptsOffset)
        deepPauseResumePosition = CMTimeCompare(inAsset, .zero) > 0 ? inAsset : .zero
        wpxLog.info("deep pause — decoder released")
    }

    /// Rebuilds the pipeline from where the still froze, so resuming continues
    /// there instead of snapping back to the start.
    private func resumeFromDeepPause() {
        guard isDeepPaused, let sourceURL else { return }
        isDeepPaused = false
        didSignalFirstFrame = true
        openReader(url: sourceURL, from: deepPauseResumePosition)
        wpxLog.info("deep pause ended — pipeline rebuilt")
    }

    /// Ease the rate over `duration` — this is what reads as the wallpaper
    /// "settling into a still" rather than cutting to a frozen frame.
    func rampRate(to target: Double, duration: TimeInterval = 2.0) {
        queue.async { [weak self] in self?.rampRateOnQueue(to: target, duration: duration) }
    }

    private func rampRateOnQueue(to target: Double, duration: TimeInterval) {
        guard let timebase else { return }
        cancelRamp()
        desiredRate = target
        // A deep-paused renderer has no reader — ramping only the timebase
        // would "resume" into a permanent freeze-frame (every policy update
        // funnels through here, so this is the main wake-up path).
        if target > 0, isDeepPaused { resumeFromDeepPause() }
        let start = currentRate
        guard abs(target - start) > 0.001 else { return }
        // A dead-stop 0 start never advances; nudge it so easing has an effect.
        if start == 0, target > 0 {
            CMTimebaseSetRate(timebase, rate: 0.01)
            currentRate = 0.01
        }
        let steps = max(1, Int(duration * 120))
        var step = 0
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: duration / Double(steps))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            step += 1
            let t = min(1.0, Double(step) / Double(steps))
            let eased = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
            let rate = start + (target - start) * eased
            CMTimebaseSetRate(timebase, rate: rate)
            self.currentRate = rate
            if t >= 1.0 {
                self.cancelRamp()
                // Landing on a still is what arms the decoder release.
                if rate == 0 { self.scheduleDeepPause() }
            }
        }
        rampTimer = timer
        timer.resume()
    }

    private func cancelRamp() {
        rampTimer?.cancel()
        rampTimer = nil
    }

    func stop() {
        queue.async { [weak self] in self?.stopOnQueue() }
    }

    /// Teardown wants the pump provably quiet before the remote context goes
    /// away, so this one blocks. Lifecycle → render queue sync is safe: the
    /// render queue never calls back into the lifecycle queue synchronously
    /// (same argument as `enqueueStill`).
    func stopSync() {
        queue.sync { self.stopOnQueue() }
    }

    private func stopOnQueue() {
        cancelRamp()
        cancelDeepPauseTimer()
        renderer.stopRequestingMediaData()
        reader?.cancelReading()
        reader = nil
        output = nil
    }
}
