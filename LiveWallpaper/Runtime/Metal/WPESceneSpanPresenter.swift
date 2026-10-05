#if !LITE_BUILD
import CoreGraphics
import Foundation
import LiveWallpaperCore
import Metal

/// Cross-thread status only; command buffers and drawable acquisition stay on
/// the presenter's dedicated actor. A successful frame from an old load is not ready.
final class WPESceneSpanPresentationState: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: Int?
    func record(generation: Int) {
        lock.lock(); self.generation = generation; lock.unlock()
    }

    func hasPresented(generation: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return self.generation == generation
    }
}

final class WPESceneSpanPresenter {
    let frames: WPESceneSpanFrames
    let state: WPESceneSpanPresentationState
    let producer: WPEDisplayRenderActor
    let executor: WPEMetalRenderExecutor
    let layer: WPEPresentLayer
    let permits = WPEMetalFrameSubmissionPool(slotCount: 1)
    var configuration: VideoSpanRenderConfiguration
    let density: CGFloat

    init(device: MTLDevice, layer: WPEPresentLayer, frames: WPESceneSpanFrames,
         state: WPESceneSpanPresentationState, producer: WPEDisplayRenderActor,
         configuration: VideoSpanRenderConfiguration, density: CGFloat) throws {
        self.frames = frames
        self.state = state
        self.producer = producer
        self.layer = layer
        self.configuration = configuration
        self.density = density
        executor = try WPEMetalRenderExecutor(device: device)
    }

    func present() {
        guard let frame = frames.latest(), let permit = permits.tryAcquire() else { return }
        defer { permit.seal() }
        let size = configuration.canvasFrame.size
        guard let uniforms = WPEPresentUniforms.make(
            fitMode: frame.fitMode,
            sourceWidth: Int(frame.sourceSize.width), sourceHeight: Int(frame.sourceSize.height),
            targetWidth: Int(size.width * density), targetHeight: Int(size.height * density)
        ).sliced(to: configuration) else { return }
        do {
            let completion = permit.registerSubmission()
            let state = state
            let producer = producer
            let presented = try executor.present(texture: frame.texture, layer: layer.layer, uniforms: uniforms, presentCompletion: { _, commandBuffer, release in
                // Capturing the packet pins the producer's texture until this read finishes.
                if commandBuffer.status == .completed {
                    state.record(generation: frame.generation)
                    Task {
                        await producer.recordPresentCompletion(.init(generation: frame.generation,
                                                                     renderCompleted: true, presentCompleted: true))
                    }
                }
                release()
                completion.complete()
            })
            if !presented {
                completion.complete()
            }
        } catch {
            Logger.repeatedWarning("Scene span present failed: \(error.localizedDescription)", source: .sceneSpanPresent, category: .wpeRender)
        }
    }
}

/// Constructed on main, transferred once, subsequently actor-owned.
struct WPESceneSpanPresenterHandoff: @unchecked Sendable {
    let presenter: WPESceneSpanPresenter
}
#endif
