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
final class WallpaperRenderer: @unchecked Sendable { // `state` behind its OSAllocatedUnfairLock, `video` on its own render queue, scene lifecycle behind its own lock
    var layer: CALayer {
        video.layer
    }

    private let video = VideoRenderer()
    private struct State {
        var generation: UInt64 = 0
        var rate: Double = 1
        var scene: WallpaperSceneLifecycle?
        var presented = false
        var refreshLiveData = true
        var hideClockCalendar = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func enqueueStill(posterURL: URL?, size: CGSize) {
        video.enqueueStill(posterURL: posterURL, size: size)
    }

    func snapshot() -> IOSurface? {
        video.snapshot()
    }

    func start(url: URL, initialRate: Double = 1,
               refreshLiveData: Bool = true, hideClockCalendar: Bool = false,
               onFirstFrame: (@Sendable () -> Void)? = nil,
               onFailure: (@Sendable (String) -> Void)? = nil,
               onHealthChange: @escaping @Sendable () -> Void = {}) {
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
        let lifecycle = WallpaperSceneLifecycle(running: initialRate > 0, onHealthChange: onHealthChange,
                                                onFailure: { [weak self] code in
                                                    guard let self, state.withLock({ $0.generation }) == generation else { return }
                                                    onFailure?(code)
                                                })
        state.withLock { $0.scene = lifecycle }
        let task = Task { @MainActor [self] in
            let sceneLayer = CAMetalLayer()
            do {
                try Task.checkCancellation()
                let fingerprint = try await CancellableBackgroundWork.run {
                    try WallpaperSceneCapsule.fingerprint(at: url)
                }
                guard lifecycle.setCapsule(fingerprint) else { return }
                try await lifecycle.acquireSlot()
                try Task.checkCancellation()
                guard let device = MTLCreateSystemDefaultDevice() else { throw CocoaError(.featureUnsupported) }
                sceneLayer.device = device
                sceneLayer.pixelFormat = .bgra8Unorm_srgb
                sceneLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
                sceneLayer.frame = layer.bounds
                let (source, clockObjectIDs) = try await CancellableBackgroundWork.run {
                    let source = try SystemWallpaperSceneSource.published(at: url)
                    return (source, source.clockCalendarObjectIDs())
                }
                sceneLayer.drawableSize = source.renderSize(for: CGSize(width: layer.bounds.width * layer.contentsScale,
                                                                        height: layer.bounds.height * layer.contentsScale))
                var pool = try SystemWallpaperFramePool(size: sceneLayer.drawableSize, device: device)
                let running = try await SystemWallpaperSceneRuntime.makeActor(source: source, layer: sceneLayer, size: sceneLayer.drawableSize,
                                                                              hidingClockCalendar: hideClockCalendar,
                                                                              actorCreated: { actor in
                                                                                  lifecycle.installShutdown { await actor.shutdownSystemWallpaperRenderer() }
                                                                              })
                var clocksHidden = hideClockCalendar
                let clock = ContinuousClock()
                var wasPaused = false
                var pausedAt: ContinuousClock.Instant?
                var hibernated = false
                while !Task.isCancelled, lifecycle.isActive, state.withLock({ $0.generation }) == generation {
                    let (rate, didPresent, refreshLiveData, hideClocks) = state.withLock { ($0.rate, $0.presented, $0.refreshLiveData, $0.hideClockCalendar) }
                    if clocksHidden != hideClocks {
                        let descriptor = try await CancellableBackgroundWork.run {
                            source.descriptorForSystemWallpaper(hidingClockCalendar: hideClocks)
                        }
                        try await running.setSystemWallpaperState(
                            descriptor: descriptor,
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
                                    lifecycle.releaseSlot()
                                }
                            }
                            try await clock.sleep(for: .seconds(1))
                            continue
                        }
                        if hibernated {
                            try await lifecycle.acquireSlot()
                            try await running.reload()
                            await running.applyPerformanceProfile(.suspended)
                            hibernated = false
                        }
                    } else if wasPaused {
                        if hibernated {
                            try await lifecycle.acquireSlot()
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
                                               isCurrent: { [state] in lifecycle.isActive && state.withLock { $0.generation == generation } },
                                               onFirstFrame: { [state] in
                                                   let first = state.withLock { value -> Bool in
                                                       guard value.generation == generation, !value.presented else { return false }
                                                       value.presented = true
                                                       return true
                                                   }
                                                   if first {
                                                       onFirstFrame?()
                                                   }
                                               },
                                               onFrame: { lifecycle.framePresented() })
                    withExtendedLifetime(frame.cachedTexture) {}
                    try await clock.sleep(for: .seconds(1.0 / Double(fps)))
                }
            } catch is WallpaperSceneAdmission.CircuitOpen {
                lifecycle.finish(failure: "scene.circuit.open")
            } catch is WallpaperSceneAdmission.Unavailable {
                lifecycle.finish(failure: "scene.admission.closed")
            } catch {
                if !Task.isCancelled, state.withLock({ $0.generation }) == generation {
                    lifecycle.finish(failure: "scene.load.failed")
                    wpxLog.error("live scene failed: \(WPXLogPrivacy.summary(error), privacy: .private)")
                }
            }
            lifecycle.finish()
        }
        lifecycle.install(task: task)
        #else
        onFailure?("scene.unsupported")
        #endif
    }

    func rampRate(to rate: Double, duration: TimeInterval = 2, refreshLiveData: Bool = true, hideClockCalendar: Bool = false) {
        let scene = state.withLock { value in
            value.rate = rate
            value.refreshLiveData = refreshLiveData
            value.hideClockCalendar = hideClockCalendar
            return value.scene
        }
        scene?.setRunning(rate > 0)
        video.rampRate(to: rate, duration: duration)
    }

    func stop() {
        let scene = state.withLock { state -> WallpaperSceneLifecycle? in
            state.generation &+= 1
            defer { state.scene = nil }
            return state.scene
        }
        scene?.finish()
        video.stop()
    }

    func stopSync() {
        stop(); video.stopSync()
    }
}
