#if !LITE_BUILD
import MetalKit

extension WPEMetalSceneRenderer {
    typealias PresentCompletion = @Sendable (
        MTLTexture,
        MTLCommandBuffer,
        @escaping @Sendable () -> Void
    ) -> Void

    /// Passed in because merged present builds this mid-render, before `outputFrameProduction`.
    func makeReadinessPresentCompletion(
        livePosterCaptures: LivePosterCaptureBatch?,
        frameProduction candidateProduction: WPEMetalFrameProductionCompletion?
    ) -> PresentCompletion? {
        let posterCompletion = Self.livePosterPresentCompletion(for: livePosterCaptures)
        let presentGeneration = loadGeneration
        let candidateRenderActor = displayActor
        let readinessPlan = WPEFrameReadinessTrackingPlan.make(
            generation: presentGeneration,
            completedGeneration: completedPresentGeneration,
            hasReadinessConsumer: candidateRenderActor != nil
        )
        let renderActor = readinessPlan.tracksReadiness ? candidateRenderActor : nil
        let frameProduction = readinessPlan.tracksReadiness ? candidateProduction : nil
        guard readinessPlan.requiresPresentCompletion(
            hasPosterConsumer: posterCompletion != nil
        ) else {
            return nil
        }

        return { source, commandBuffer, releaseSource in
            let presentCompleted = commandBuffer.status == .completed
            if let posterCompletion {
                WPEPresentSourceReleaseRouter.route(releaseSource: releaseSource) { releaseOnce in
                    posterCompletion(source, commandBuffer, releaseOnce)
                }
            } else {
                WPEPresentSourceReleaseRouter.route(releaseSource: releaseSource)
            }
            guard let renderActor else { return }
            WPEFrameReadinessCoordinator.observe(
                generation: presentGeneration,
                frameProduction: frameProduction,
                presentCompleted: presentCompleted
            ) { result in
                Task {
                    await renderActor.recordPresentCompletion(result)
                }
            }
        }
    }
}
#endif
