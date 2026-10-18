import CoreVideo
import Foundation
@preconcurrency import IOSurface
import os
import QuartzCore
#if !LITE_BUILD
import LiveWallpaperCore
import Metal
#endif

/// Keeps video and live scenes behind the same surface lifecycle used by WallpaperAgent.
final class WallpaperRenderer: @unchecked Sendable {
    var layer: CALayer {
        video.layer
    }

    private let video = VideoRenderer()
    private struct State {
        var generation: UInt64 = 0
        var rate: Double = 1
        var task: Task<Void, Never>?
        var presented = false
        var refreshLiveData = true
        var hideClockCalendar = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    #if !LITE_BUILD
    @MainActor private static var activeScenes = 0

    @MainActor
    private static func acquireSceneSlot() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(30))
        while activeScenes >= 4 {
            try Task.checkCancellation()
            guard clock.now < deadline else { throw CocoaError(.featureUnsupported) }
            try await clock.sleep(for: .milliseconds(100))
        }
        activeScenes += 1
    }
    #endif

    func enqueueStill(posterURL: URL?, size: CGSize) {
        video.enqueueStill(posterURL: posterURL, size: size)
    }

    func snapshot() -> IOSurface? {
        video.snapshot()
    }

    func start(url: URL, initialRate: Double = 1,
               refreshLiveData: Bool = true, hideClockCalendar: Bool = false,
               onFirstFrame: (@Sendable () -> Void)? = nil,
               onFailure: (@Sendable (String) -> Void)? = nil) {
        stop()
        if url.pathExtension != "scene" {
            video.start(url: url, initialRate: initialRate, onFirstFrame: onFirstFrame, onFailure: onFailure)
            return
        }
        #if !LITE_BUILD
        let generation = state.withLock { state -> UInt64 in
            state.rate = initialRate
            state.presented = false
            state.refreshLiveData = refreshLiveData
            state.hideClockCalendar = hideClockCalendar
            return state.generation
        }
        let task = Task { @MainActor [self] in
            var actor: WPEDisplayRenderActor?
            var ownsSlot = false
            defer {
                if ownsSlot {
                    Self.activeScenes -= 1
                }
            }
            let sceneLayer = CAMetalLayer()
            do {
                try Task.checkCancellation()
                try await Self.acquireSceneSlot()
                ownsSlot = true
                guard let device = MTLCreateSystemDefaultDevice() else { throw CocoaError(.featureUnsupported) }
                sceneLayer.device = device
                sceneLayer.pixelFormat = .bgra8Unorm_srgb
                sceneLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
                sceneLayer.frame = layer.bounds
                let source = try SystemWallpaperSceneSource.published(at: url)
                sceneLayer.drawableSize = source.renderSize(for: CGSize(width: layer.bounds.width * layer.contentsScale,
                                                                        height: layer.bounds.height * layer.contentsScale))
                var pool = try SystemWallpaperFramePool(size: sceneLayer.drawableSize, device: device)
                let clockObjectIDs = source.clockCalendarObjectIDs()
                let running = try await SystemWallpaperSceneRuntime.makeActor(source: source, layer: sceneLayer, size: sceneLayer.drawableSize,
                                                                              hidingClockCalendar: hideClockCalendar)
                var clocksHidden = hideClockCalendar
                actor = running
                let clock = ContinuousClock()
                let firstFrameDeadline = clock.now.advanced(by: .seconds(30))
                var wasPaused = false
                var pausedAt: ContinuousClock.Instant?
                var hibernated = false
                while !Task.isCancelled, state.withLock({ $0.generation }) == generation {
                    let (rate, didPresent, refreshLiveData, hideClocks) = state.withLock { ($0.rate, $0.presented, $0.refreshLiveData, $0.hideClockCalendar) }
                    if clocksHidden != hideClocks {
                        try await running.setSystemWallpaperState(
                            descriptor: source.descriptorForSystemWallpaper(hidingClockCalendar: hideClocks),
                            excludedObjectIDs: hideClocks ? clockObjectIDs : []
                        )
                        clocksHidden = hideClocks
                    }
                    if rate <= 0, didPresent {
                        if !wasPaused {
                            await running.applyPerformanceProfile(.suspended)
                            wasPaused = true
                            pausedAt = clock.now
                        }
                        if !refreshLiveData {
                            if !hibernated, let pausedAt, pausedAt.duration(to: clock.now) >= .seconds(30) {
                                hibernated = await running.hibernate()
                                if hibernated {
                                    Self.activeScenes -= 1; ownsSlot = false
                                }
                            }
                            try await clock.sleep(for: .seconds(1))
                            continue
                        }
                        if hibernated {
                            try await Self.acquireSceneSlot()
                            ownsSlot = true
                            try await running.reload()
                            await running.applyPerformanceProfile(.suspended)
                            hibernated = false
                        }
                    } else if wasPaused {
                        if hibernated {
                            try await Self.acquireSceneSlot()
                            ownsSlot = true
                            try await running.reload()
                            hibernated = false
                        }
                        await running.applyPerformanceProfile(.quality)
                        wasPaused = false
                        pausedAt = nil
                    }
                    let size = source.renderSize(for: CGSize(width: layer.bounds.width * layer.contentsScale,
                                                             height: layer.bounds.height * layer.contentsScale))
                    if sceneLayer.drawableSize != size {
                        sceneLayer.drawableSize = size
                        pool = try SystemWallpaperFramePool(size: size, device: device)
                        await running.updateSurfaceGeometry(drawableSize: size)
                    }
                    let fps = rate <= 0 ? 1 : rate < 1 ? min(source.preferredFramesPerSecond, 15) : source.preferredFramesPerSecond
                    await running.setFrameRateCeiling(fps)
                    let frame = try await pool.nextFrame()
                    try await running.renderMovieFrame(into: .init(texture: frame.texture))
                    try Task.checkCancellation()
                    // GPU writes have completed; only the cache wrapper's lifetime is retained afterwards.
                    nonisolated(unsafe) let completedBuffer = frame.buffer
                    video.enqueueRenderedFrame(CVReadOnlyPixelBuffer(unsafeBuffer: completedBuffer), first: !didPresent,
                                               isCurrent: { [state] in state.withLock { $0.generation == generation } },
                                               onFirstFrame: { [state] in
                                                   let first = state.withLock { value -> Bool in
                                                       guard value.generation == generation, !value.presented else { return false }
                                                       value.presented = true
                                                       return true
                                                   }
                                                   if first {
                                                       onFirstFrame?()
                                                   }
                                               })
                    withExtendedLifetime(frame.cachedTexture) {}
                    if !didPresent, clock.now >= firstFrameDeadline {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    try await clock.sleep(for: .seconds(1.0 / Double(fps)))
                }
            } catch {
                if !Task.isCancelled, state.withLock({ $0.generation }) == generation {
                    onFailure?("scene.load.failed")
                    wpxLog.error("live scene failed: \(WPXLogPrivacy.summary(error), privacy: .private)")
                }
            }
            if let actor {
                await actor.teardownRenderer()
                actor.requestStop()
            }
        }
        state.withLock { $0.task = task }
        #else
        onFailure?("scene.unsupported")
        #endif
    }

    func rampRate(to rate: Double, duration: TimeInterval = 2, refreshLiveData: Bool = true, hideClockCalendar: Bool = false) {
        state.withLock { $0.rate = rate; $0.refreshLiveData = refreshLiveData; $0.hideClockCalendar = hideClockCalendar }
        video.rampRate(to: rate, duration: duration)
    }

    func stop() {
        let task = state.withLock { state -> Task<Void, Never>? in
            state.generation &+= 1
            defer { state.task = nil }
            return state.task
        }
        task?.cancel()
        video.stop()
    }

    func stopSync() {
        stop(); video.stopSync()
    }
}
