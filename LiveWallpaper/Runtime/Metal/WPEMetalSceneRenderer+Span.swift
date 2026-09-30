#if !LITE_BUILD
import CoreGraphics
import LiveWallpaperCore
import Metal

extension WPEMetalSceneRenderer {
    /// The group producer never asks any display for a drawable. Publication
    /// waits for all render submissions, including auxiliary text passes.
    func renderAndPublishSpanFrame(to frames: WPESceneSpanFrames) {
        guard didLoad else { return }
        do {
            if needsContinuousFrames || pendingForcedRerender || outputTexture == nil {
                pendingForcedRerender = false
                #if DEBUG
                frameEncodeCountForTesting += 1
                #endif
                outputTexture = try renderCurrentFrame(inputs: makeFrameInputs())
                outputFrameProduction = latestFrameProduction
            }
            guard let texture = outputTexture, let production = outputFrameProduction else { return }
            spanFrameSequence &+= 1
            let frame = WPESceneSpanFrame(texture: texture, generation: loadGeneration,
                                          sequence: spanFrameSequence, sourceSize: sceneRenderSize,
                                          fitMode: presentFitMode, tracker: executor.presentTracker)
            let captures = takePendingLivePosterCaptures()
            let actor = displayActor
            production.observe { succeeded in
                if let captures {
                    captures.captureAfterPresent(from: frame.texture, completed: succeeded,
                                                 releaseSource: { withExtendedLifetime(frame) {} })
                }
                if succeeded {
                    frames.publish(frame, generation: frame.generation, sequence: frame.sequence)
                } else if let actor {
                    Task { await actor.recordPresentCompletion(.init(generation: frame.generation,
                                                                     renderCompleted: false, presentCompleted: false)) }
                }
            }
            didLogFrameFailure = false
            synchronizeFrameDemand()
        } catch is WPEMetalFrameInFlightBudgetExhausted {
            // Bounded pool or render submissions are busy; retain the last frame.
        } catch {
            if !didLogFrameFailure {
                Logger.warning("Scene span frame failed: \(error.localizedDescription)", category: .screenManager)
                didLogFrameFailure = true
            }
        }
    }
}
#endif
