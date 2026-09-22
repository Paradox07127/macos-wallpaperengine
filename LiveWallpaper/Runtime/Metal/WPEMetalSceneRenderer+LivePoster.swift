#if !LITE_BUILD
import AppKit
import LiveWallpaperCore
import MetalKit

extension WPEMetalSceneRenderer {

    // MARK: - Capture batch

    final class LivePosterCaptureBatch: Sendable {
        let actor: WPEDisplayRenderActor
        let captures: [UUID: CheckedContinuation<NSImage?, Never>]
        let generation: Int
        let snapshotter: WPEMetalTextureSnapshotter

        init(
            actor: WPEDisplayRenderActor,
            captures: [UUID: CheckedContinuation<NSImage?, Never>],
            generation: Int,
            snapshotter: WPEMetalTextureSnapshotter
        ) {
            self.actor = actor
            self.captures = captures
            self.generation = generation
            self.snapshotter = snapshotter
        }

        func captureAfterPresent(
            from texture: MTLTexture,
            completed: Bool,
            releaseSource: @escaping @Sendable () -> Void
        ) {
            let source = WPEMetalTextureSnapshotter.SnapshotSource(texture: texture)
            let snapshotter = snapshotter
            if !completed {
                Logger.info("[live-poster] present command buffer not completed — poster skipped", category: .wpeRender)
            }
            Task { [self, snapshotter] in
                let image = completed ? await snapshotter.snapshotAsync(from: source) : nil
                releaseSource()
                let stillCurrent = await actor.isCurrentLoadGeneration(generation)
                finish(image: stillCurrent ? image : nil)
            }
        }

        func finish(image: NSImage?) {
            for continuation in captures.values {
                continuation.resume(returning: image)
            }
        }
    }
    // MARK: - Capture requests

    /// Reuses the next frame already going to present; do not force a fresh synchronous `renderCurrentFrame()` on the display render actor.
    func enqueueLivePosterCapture(id: UUID, continuation: CheckedContinuation<NSImage?, Never>) {
        displayActor?.preconditionIsolated()
        guard didLoad, hasPresentedFrame, renderPipeline != nil, currentProfile == .quality else {
            Logger.info(
                "[live-poster] skipped: didLoad=\(didLoad) presented=\(hasPresentedFrame) pipeline=\(renderPipeline != nil) profile=\(String(describing: currentProfile))",
                category: .wpeRender
            )
            continuation.resume(returning: nil)
            return
        }
        pendingLivePosterCaptures[id] = continuation
        requestLivePosterCaptureFrame()
    }

    private func requestLivePosterCaptureFrame() {
        if needsContinuousFrames {
            surfaceControl.setNeedsRedraw()
        } else if outputTexture != nil {
            surfaceControl.drawImmediately()
        } else {
            surfaceControl.setNeedsRedraw()
        }
    }

    // MARK: - Frame-time drain & completion

    func takePendingLivePosterCaptures() -> LivePosterCaptureBatch? {
        guard !pendingLivePosterCaptures.isEmpty, let actor = displayActor else { return nil }
        let captures = pendingLivePosterCaptures
        pendingLivePosterCaptures.removeAll(keepingCapacity: true)
        return LivePosterCaptureBatch(
            actor: actor,
            captures: captures,
            generation: loadGeneration,
            snapshotter: snapshotter
        )
    }

    nonisolated private static func capturePendingLivePostersAfterPresent(
        _ batch: LivePosterCaptureBatch,
        from texture: MTLTexture,
        commandBuffer: MTLCommandBuffer,
        releaseSource: @escaping @Sendable () -> Void
    ) {
        batch.captureAfterPresent(
            from: texture,
            completed: commandBuffer.status == .completed,
            releaseSource: releaseSource
        )
    }

    static func livePosterPresentCompletion(
        for batch: LivePosterCaptureBatch?
    ) -> (@Sendable (MTLTexture, MTLCommandBuffer, @escaping @Sendable () -> Void) -> Void)? {
        guard let batch else { return nil }
        return { source, commandBuffer, releaseSource in
            Self.capturePendingLivePostersAfterPresent(
                batch,
                from: source,
                commandBuffer: commandBuffer,
                releaseSource: releaseSource
            )
        }
    }

    func finishLivePosterCapture(id: UUID, image: NSImage?) {
        guard let continuation = pendingLivePosterCaptures.removeValue(forKey: id) else { return }
        continuation.resume(returning: image)
    }

    func finishAllPendingLivePosterCaptures(image: NSImage?) {
        guard !pendingLivePosterCaptures.isEmpty else { return }
        let captures = pendingLivePosterCaptures
        pendingLivePosterCaptures.removeAll(keepingCapacity: false)
        for continuation in captures.values {
            continuation.resume(returning: image)
        }
    }
}
#endif
